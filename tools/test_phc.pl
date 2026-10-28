#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_phc.pl -- the .phc command language and its line checker.
#
#   perl tools/test_phc.pl          every check; example 04 read, not solved
#   perl tools/test_phc.pl --full   also solve example 04 both ways (minutes)
#
# What it proves, in order:
#
#   1. EXAMPLES.  Every example in .phc solves to the same pipe flows and node
#      pressures as its .hcx original, the baseline.
#   2. EVERY COMMAND.  A valid line reads; a line missing each field, with a
#      bad number, a KEY=value, an unknown word, or a duplicate, is refused --
#      and every refusal names its line.
#   3. ANY ORDER.  Shuffled lines solve to the same results.
#   4. UNITS.  One model in other units, and values carrying their own units,
#      is the same model.
#   5. COPIES, CHANGES AND DEVICES.  PC, NC, CHANGEPIPE, EQV, and BP, BFP,
#      PRV, OPP and OFD in a pipe, each give the network they describe.
#   6. THE LINE CHECKER.  Status, template, pick lists and proposals.
#   7. TRAPS CLOSED.  Undefined nodes, duplicate names, '#', END, KEY=value.
#   8. FIXED FLOWS.  The minimum pressure is checked and can govern.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use List::Util qw(shuffle);
use HardyCross;
use HardyCross::Parse;
use HardyCross::Phc;
use HardyCross::Report;
use HardyCross::Demand;

my $FULL = grep { $_ eq '--full' } @ARGV;
my $EX   = "$FindBin::Bin/../examples";
my ($pass, $fail) = (0, 0);

# is -- one named check; a failure prints what was found.
sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }

# read_phc -- (network, undef) or (undef, message) for .phc text.
sub read_phc {
    my $net = eval { HardyCross::Phc::read_string(shift) };
    return ($net, undef) if $net;
    my $e = $@;
    return (undef, HardyCross::is_model_error($e) ? $e->{msg} : "$e");
}

# refused -- .phc text must be refused on line $line, with a message matching $re.
sub refused {
    my ($name, $text, $line, $re) = @_;
    my ($net, $err) = read_phc($text);
    is($name, !$net && $err =~ /^line \Q$line\E: / && $err =~ $re, $net ? 'it was accepted' : "got: $err");
}

