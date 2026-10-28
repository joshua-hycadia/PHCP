#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_gui_editing.pl -- the spreadsheet's editing operations and cell-level
# validation, tested headlessly against the document.
#
# The grid widget and the clipboard are replaced by small stand-ins, so this
# runs with no display.  What it proves is the part that can go wrong without
# anyone noticing: that a paste never writes a calculated cell, that a fitting
# string with a comma arrives in one cell, that every operation is one undo
# step and undoes exactly, and that a problem is marked on the cell it belongs
# to and nowhere else.
#==============================================================================
use warnings;
use FindBin; use lib "$FindBin::Bin/..";
use HardyCross; use HardyCross::Parse; use HardyCross::PipeData;

# --- stand-ins for the Tk grid and clipboard ---------------------------------
package FakeGrid;
sub new { bless { sel => [], active => '1,1' }, shift }
sub curselection { @{ $_[0]{sel} } }
sub index { $_[0]{active} }
sub activate { $_[0]{active} = $_[1] }
sub selectionClear { $_[0]{sel} = [] }
sub selectionSet { push @{ $_[0]{sel} }, $_[1] }
sub see {} sub update {} sub configure {} sub tagCell {} sub colWidth {}
sub reread { $_[0]{rereads}++ }        ; # discards the stale edit buffer
sub rereads { $_[0]{rereads} || 0 }
sub select_rect { my ($t, $r0, $c0, $r1, $c1) = @_;
  $t->{sel} = [ map { my $r = $_; map { "$r,$_" } $c0 .. $c1 } $r0 .. $r1 ];
  $t->{active} = "$r0,$c0" }
package FakeMW;
my $CLIP = '';
sub new { bless {}, shift }
sub clipboardClear { $CLIP = '' } sub clipboardAppend { $CLIP .= $_[-1] }
sub SelectionGet { $CLIP } sub afterCancel {} sub after {}
package main;

my $src = do { open my $f, '<', "$FindBin::Bin/../phcp_gui.pl" or die; local $/; <$f> };
$src =~ s/^use Tk.*$//mg;
$src =~ s/^\$mw = MainWindow.*\z//ms;
$src .= q{ sub _doc { \%doc } sub _undo_n { scalar @undo } sub _bad { \%cell_bad }
           sub _derived { \%derived_now } sub _set_mw { $mw = shift } sub _set_grid { $grid{$_[0]} = $_[1] } };
eval $src; die $@ if $@;
no warnings 'redefine';
*refresh_grids = sub {}; *solve_now = sub {}; *set_status = sub { $main::last_status = $_[0] };
*schedule_solve = sub {}; *fit_columns = sub {};
_set_mw(FakeMW->new);

my ($pass, $fail) = (0, 0);
sub ok { my ($n, $c) = @_; printf "  %-70s %s\n", $n, $c ? 'ok' : '*** FAIL'; $c ? $pass++ : $fail++ }

