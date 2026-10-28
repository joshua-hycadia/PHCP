#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_pipedata.pl -- the pipe and fitting database and its resolver.
#
# Reproduces hand-calculated values: a DN300 Schedule 20 tee, the C multiplier
# and diameter modifier at a spread of types and sizes, and every pipe K in the
# database from its own bore and C.  A wrong basis bore, exponent or source
# boundary would each show up here as a mismatch.  Also checks the rules: a
# dash is DATA_REQUIRED and never zero, CPVC and PE take no corrections, PVC-M
# is a fallback that must be flagged, and fittings that do not turn the flow
# are not counted.
#
# The database is user editable.  If an edit makes this test fail, either the
# edit is wrong or the expected value here must be re-derived by hand -- never
# just changed to match.
#==============================================================================
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/..";
use HardyCross::PipeData;
HardyCross::PipeData::load("$FindBin::Bin/../data/pipes.dat");

my ($pass, $fail) = (0, 0);
sub near { my ($name, $got, $want, $tol) = @_;
  my $ok = defined $got && abs($got - $want) <= $tol;
  printf "  %-58s %9s  want %-7s %s\n", $name, defined $got ? sprintf('%.3f',$got) : 'undef', $want, $ok ? 'ok' : '*** FAIL';
  $ok ? $pass++ : $fail++; }
sub is { my ($name, $ok) = @_; printf "  %-58s %s\n", $name, $ok ? 'ok' : '*** FAIL'; $ok ? $pass++ : $fail++ }
my $R = \&HardyCross::PipeData::resolve;

print "HAND CHECK - DN300 Schedule 20 tee, flow turned\n";
my $r = $R->(type=>'S20', dn=>300, spec=>'T');
# FM base 18.3 m on Schedule 40, corrected to the Schedule 20 bore:
# 18.3 x (d S20 / d S40)^4.87 = 18.3 x 1.13378 = 20.748 m.  Rounding the
# modifier to 1.134 first gives 20.752; the engine carries the exact value.
near('DN300 tee, flow turned, Schedule 20, exact', $r->{total}, 20.748, 0.001);
near('   its diameter modifier -> 1.134', $r->{records}[0]{dmult}, 1.134, 0.0005);

print "C MULTIPLIER - (C / 120)^1.85\n";
for ([100,0.71],[110,0.85],[130,1.16],[140,1.33],[150,1.51]) {
  my $x = $R->(type=>'ASAM', dn=>50, c=>$_->[0], spec=>'E');
  near("C = $_->[0]", $x->{records}[0]{cmult}, $_->[1], 0.005); }

print "DIAMETER MODIFIER - AS 2118.1 values on other pipe\n";
for (['ASAM',50,1.000],['ASAH',20,0.757],['ASAH',150,0.966],
     ['S40',25,0.888],['S40',65,0.640],['S40',150,0.959]) {
  my $x = $R->(type=>$_->[0], dn=>$_->[1], spec=>'E');
  near("$_->[0] DN$_->[1]", $x->{records}[0]{dmult}, $_->[2], 0.0005); }

print "DIAMETER MODIFIER - FM DS 3-0 values on other pipe\n";
for ([200,1.091],[250,1.117],[300,1.134],[350,1.097],[450,1.153],[600,1.142]) {
  my $x = $R->(type=>'S20', dn=>$_->[0], spec=>'E45');
  near("S20 DN$_->[0]", $x->{records}[0]{dmult}, $_->[1], 0.0005); }

print "PIPE K - every K reproduces from its own d and C\n";
my ($kmax, $kworst) = (0, '');
for my $t (HardyCross::PipeData::pipe_types()) {
  my $c = HardyCross::PipeData::pipe_type($t)->{c};
  for my $dn (sort { $a <=> $b } grep { defined HardyCross::PipeData::bore($t,$_) }
              map { $_ } (15..700)) {
    my $row = HardyCross::PipeData::pipe_row($t,$dn) or next;
    next if $row->{k} eq 'DASH';
    my $k = 6.05e7 / ($c ** 1.85 * $row->{bore} ** 4.87);
    my $rel = abs($k - $row->{k}) / $row->{k};
    ($kmax, $kworst) = ($rel, "$t DN$dn") if $rel > $kmax;
  } }
near("worst K disagreement ($kworst), as a fraction", $kmax, 0, 0.006);

