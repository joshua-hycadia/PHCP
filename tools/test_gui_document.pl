#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_gui_document.pl -- the spreadsheet's document model, without a display.
#
# Loads a model into the spreadsheet's sheets, saves it back, and proves that
# nothing is lost or altered on the way: every parameter must survive a load
# and a save exactly, outlet ids must not be renamed, pumps and nodes that sit
# on devices must be editable, and undo and redo must restore the document
# byte for byte.  Two real defects -- outlets renamed on save, and derived
# display values written back as inputs -- were found by this test.
#==============================================================================
# Headless test of the spreadsheet's document logic.
use warnings; use FindBin;
use FindBin; use lib "$FindBin::Bin/..";
use HardyCross; use HardyCross::Parse; use HardyCross::PipeData;
my $src = do { open my $f,"<","$FindBin::Bin/../phcp_gui.pl" or die; local $/; <$f> };
$src =~ s/^use Tk.*$//mg; $src =~ s/^\$mw = MainWindow.*\z//ms;
$src .= q{ sub _doc { return \%doc } sub _undo_n { scalar @undo } sub _redo_n { scalar @redo } };
eval $src; die $@ if $@;
no warnings 'redefine';
*refresh_grids = sub {}; *solve_now = sub {}; *fit_columns = sub {};
*paint_derived = sub {}; *set_status = sub {}; *schedule_solve = sub {};
my ($pass, $fail) = (0, 0);
sub ok { my ($n, $c) = @_; printf "  %-66s %s\n", $n, $c ? 'ok' : '*** FAIL'; $c ? $pass++ : $fail++ }
sub solve_text { my $n = HardyCross::Parse::read_string(shift); HardyCross::solve_model($n); $n }
sub flows { my $n = shift; my %q; $q{$_->{id}} = $_->{q} for @{$n->{elems}}[1..$#{$n->{elems}}]; \%q }

open my $f,"<","$FindBin::Bin/../examples/02_full_network.hcx" or die;
my $in = do { local $/; <$f> };
load_text($in);
my $d = _doc();
print "SHEETS\n";
ok('pump PMP1 is a row on the PUMPS sheet', grep { ($_->[0]//'') eq 'PMP1' } @{ $d->{PUMPS} });
my @other = map { $_->[0] } grep { ($_->[0]//'') =~ /\S/ } @{ $d->{OTHERNODES} };
ok("device-only nodes are rows on OTHER NODES (@other)", (grep { $_ eq 'X2' } @other) && (grep { $_ eq 'Y2' } @other));
my ($x2) = grep { ($_->[0]//'') eq 'X2' } @{ $d->{OTHERNODES} };
ok('   X2 keeps its outlet id and type (S1 SPRINKLER)', $x2->[3] eq 'S1' && uc($x2->[4]) eq 'SPRINKLER');

print "ROUND TRIP\n";
my $out = serialise();
my ($a, $b) = (flows(solve_text($in)), flows(solve_text($out)));
my $worst = 0;
for my $k (keys %$a) { my $dd = abs($a->{$k} - ($b->{$k} // 1e9)); $worst = $dd if $dd > $worst }
# A save may list elements in a different order, giving a different loop set
# that converges to a slightly different point -- so flows are judged against
# the model's OWN tolerance, and the real guarantee is tested below: that every
# PARAMETER survives the round trip exactly.
my $tol = HardyCross::Parse::read_string($in)->{opts}{tol_flow};
ok(sprintf('flows agree within the model tolerance (worst %.2e, tol %g L/min)', $worst, $tol),
   $worst <= $tol);
ok('pump curve written back', $out =~ /^\s*PMP1 T1 J1 0 850 2500 800 4000 600\s*$/m);

print "EDITING THE NEW SHEETS\n";
my ($pr) = grep { ($_->[0]//'') eq 'PMP1' } @{ $d->{PUMPS} };
$pr->[5] = 900;                                  # raise the shut-off head
my $q1 = flows(solve_text(serialise()))->{PMP1};
ok(sprintf('editing the pump curve changes the solve (PMP1 %.1f -> %.1f L/min)',
           $a->{PMP1}, $q1), abs($q1 - $a->{PMP1}) > 1);
$x2->[7] = 80;                                   # raise S1's minimum pressure
ok('editing an OTHER NODES outlet is written to DISCHARGES',
   serialise() =~ /^\s*S1 X2 SPRINKLER .*P=80/m);

print "UNDO\n";
load_text($in); $d = _doc();
my $before = serialise();
push_undo(); ($pr) = grep { ($_->[0]//'') eq 'PMP1' } @{ $d->{PUMPS} }; $pr->[5] = 999;
push_undo(); ($x2) = grep { ($_->[0]//'') eq 'X2' } @{ $d->{OTHERNODES} }; $x2->[7] = 77;
ok('two edits recorded', _undo_n() == 2);
do_undo(); do_undo();
ok('two undos restore the document exactly', serialise() eq $before);
do_redo();
ok('redo reapplies the first edit', serialise() =~ /PMP1 T1 J1 0 999/);
push_undo();
ok('a fresh edit clears the redo stack', _redo_n() == 0);
load_text($in);
my %ia = map { $_ => 1 } keys %{ flows(solve_text($in)) };
my %ib = map { $_ => 1 } keys %{ flows(solve_text(serialise())) };
print "only in original : ", join(' ', sort grep { !$ib{$_} } keys %ia), "\n";
print "only after save  : ", join(' ', sort grep { !$ia{$_} } keys %ib), "\n";
sub params { my $n = HardyCross::Parse::read_string(shift); my %p;
  for my $e (@{$n->{elems}}[1..$#{$n->{elems}}]) {
    $p{$e->{id}} = join ' ', map { my $v = $e->{$_}; defined $v && !ref $v ? "$_=$v" : () }
      qw(kind len dia c eqv kfit k qreq preq z dp bore pipedia pstat); }
  for my $i (1..$#{$n->{nodes}}) { my $nd = $n->{nodes}[$i]; $p{"node:$nd->{id}"} = "z=$nd->{z} demand=$nd->{demand}" }
  \%p }
load_text($in);
my ($pa, $pb) = (params($in), params(serialise()));
my $diffs = 0;
for my $k (sort keys %$pa) { next if ($pb->{$k}//'') eq $pa->{$k}; $diffs++;
  print "DIFF $k\n   file: $pa->{$k}\n   save: ", ($pb->{$k}//'MISSING'), "\n" }
ok("every parameter survives load and save exactly ($diffs differences)", $diffs == 0);
printf "\n%d passed, %d failed\n", $pass, $fail;