my ($model) = grep { -r } ("$FindBin::Bin/../examples/07_pipe_database_demo.hcx", $ENV{PHCP_TEST_MODEL} // '');
open my $f, '<', $model or die "no test model: set PHCP_TEST_MODEL\n";
my $in = do { local $/; <$f> };
load_text($in);
my $t = FakeGrid->new;
_set_grid('NETWORK', $t);
my $d = _doc();
my $row = sub { my $r = shift; $d->{NETWORK}[ $r - 1 ] };

print "COPY AND PASTE\n";
$t->select_rect(1, 1, 2, 4);
do_copy($t, 'NETWORK');
ok('copy gives a 2 x 4 tab-separated block', $CLIP =~ /^M1\tSUP\tR1\t12\.0\nM2\tR1\tR2\t6\.0\n\z/);
my $u0 = _undo_n();
$t->select_rect(5, 1, 5, 1);
$CLIP = "Q9\tH3\tH1\t7.5\t\t50\t2E,1T\n";
do_paste($t, 'NETWORK');
ok('paste writes the block from the active cell', $row->(5)[0] eq 'Q9' && $row->(5)[3] eq '7.5');
ok('a fitting string with a comma arrives in ONE cell', $row->(5)[6] eq '2E,1T');
ok('the paste is one undo step', _undo_n() == $u0 + 1);
# a paste that crosses a calculated (mirrored) cell must skip it
my ($dr, $dc) = map { split /,/ } grep { /^\d+,(9|10)$/ } sort keys %{ _derived() };
if (defined $dr) {
  my $before = $row->($dr)[ $dc - 1 ] // '';
  $t->select_rect($dr, $dc, $dr, $dc);
  $CLIP = "999\n";
  do_paste($t, 'NETWORK');
  ok("paste over calculated cell $dr,$dc is skipped, not stored",
     ($row->($dr)[ $dc - 1 ] // '') eq $before && $main::last_status =~ /skipped/);
} else { ok('model has a calculated cell to test against', 0) }

print "CLEAR, FILL DOWN\n";
$t->select_rect(5, 4, 5, 6);
do_clear($t, 'NETWORK');
ok('clear empties the selected input cells', !has($row->(5)[3]) && !has($row->(5)[5]));
$t->select_rect(1, 1, 3, 6);
do_fill_down($t, 'NETWORK');
ok('fill down copies the top row into the rows below', $row->(3)[3] eq $row->(1)[3] && $row->(2)[5] eq $row->(1)[5]);
ok('fill down gives the id column the NEXT id each row', $row->(2)[0] eq 'M2' && $row->(3)[0] eq 'M3');

print "INSERT, DELETE, UNDO\n";
load_text($in); $d = _doc();
my $before = serialise();
my $n0 = scalar @{ $d->{NETWORK} };
$t->select_rect(2, 1, 2, 1);
do_insert_row($t, 'NETWORK', 0);
ok('insert row above puts a blank row at 2', !row_has_content($d->{NETWORK}[1]) && $d->{NETWORK}[2][0] eq 'M2');
$t->select_rect(3, 1, 4, 1);
do_delete_rows($t, 'NETWORK');
ok('delete removes the two selected rows', $d->{NETWORK}[2][0] eq 'B2');
do_undo(); do_undo();
ok('two undos restore the document exactly', serialise() eq $before);

print "CELL-LEVEL VALIDATION\n";
load_text($in); $d = _doc();
$d->{NETWORK}[0][3] = '';                 # M1 loses its length
$d->{NETWORK}[1][3] = 'six';              # M2's length is not a number
$d->{NETWORK}[1][4] = 'S20'; $d->{NETWORK}[1][5] = '350'; $d->{NETWORK}[1][6] = '1E';  # E above DN300
cell_problems();
my $bad = _bad()->{NETWORK};
ok('a missing length marks exactly that cell (1,4)', ($bad->{'1,4'} // '') eq 'ERROR');
ok('a non-number length marks its cell (2,4)', ($bad->{'2,4'} // '') eq 'ERROR');
ok('a DATA_REQUIRED fitting marks the fitting cell (2,7)', ($bad->{'2,7'} // '') eq 'ERROR');
ok('a good cell is left alone (1,1)', !exists $bad->{'1,1'});
my $fs = validate_model();
my ($link) = grep { $_->[3] && $_->[3][1] == 2 && $_->[3][2] == 7 } @$fs;
ok('the panel finding carries its cell, so a click can go there', defined $link);
ok("   and says why: " . substr($link->[2] // '', 0, 40) . '...', ($link->[2] // '') =~ /DATA_REQUIRED/);

print "OPENING A FILE\n";
# The grid holds the cell being edited in a buffer of its own.  Replacing the
# document must throw that buffer away, or the cell goes on showing the old
# model's value -- seen on Windows as a supply node still reading "A" after
# opening a model whose supply is at SUP.
my $before_rereads = $t->rereads;
load_text($in);
ok('opening a document rereads the grids, dropping any stale edit buffer',
   $t->rereads > $before_rereads);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