# Solved pipe flows by id, and gauge pressures by node id.
sub results {
    my $net = shift;
    my (%q, %p);
    $q{ $_->{id} } = $_->{q} for grep { $_->{kind} eq 'PIPE' } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    $p{ $_->{id} } = $_->{h} - $HardyCross::GAMMA_W * $_->{z}
        for grep { $_->{id} ne 'REF' } @{ $net->{nodes} }[1 .. $#{ $net->{nodes} }];
    return (\%q, \%p);
}
# worst -- the largest difference over the keys of $a (all must be in $b).
sub worst {
    my ($a, $b) = @_;
    my $w = 0;
    for (keys %$a) {
        return 1e30 unless exists $b->{$_};
        my $d = abs($a->{$_} - $b->{$_});
        $w = $d if $d > $w;
    }
    return $w;
}
sub solved { my $n = shift; HardyCross::solve_model($n); $n }
sub elems_by_id { my $n = shift; return map { $_->{id} => $_ } grep { $_->{id} } @{ $n ? $n->{elems} : [] } }

# Tight tolerances, so two descriptions of one model are compared on the
# model and not on where the iteration happened to stop.
my $TIGHT_PHC = "\nOPTION TOL_FLOW 1E-7\nOPTION TOL_LOOP 1E-8\nOPTION MAXITER 200000\n";
sub tighten_phc { my $t = shift; $t =~ s/^OPTION\s+(TOL_FLOW|TOL_LOOP|MAXITER)\b.*$//mg; $t . $TIGHT_PHC }
sub tighten_hcx {
    my $t = shift;
    $t =~ s/^\s*(TOL_FLOW|TOL_LOOP|MAXITER)\b.*$//mg;
    $t =~ s/^OPTIONS\s*$/OPTIONS\n  TOL_FLOW 1E-7\n  TOL_LOOP 1E-8\n  MAXITER 200000/m
        or $t =~ s/^UNITS\s*$/OPTIONS\n  TOL_FLOW 1E-7\n  TOL_LOOP 1E-8\n  MAXITER 200000\nEND\nUNITS/m;
    return $t;
}

#==============================================================================
print "1. EXAMPLES - the same flows and pressures as the .hcx baseline\n";
#==============================================================================
# An orifice plate in .phc takes its pipe's bore from the pipe and fitting
# database (ASAM DN50: 53.0 mm); the .hcx route used a fixed table (53.1 mm).
# The baseline is given the database bore, so the comparison is exact.
for my $phcpath (sort glob("$EX/*.phc")) {
    (my $base = $phcpath) =~ s{.*/}{};
    (my $hcxpath = $phcpath) =~ s/\.phc\z/.hcx/;
    my ($p, $err) = read_phc(slurp($phcpath));
    is("$base reads", $p, $err);
    next unless $p && -e $hcxpath;
    my $hcx = slurp($hcxpath);
    $hcx =~ s/(ORIFICE_[PD].*DN=50)/$1 PIPEDIA=53.0/g;
    if ($base =~ /grid1000/) {
        my $h = HardyCross::Parse::read_string($hcx);
        my %pp = map { $_->{id} => 1 } grep { $_->{kind} eq 'PIPE' } @{ $p->{elems} }[1 .. $#{ $p->{elems} }];
        my @missing = grep { !$pp{ $_->{id} } } grep { $_->{kind} eq 'PIPE' } @{ $h->{elems} }[1 .. $#{ $h->{elems} }];
        is('   every baseline pipe and node is in the .phc model',
           !@missing && @{ $p->{nodes} } == @{ $h->{nodes} } + 1);   # + the moved sprinkler's node
        next unless $FULL;
        my ($qa, $pa) = results(solved($h));
        my ($qb, $pb) = results(solved($p));
        is(sprintf('   solved: worst %.1e L/min, %.1e kPa (within its tolerances)',
                   worst($qa, $qb), worst($pa, $pb)), worst($qa, $qb) < 0.5 && worst($pa, $pb) < 0.5);
        next;
    }
    my ($qa, $pa) = results(solved(HardyCross::Parse::read_string(tighten_hcx($hcx))));
    my ($t) = read_phc(tighten_phc(slurp($phcpath)));
    my ($qb, $pb) = results(solved($t));
    my ($wq, $wp) = (worst($qa, $qb), worst($pa, $pb));
    is(sprintf('   worst difference %.1e in a pipe flow, %.1e in a node pressure', $wq, $wp),
       $wq < 1e-4 && $wp < 1e-4);
}

#==============================================================================
print "2. EVERY COMMAND - valid, each field missing, bad numbers, refusals\n";
#==============================================================================
# A small model; each test line is added as line 10.
my $BASE = join "\n", 'UNITS LENGTH M', 'NODE A 0', 'NODE B 0', 'NODE C 1.5',
    'WATER W1 0 500', 'USE BORE 120', 'PIPE P1 W1 A 10 100', 'PIPE P2 A B 10 100',
    'SPRINKLER S1 1 -50 80', '';
my $L = 10;
# Each command: a valid line, and the positions (from 1) of its numeric fields.
my @CASES = (
    [ 'TITLE A TEST MODEL',                 [] ],
    [ 'PROJECT JOB HYC-2026-000',           [] ],
    [ 'UNITS PRESSURE KPA',                 [] ],
    [ 'METHOD HW',                          [] ],
    [ 'OPTION TOL_FLOW 0.01',               [2] ],
    [ 'USE ASAM 110',                       [2] ],
    [ 'PIPE P3 B C 5 50',                   [4, 5] ],
    [ 'PC P2 P4 B C',                       [] ],
    [ 'CHANGEPIPE P2 12 80',                [2, 3] ],
    [ 'EQV P2 3.5',                         [2] ],
    [ 'NODE D 2.5',                         [2] ],
    [ 'NC C D E',                           [] ],
    [ 'WATER W2 0 600 1000 500',            [2, 3, 4, 5] ],
    [ 'SPRINKLER S2 1.5 -50 80',            [2, 3, 4] ],
    [ 'HYDRANT H1 1.5 600 21',              [2, 3, 4] ],
    [ 'HREEL R1 1.5 -220 7.5',              [2, 3, 4] ],
    [ 'FIXEDFLOW F1 C 100 150',             [3, 4] ],
    [ 'PUMP PU1 A C 300 1000 200',          [4, 5, 6] ],
    [ 'BP P2 300 1000 200',                 [2, 3, 4] ],
    [ 'BFP P2 0 10 1000 30',                [2, 3, 4, 5] ],
    [ 'PRV P2 0 50',                        [2, 3] ],
    [ 'OPP P2 20',                          [2] ],
    [ 'OFD P2 60',                          [2] ],
    [ 'PRA P2 3:1 300',                     [3] ],
);
for my $case (@CASES) {
    my ($line, $nums) = @$case;
    my ($word) = $line =~ /^(\S+)/;
    my ($net, $err) = read_phc($BASE . $line);
    is("$word: '$line' reads", $net, $err);
    # Each fixed field missing: the line cut after fewer and fewer fields.
    my $spec = HardyCross::Phc::command_spec($word);
    my @tk = split ' ', $line;
    my $nfix = @{ $spec->{fixed} };
    for my $keep (0 .. $nfix - 1) {
        my $cut = join ' ', @tk[0 .. $keep];
        refused("   missing $spec->{fixed}[$keep][0]: '$cut'", $BASE . $cut, $L, qr/NEEDS/);
    }
    # Each numeric field given a bad number (the letter O for a zero).
    for my $i (@$nums) {
        my @b = @tk;
        $b[$i] = '1O0';
        refused("   field $i '1O0' refused", $BASE . join(' ', @b), $L, qr/NOT A (NUMBER|LENGTH)/);
    }
}
refused('a KEY=value field is refused', $BASE . 'PIPE P3 B C 5 50 C=120', $L, qr/BY POSITION/);
refused('an unknown command', $BASE . 'HEAD H9 0 50 8', $L, qr/UNKNOWN COMMAND HEAD/);
refused('an unknown option', $BASE . 'OPTION TRACE FULL', $L, qr/UNKNOWN OPTION/);
refused('an unknown unit', $BASE . 'UNITS FLOW LPH', $L, qr/UNKNOWN UNIT LPH FOR FLOW/);
refused('an unknown units quantity', $BASE . 'UNITS SPEED MS', $L, qr/UNKNOWN UNITS QUANTITY/);
refused('an unknown pipe type', $BASE . 'USE BB16 150', $L, qr/UNKNOWN PIPE TYPE BB16/);
refused('a size not made in the pipe type, on its line',
        $BASE . "USE ASAM\nPIPE P9 B C 3 47", $L + 1, qr/DATA_REQUIRED - DN47/);
refused('a fitting the database lacks, on its line',
        $BASE . "USE ASAM\nPIPE P9 B C 3 50 2Q", $L + 1, qr/CANNOT READ FITTING CODE/);
refused('fittings on a USE BORE pipe', $BASE . 'PIPE P9 B C 3 50 2E', $L, qr/FITTINGS NEED A PIPE TYPE/);
refused('extra fields', $BASE . 'NODE D 2.5 9', $L, qr/UNEXPECTED FIELD/);
refused('a negative length', $BASE . 'PIPE P9 B C -3 50', $L, qr/CANNOT BE NEGATIVE/);
refused('a single BFP pair must be at flow 0', $BASE . 'BFP P2 100 10', $L, qr/FIXED LOSS: ITS FLOW MUST BE 0/);
refused('a PRA ratio must reduce', $BASE . 'PRA P2 1:2', $L, qr/MUST BE MORE THAN 1/);

print "   settings and names given twice name both lines\n";
refused('UNITS LENGTH twice',    $BASE . 'UNITS LENGTH MM', $L, qr/UNITS LENGTH IS ALREADY SET ON LINE 1/);
refused('METHOD twice',          "METHOD HW\n$BASE" . 'METHOD DW', $L + 1, qr/METHOD IS ALREADY SET ON LINE 1/);
refused('OPTION twice',          "OPTION MAXITER 9\n$BASE" . 'OPTION MAXITER 8', $L + 1, qr/OPTION MAXITER IS ALREADY SET/);
refused('TITLE twice',           "TITLE A\n$BASE" . 'TITLE B', $L + 1, qr/TITLE IS ALREADY SET/);
refused('PROJECT field twice',   "PROJECT JOB 1\n$BASE" . 'PROJECT job 2', $L + 1, qr/PROJECT JOB IS ALREADY SET/);
refused('a node defined twice',  $BASE . 'NODE A 3', $L, qr/NODE A IS ALREADY DEFINED ON LINE 2/);
refused('a node defined twice, by another command', $BASE . 'SPRINKLER B 0 -50 80', $L,
        qr/NODE B IS ALREADY DEFINED ON LINE 3/);
refused('a pipe name used twice', $BASE . 'PIPE P1 B C 3 50', $L, qr/THE NAME P1 IS ALREADY USED ON LINE 7/);
refused('two devices in one pipe', $BASE . "BFP P2 0 10\nPRV P2 0 5", $L + 1, qr/ALREADY HAS A DEVICE, BFP/);

#==============================================================================
print "3. ANY ORDER - shuffled lines give the same results\n";
#==============================================================================
# Lines are shuffled as units; a USE line travels with the pipes after it
# (USE is positional by design), and those pipes are shuffled among themselves.
srand 20261028;
for my $phcpath (sort glob("$EX/*.phc")) {
    next if $phcpath =~ /grid1000/;
    (my $base = $phcpath) =~ s{.*/}{};
    my @lines = grep { /\S/ && !m{^\s*//} } split /\n/, tighten_phc(slurp($phcpath));
    my (@units, $group);
    for (@lines) {
        if    (/^USE\b/)  { $group = [$_]; push @units, $group }
        elsif (/^PIPE\b/) { push @$group, $_ }
        else              { push @units, [$_] }
    }
    my $text = sub { join "\n", map { @$_ } @_ };
    my ($ref) = read_phc($text->(@units));
    my ($rq, $rp) = results(solved($ref));
    for my $try (1 .. 2) {
        my @u = map { $_->[0] =~ /^USE/ ? [ $_->[0], shuffle(@{$_}[1 .. $#$_]) ] : $_ } shuffle(@units);
        my ($net, $err) = read_phc($text->(@u));
        unless ($net) { is("$base shuffle $try reads", 0, $err); next }
        my ($q, $p) = results(solved($net));
        my ($wq, $wp) = (worst($rq, $q), worst($rp, $p));
        is(sprintf('%s shuffle %d: worst %.1e L/min, %.1e kPa', $base, $try, $wq, $wp),
           $wq < 1e-4 && $wp < 1e-4);
    }
}

#==============================================================================
print "4. UNITS - one model in other units is the same model\n";
#==============================================================================
{
    # The same network three ways.  Lengths, elevations, sizes, pressures,
    # flows and K-factors change unit; the solution must not.
    my $si = join "\n", 'NODE A 0', 'NODE B 2.5', 'WATER W 0 700 2000 600', 'USE ASAM',
        'PIPE P1 W A 20000 100 2E', 'PIPE P2 A B 15000 80 T', 'SPRINKLER S 3 -50 8',
        'HYDRANT H 2.5 600 21', 'PIPE P3 B S 3000 40', 'PIPE P4 B H 5000 80', 'FIXEDFLOW F A 100 150', '';
    my $other = join "\n", 'UNITS LENGTH M', 'UNITS ELEVATION MM', 'UNITS SIZE IN', 'UNITS PRESSURE BAR',
        'UNITS FLOW LPS', 'UNITS KFACTOR LPM/BAR',
        'NODE A 0', 'NODE B 2500', 'WATER W 0 7 33.333333333333 6', 'USE ASAM',
        'PIPE P1 W A 20 4 2E', 'PIPE P2 A B 15 3 T', 'SPRINKLER S 3000 -0.5 80',
        'HYDRANT H 2500 10 210', 'PIPE P3 B S 3 1.5', 'PIPE P4 B H 5 3', 'FIXEDFLOW F A 1.6666666666667 1.5', '';
    my $suffix = join "\n", 'NODE A 0', "NODE B 8'2.425\"", 'WATER W 0MM 700 2000 600', 'USE ASAM',
        'PIPE P1 W A 20M 100 2E', 'PIPE P2 A B 1500CM 80 T', 'SPRINKLER S 3000MM -50 8',
        'HYDRANT H 2.5M 600 21', 'PIPE P3 B S 3M 40', 'PIPE P4 B H 5000 80', 'FIXEDFLOW F A 100 150', '';
    my ($a) = read_phc(tighten_phc($si));
    my ($qa, $pa) = results(solved($a));
    my ($b, $eb) = read_phc(tighten_phc($other));
    is('the model in M, MM, IN, BAR, L/S and LPM/BAR reads', $b, $eb);
    if ($b) {
        my ($qb, $pb) = results(solved($b));
        is(sprintf('   same flows (worst %.1e L/min) and pressures (%.1e kPa)', worst($qa, $qb), worst($pa, $pb)),
           worst($qa, $qb) < 1e-3 && worst($pa, $pb) < 1e-3);
    }
    my ($c, $ec) = read_phc(tighten_phc($suffix));
    is("values carrying units: 20M, 1500CM, 3000MM, 8'2.425\"", $c, $ec);
    if ($c) {
        my ($qc, $pc) = results(solved($c));
        is(sprintf('   same flows (worst %.1e) and pressures (%.1e)', worst($qa, $qc), worst($pa, $pc)),
           worst($qa, $qc) < 1e-3 && worst($pa, $pc) < 1e-3);
    }
    my %e = elems_by_id($a);
    is('default units: pipe length in mm (20000 is 20 m)', abs($e{P1}{len} - 20) < 1e-9);
    is('default units: elevation in m (NODE B 2.5)', grep { ($_->{id} // '') eq 'B' && abs($_->{z} - 2.5) < 1e-9 } @{ $a->{nodes} });
    is('default K unit L/min/kPa^0.5: K 8 is 8 in L/min and kPa', abs($e{S}{k} - 8) < 1e-9);
    my %eb = elems_by_id($b);
    # The parser holds K in L/min per kPa^0.5 whatever the file's units.
    is('K 80 in LPM/BAR is K 8 in LPM/KPA', $eb{S} && abs($eb{S}{k} - 8) < 1e-6);
}

#==============================================================================
print "5. COPIES, CHANGES AND DEVICES\n";
#==============================================================================
{
    my $m = join "\n", 'NODE A 0', 'NODE B 0', 'NODE C 0', 'NODE D 0', 'WATER W 0 700',
        'USE ASAM 110', 'PIPE P1 W A 10000 100 2E',
        'PC P1 P2 A B P3 B C',            # two copies of P1
        'CHANGEPIPE P3 5000 80 T',        # P3 changed after copying
        'EQV P2 2500',                    # 2.5 m extra on P2
        'SPRINKLER S1 0 -50 8', 'NC S1 S2 S3', 'PIPE P4 C S1 1000 50', 'PIPE P5 C S2 1000 50',
        'PIPE P6 C S3 1000 50', 'PIPE P7 C D 1000 50', '';
    my ($net, $err) = read_phc($m);
    is('copies and changes read', $net, $err);
    my %e = elems_by_id($net);
    is('PC: P2 is P1 with new nodes (ASAM DN100, C 110, 2E)',
       $e{P2}{dn} == 100 && $e{P2}{c} == 110 && ($e{P2}{fitspec} // '') eq '2E');
    is('PC then CHANGEPIPE: P3 is DN80, 5 m, T', $e{P3}{dn} == 80 && abs($e{P3}{len} - 5) < 1e-9 && $e{P3}{fitspec} eq 'T');
    is('   the source P1 is unchanged', $e{P1}{dn} == 100 && abs($e{P1}{len} - 10) < 1e-9);
    is('EQV adds 2.5 m to P2', abs($e{P2}{eqv} - $e{P1}{eqv} - 2.5) < 1e-9);
    is('NC: S2 and S3 are sprinklers like S1', $e{S2} && $e{S3} && $e{S3}{otype} eq 'SPRINKLER');

    for my $dev ([ 'BP P1 300 2000 250', 'PUMP' ], [ 'BFP P1 0 10 2000 40', 'BFP' ],
                 [ 'BFP P1 0 25', 'FIXED_DROP' ], [ 'PRV P1 0 50 2000 80', 'BFP' ],
                 [ 'OPP P1 30', 'ORIFICE_REQUIRED' ], [ 'OFD P1 60', 'ORIFICE' ]) {
        my ($line, $kind) = @$dev;
        my ($d, $de) = read_phc("$m$line\n");
        my ($k) = $line =~ /^(\S+)/;
        my %de = elems_by_id($d);
        my ($el, $pipe) = ($de{"P1.$k"}, $de{P1});
        my %nid = $d ? map { $_ => $d->{nodes}[$_]{id} } 1 .. $#{ $d->{nodes} } : ();
        is("$line: a $kind from W to P1~, the pipe from P1~ to A",
           $el && $el->{kind} eq $kind && $nid{ $el->{n1} } eq 'W' && $nid{ $el->{n2} } eq 'P1~'
           && $nid{ $pipe->{n1} } eq 'P1~' && $nid{ $pipe->{n2} } eq 'A', $de);
        # A plate sized for a drop keeps its DN (its sizing uses it); both
        # take the pipe's bore from the database.
        is("   the plate takes its pipe's database bore (ASAM DN100: 105.1 mm)"
           . ($k eq 'OPP' ? ' and DN' : ''),
           abs($el->{pipedia} - 105.1) < 1e-9 && ($k ne 'OPP' || $el->{dn} == 100)) if $el && $k =~ /^O/;
    }
    my ($d) = read_phc("${m}BP P1 300 2000 250\n");
    is('a solve runs through a pipe with a pump in it', $d && HardyCross::solve_model($d));

    # The pressure ratio valve, as the manufacturer's worked example: a tank
    # 153 m up gives about 1500 kPa at a 3:1 valve, and 500 kPa after it.
    my $t = join "\n", 'WATER TANK 153 0', 'NODE A 0', 'NODE B 0', 'USE S40 120',
        'PIPE P1 TANK A 200000 100', 'PIPE P2 A B 1000 100', 'FIXEDFLOW F B 100', '';
    my ($r, $re) = read_phc($t . "PRA P2 3:1 300\n");
    is('PRA P2 3:1 reads: a RATIO element in pipe P2', $r && { elems_by_id($r) }->{'P2.PRA'}{kind} eq 'RATIO', $re);
    my $ok = HardyCross::solve_model($r);
    my ($q, $p) = results($r);
    is(sprintf('   outlet = inlet / 3: %.1f kPa in, %.1f kPa out', $p->{A}, $p->{'P2~'}),
       $ok && abs($p->{'P2~'} - $p->{A} / 3) < 0.05 && abs($p->{A} - 1499) < 2);
    my $rep = HardyCross::Report::write_report($r, $ok, 't.phc');
    is('   the report shows the ratio, inlet and outlet, and no warning',
       $rep =~ /P2\.PRA\s+PRA\s+A\s+P2~.*ratio 3:1, inlet 1499\.\d, outlet 499\.\d/ && $rep =~ /No warnings\./);
    my ($lo) = read_phc($t . "PRA P2 3:1 2000\n");
    my $rl = HardyCross::Report::write_report($lo, HardyCross::solve_model($lo), 't.phc');
    is('   an inlet below the stated minimum is a warning', $rl =~ /below its minimum\s+inlet pressure/);
    my ($two) = read_phc($t . "PRA P2 2:1\n");
    HardyCross::solve_model($two);
    my (undef, $p2) = results($two);
    is('   a 2:1 valve halves it', abs($p2->{'P2~'} - $p2->{A} / 2) < 0.05);
}

#==============================================================================
print "6. THE LINE CHECKER - status, template, choices, proposals\n";
#==============================================================================
{
    my $ck = \&HardyCross::Phc::check_line;
    my $ctx = { use => 'ASAM', nodes => [qw(A B C)] };
    for my $case (@CASES) {
        my ($word) = $case->[0] =~ /^(\S+)/;
        my $r = $ck->($case->[0], $ctx);
        is("$word: ok, template names the command",
           $r->{status} eq 'ok' && $r->{template}{command} eq $word, "$r->{status} $r->{message}");
    }
    my $r = $ck->('PI', $ctx);
    is("'PI' while typing: incomplete, not unknown", $r->{status} eq 'incomplete');
    $r = $ck->('PIPX', $ctx);
    is("'PIPX': an error", $r->{status} eq 'error' && $r->{message} =~ /UNKNOWN COMMAND/);
    $r = $ck->('PIPE P1 A', $ctx);
    is("'PIPE P1 A': incomplete, needs END, cursor in START",
       $r->{status} eq 'incomplete' && $r->{message} =~ /NEEDS END/
       && $r->{template}{fields}[ $r->{template}{current} ] eq 'START');
    is('template text', HardyCross::Phc::template_text('PIPE')
       eq 'PIPE <NAME> <START> <END> <LENGTH> <SIZE> [FITTINGS ...]', HardyCross::Phc::template_text('PIPE'));
    is('an alias: P is PIPE', ($ck->('P P1 A B 3000 50', $ctx)->{template}{command} // '') eq 'PIPE');

    my %c = map { $_->[0] => $_->[1] } @{ $ck->('USE ', $ctx)->{choices} };
    is('USE type field: the database pipe types and BORE, in capitals',
       $c{ASAM} && $c{S20} && $c{BORE} && $c{ASAM} !~ /[a-z]/);
    %c = map { $_->[0] => $_->[1] } @{ $ck->('PIPE P1 A B 3000 50 ', $ctx)->{choices} };
    # AS 2118.1 lists no butterfly valve, so at DN50 B (for BV) is not offered.
    is('fitting field, ASAM DN50: database codes, short forms G and C, no B',
       $c{E} && $c{T} && $c{GV} && $c{G} && $c{C} && !$c{B} && $c{G} =~ /SHORT FOR GV/);
    %c = map { $_->[0] => 1 } @{ $ck->('PIPE P1 A B 3000 250 ', { %$ctx, use => 'S20' })->{choices} };
    is('fitting field, S20 DN250 (FM Global): B is offered', $c{B} && $c{BV});
    %c = map { $_->[0] => 1 } @{ $ck->('UNITS FLOW ', $ctx)->{choices} };
    is('UNITS FLOW: the flow units', $c{LPM} && $c{LPS} && $c{GPM});
    $r = $ck->('PIPE P1 A B 3000 47', $ctx);
    is("ASAM DN47: the parser's DATA_REQUIRED, on the line", $r->{status} eq 'error' && $r->{message} =~ /DATA_REQUIRED/);
    $r = $ck->('SPRINKLER S1 3 -50 0', $ctx);
    is('a sprinkler with K 0 (turned off) is fine', $r->{status} eq 'ok');
    $r = $ck->('PIPE P1 A Z9 3000 50', $ctx);
    is('a node not yet defined is listed, not an error', $r->{status} eq 'ok' && "@{ $r->{undefined} }" eq 'Z9');

    my $pr = sub { $ck->($_[0], $ctx)->{proposal} // '(none)' };
    is('after a pipe: next name, starting where it ended, no fittings',
       $pr->('PIPE 3101 2113 3101 6376 65 T') eq 'PIPE 3102 3101 3102 6376 65', $pr->('PIPE 3101 2113 3101 6376 65 T'));
    is('after a sprinkler: next name, same elevation, flow and K', $pr->('SPRINKLER 4101 47.076 81 8') eq 'SPRINKLER 4102 47.076 81 8');
    is('after a node', $pr->('NODE 301 27.197') eq 'NODE 302 27.197');
    is('after a fixed flow: name and node stepped', $pr->('FIXEDFLOW F1 N1 100 150') eq 'FIXEDFLOW F2 N2 100 150');
    is('after a setting, USE or a copy: none',
       $pr->('UNITS FLOW LPM') eq '(none)' && $pr->('USE S20 120') eq '(none)' && $pr->('NC A B') eq '(none)');
}

#==============================================================================
print "7. TRAPS CLOSED\n";
#==============================================================================
refused('a node with no definition: named, at the first line using it',
        "WATER W 0 500\nUSE BORE 120\nPIPE P1 W B 1000 100\n", 3, qr/NODE B IS NOT DEFINED/);
refused('several undefined nodes: all named',
        "NODE A 0\nPIPE P1 A B 1000 100\nPIPE P2 B C 1000 100\n", 2, qr/NODE B IS NOT DEFINED \(ALSO C ON LINE 3\)/);
refused('a copy of an undefined pipe', $BASE . 'PC P9 P10 A B', $L, qr/PIPE P9, COPIED AS P10, IS NOT DEFINED/);
refused('a copy of an undefined node', $BASE . 'NC Q1 Q2', $L, qr/NODE Q1, COPIED AS Q2, IS NOT DEFINED/);
refused('a change to an undefined pipe', $BASE . 'CHANGEPIPE P9 1 50', $L, qr/PIPE P9 IS NOT DEFINED/);
refused("'#' in a line is refused, not taken as a comment", $BASE . 'TITLE JOB #12', $L, qr/'#' CANNOT BE USED/);
refused('END as a name', $BASE . 'NODE END 0', $L, qr/END CANNOT BE A NAME/);
refused("'~' in a name (PHCP's own names use it)", $BASE . 'NODE A~ 0', $L, qr/'~' IS RESERVED/);
{
    my ($net) = read_phc("// a comment line\nNODE A 0 // the riser\nWATER W 0 500\nUSE BORE 120\n"
                       . "PIPE P1 W A 1000 100\nsprinkler s1 0 -50 8\npipe p2 A s1 1000 50\n");
    is('// comments anywhere; lower-case commands read the same', $net);
    my ($off) = read_phc("NODE A 0\nWATER W 0 500\nUSE BORE 120\nPIPE P1 W A 1000 100\nSPRINKLER S1 0 -50 0\n"
                       . "PIPE P2 A S1 1000 50\nSPRINKLER S2 0 -50 8\nPIPE P3 A S2 1000 50\n");
    my %o = elems_by_id($off);
    is('a sprinkler with K 0 is off: its node stays, with no outlet', $off && !$o{S1} && $o{S2});
    my ($neg) = read_phc("NODE A 0\nWATER W 0 500\nUSE BORE 120\nPIPE P1 W A 1000 100\nSPRINKLER S1 0 81 8\n"
                       . "PIPE P2 A S1 1000 50\nHYDRANT H1 0 -200 21\nPIPE P3 A H1 1000 80\n");
    my %e = elems_by_id($neg);
    is('MINFLOW: 81 is a least flow of 81; -200 a least pressure of 200',
       $e{S1}{qreq} == 81 && abs($e{S1}{preq} - (81 / 8) ** 2) < 1e-9 && $e{H1}{preq} == 200);
    my $m = eval { HardyCross::Parse::read_model("$EX/01_single_branch.phc") };
    is('read_model dispatches .phc to the .phc reader', $m && $m->{phc_text});
}

#==============================================================================
print "8. FIXED FLOWS - the minimum pressure is checked and can govern\n";
#==============================================================================
{
    # C is 20 m above the supply, so the fixed flow there has the least
    # pressure to spare, and governs.
    my $m = join "\n", 'NODE A 0', 'NODE C 20', 'WATER W 0 600', 'USE BORE 120',
        'PIPE P1 W A 50000 100', 'SPRINKLER S 0 -50 80', 'PIPE P3 A S 1000 50', 'PIPE P2 A C 30000 50', '';
    my ($net, $err) = read_phc($m . "FIXEDFLOW F C 100 250\n");
    is('FIXEDFLOW with a minimum pressure reads', $net, $err);
    my $ok = HardyCross::solve_model($net);
    my $f = $net->{fixed}[0];
    is('   kept by its own name, on its node, with its minimum', $f && $f->{id} eq 'F' && $f->{preq} == 250);
    my ($gov) = HardyCross::Demand::governing_outlet($net);
    is('   it governs (least margin)', $gov && $gov->{id} eq 'F', $gov && $gov->{id});
    my $dm = HardyCross::Demand::demand_point($net);
    my ($df) = @{ $dm->{net}{fixed} || [] };
    my $pf = $df ? HardyCross::Demand::gauge($dm->{net}, $df->{n1}) : -1;
    is(sprintf('   at the demand point it has exactly its minimum (%.2f kPa)', $pf), abs($pf - 250) < 0.05);
    my $rep = HardyCross::Report::write_report($net, $ok, 'm.phc');
    is('   report section 7 lists it, K fixed, PASS', $rep =~ /^ F\s+C\s+fixed\s+100\.0\s+100\.0\s+250\.0\s+[\d.]+\s+PASS$/m);
    my ($bad) = read_phc($m . "FIXEDFLOW F C 100 900\n");
    my $rb = HardyCross::Report::write_report($bad, HardyCross::solve_model($bad), 'm.phc');
    is('a minimum above the pressure available FAILS', $rb =~ /^ F\s+C\s+fixed.*\*\*\* FAIL$/m);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