print "RULES\n";
my $cv = $R->(type=>'ASAM', dn=>20, spec=>'CV');
is('DN20 check valve (dash) -> DATA_REQUIRED, never zero',
   !defined $cv->{total} && $cv->{records}[0]{status} eq 'DATA_REQUIRED');
is('   ...and the message names the component', ($cv->{errors}[0]//'') =~ /CV on ASAM DN20/);
my $se = $R->(type=>'S20', dn=>350, spec=>'E');
is('screwed elbow above DN300 (dash) -> DATA_REQUIRED', !defined $se->{total});
my $ef = $R->(type=>'S20', dn=>350, spec=>'EF');
is('flanged elbow at DN350 resolves', defined $ef->{total} && $ef->{total} > 0);
my $cp = $R->(type=>'CPVC', dn=>25, spec=>'2E');
near('CPVC DN25 2E, BlazeMaster, no corrections', $cp->{total}, 3.0, 0.001);
is('   CPVC carries no C or D multiplier', $cp->{records}[0]{cmult} == 1 && $cp->{records}[0]{dmult} == 1);
my $tr = $R->(type=>'CPVC', dn=>25, spec=>'1TR');
is('CPVC tee run is published but not counted',
   $tr->{total} == 0 && $tr->{records}[0]{method} eq 'NOT_COUNTED');
my $pe = $R->(type=>'PE11', dn=>110, spec=>'E');
my $bpe = HardyCross::PipeData::bore('PE11',110);
near("PE11 DN110 90deg elbow, Le = 40 x d", $pe->{total}, 40 * $bpe / 1000, 1e-9);
is('   PE carries no corrections', $pe->{records}[0]{dmult} == 1);
my $pv = $R->(type=>'PVCM16', dn=>150, spec=>'E');
is('PVC-M fitting is a controlled fallback -> ASSUMPTION_REQUIRED',
   $pv->{records}[0]{status} eq 'ASSUMPTION_REQUIRED');
my $hc = $R->(type=>'ASAM', dn=>25, spec=>'1E1T');
near('compact form 1E1T, ASAM DN25 = 0.6 + 1.5', $hc->{total}, 2.1, 0.001);
my $bad = $R->(type=>'ASAM', dn=>25, spec=>'2E,1X');
is('an unknown code is an error, not skipped', !defined $bad->{total});
my $so = $R->(type=>'ASAH', dn=>20, spec=>'E', standard_only=>1);
is('Standard-alone election leaves AS 2118.1 values unmodified', $so->{records}[0]{dmult} == 1);

print "REGRESSION\n";
use HardyCross::Parse;
my @tk = HardyCross::Parse::tokenize('  M1 A B 12 100 TYPE=ASAM FIT=1T,2E,1GV,1CV');
my ($fit) = grep { /^FIT=/ } @tk;
is('commas inside FIT= survive the tokeniser (was cut to the first fitting)',
   ($fit // '') eq 'FIT=1T+2E+1GV+1CV');
my $all = $R->(type=>'ASAM', dn=>100, spec=>'1T+2E+1GV+1CV');
near('   and all four resolve: 6.1 + 2x3.0 + 0.6 + 6.7', $all->{total}, 19.4, 0.001);

print "ROUGHNESS\n";
{
    my %k = map { $_ => HardyCross::PipeData::pipe_type($_)->{eps} } HardyCross::PipeData::pipe_types();
    is('every pipe type has a roughness for Darcy-Weisbach', !grep { !defined $k{$_} || $k{$_} <= 0 } keys %k);
    # A database written before the roughness column: still read, roughness none.
    require File::Temp;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    open my $in, '<:raw', HardyCross::PipeData::path() or die;
    my $old = do { local $/; <$in> };
    close $in;
    $old =~ s/^(PIPETYPE\|[^\n]*)\|[^|\n]*$/$1/mg;
    open my $o, '>:raw', "$dir/pipes.dat" or die;
    print $o $old;
    close $o;
    my $was = HardyCross::PipeData::path();
    HardyCross::PipeData::load("$dir/pipes.dat");
    is('   a database without the column still loads; roughness none published',
       HardyCross::PipeData::pipe_type('ASAM') && !defined HardyCross::PipeData::pipe_type('ASAM')->{eps}
       && HardyCross::PipeData::bore('ASAM', 50) == 53.0);
    HardyCross::PipeData::load($was);
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
