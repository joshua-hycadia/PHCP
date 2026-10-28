#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# stress_invariance.pl -- stress the Perl engine with tests that need no
# reference answer.
#
# WHY INVARIANCE
#   A comparison against another program catches a wrong answer only where
#   the two disagree -- and a mistake both share, or a case the other program
#   cannot express, sails through.  An invariance test instead
#   asks the engine to agree WITH ITSELF: take one network, describe it a
#   different way that does not change the physics, and demand the same answer.
#   Any disagreement is a bug by construction, with no reference needed.
#
#   The transforms, and why each is a real test:
#     shuffle     list the elements in a different order.  Changes the tree,
#                 every loop, and the order corrections are applied in.
#     reverse     draw a pipe the other way round.  Its flow must flip sign
#                 and nothing else may move.  Catches any sign slip in the
#                 head-loss or derivative code.
#     datum       raise the whole site.  Gauge pressures and flows must not
#                 change; total heads must rise by exactly gamma * dz.
#     split       cut a pipe in two with a node in the middle.  Friction is
#                 linear in length, so the flows must not change.
#     rename      give every node a different name.  Catches anything keyed
#                 on a name that should not be.
#     units       express the same model in L/s, bar, mm, cm and inches.  Catches a
#                 conversion factor missing on any one quantity.
#     repeat      solve the identical text twice.  The answers must be the
#                 same bytes -- no hidden state between solves.
#
#   Every solve is also checked directly: continuity at every node, closure
#   around every loop, and no non-finite number anywhere.
#
#     perl tools/stress_invariance.pl [cases] [seed]
#==============================================================================

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::PipeData;
use List::Util qw(shuffle max);

my $CASES = shift // 60;
my $SEED  = shift // 20260921;
srand $SEED;

my (%fail_by, $checks, $fails, @failures);
sub check {
    my ($what, $ok, $detail) = @_;
    $checks++;
    return 1 if $ok;
    $fails++;
    $fail_by{$what}++;
    push @failures, "$what: $detail" if @failures < 25;
    return 0;
}

#------------------------------------------------------------------------------
# A random looped network.  Grid-based so it always has real loops, with
# random extra chords, a mix of pipe sizes, two supplies (one static, one on a
# falling curve -- so there is a pseudo-loop), pressure-dependent outlets, a
# fixed-flow demand, and sometimes Darcy-Weisbach.
#
# The model is held as parts, so a transform can change one kind of line
# without parsing text back:
#   units     [quantity, unit] for each UNITS line
#   settings  the METHOD and OPTION lines
#   nodes     [command, name, elevation, fields ...]: NODE, WATER, SPRINKLER,
#             HYDRANT -- each defines its node
#   pipes     { id, a, b, len, size, c, eqv }: written as a USE BORE line (the
#             C factor, or the roughness under Darcy-Weisbach), the PIPE line
#             and an EQV line, kept together because a USE applies to the
#             pipes after it
#   fixed     [name, node, flow] for each FIXEDFLOW
# render() writes it as .phc text.
#------------------------------------------------------------------------------
sub random_model {
    my $r = 2 + int rand 4;          # 2..5 rows
    my $c = 2 + int rand 4;          # 2..5 cols
    my $dw = rand() < 0.3;
    my (@names, @pipes);
    for my $i (0 .. $r - 1) {
        push @names, "N${i}_$_" for 0 .. $c - 1;
    }
    my %z = map { $_ => sprintf '%.2f', rand 12 } @names;
    my $pid = 0;
    my @dia = (50, 65, 80, 100, 150);
    my $pipe = sub {
        my ($a, $b) = @_;
        $pid++;
        push @pipes, { id => "P$pid", a => $a, b => $b, len => sprintf('%.2f', 3 + rand 40),
                       size => $dia[ int rand @dia ],
                       c => $dw ? sprintf('%.3f', 0.01 + rand 0.2) : 100 + 10 * int(rand 5),
                       eqv => rand() < 0.4 ? sprintf('%.2f', rand 8) : undef };
    };
    for my $i (0 .. $r - 1) {
        for my $j (0 .. $c - 1) {
            $pipe->("N${i}_$j", "N${i}_" . ($j + 1)) if $j + 1 < $c;
            $pipe->("N${i}_$j", 'N' . ($i + 1) . "_$j") if $i + 1 < $r;
        }
    }
    for (1 .. int rand 3) {          # a few diagonal chords
        my ($a, $b) = ($names[ int rand @names ], $names[ int rand @names ]);
        $pipe->($a, $b) if $a ne $b;
    }
    # Each node is defined by what is at it: the two supplies, the outlets,
    # and plain junctions everywhere else.  An outlet's minimum is a pressure,
    # given as a negative MINFLOW.
    my %at;
    $at{ $names[0] } = [ 'WATER', sprintf('%.0f', 900 + rand 600) ];
    $at{ $names[ $c - 1 ] } = [ 'WATER', sprintf('%.0f', 800 + rand 400),
                                2000, sprintf('%.0f', 500 + rand 200),
                                4000, sprintf('%.0f', 200 + rand 150) ];
    $at{ $names[-1] } = [ 'SPRINKLER', -50, sprintf('%.1f', 60 + rand 60) ];
    $at{ $names[ int(@names / 2) ] } = [ 'HYDRANT', -100, sprintf('%.1f', 50 + rand 80) ]
        if @names > 4;
    my @nodes = map { my ($cmd, @f) = @{ $at{$_} || ['NODE'] }; [ $cmd, $_, $z{$_}, @f ] } @names;
    return {
        units    => [ [qw(FLOW LPM)], [qw(PRESSURE KPA)], [qw(LENGTH M)], [qw(ELEVATION M)],
                      [qw(SIZE MM)], [ 'KFACTOR', 'LPM/KPA' ] ],
        settings => [ 'METHOD ' . ($dw ? 'DW' : 'HW'), 'OPTION TOL_FLOW 1E-7',
                      'OPTION TOL_LOOP 1E-8', 'OPTION MAXITER 200000' ],
        nodes    => \@nodes,
        pipes    => \@pipes,
        fixed    => [ [ 'F1', $names[1], sprintf('%.0f', 100 + rand 400) ] ],
    };
}

# render -- the model as .phc text.
sub render {
    my $m = shift;
    my @l = ((map { "UNITS @$_" } @{ $m->{units} }), @{ $m->{settings} },
             (map { join ' ', @$_ } @{ $m->{nodes} }));
    for my $p (@{ $m->{pipes} }) {
        push @l, "USE BORE $p->{c}", "PIPE $p->{id} $p->{a} $p->{b} $p->{len} $p->{size}";
        push @l, "EQV $p->{id} $p->{eqv}" if defined $p->{eqv};
    }
    push @l, map { "FIXEDFLOW @$_" } @{ $m->{fixed} };
    return join '', map { "$_\n" } @l;
}

# copy -- a deep copy of a model, for a transform to change.
sub copy {
    my $m = shift;
    return { units => [ map { [@$_] } @{ $m->{units} } ], settings => [ @{ $m->{settings} } ],
             nodes => [ map { [@$_] } @{ $m->{nodes} } ], pipes => [ map { {%$_} } @{ $m->{pipes} } ],
             fixed => [ map { [@$_] } @{ $m->{fixed} } ] };
}

#------------------------------------------------------------------------------
sub solve {
    my $text = shift;
    my $net = eval { HardyCross::Phc::read_string($text) } or return (undef, $@);
    my $ok  = eval { HardyCross::solve_model($net) };
    return (undef, $@) unless defined $ok;
    return ($net, $ok);
}

sub flows {
    my $net = shift;
    my %q;
    $q{ $_->{id} } = $_->{q} for @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    return \%q;
}
sub gauge {
    my $net = shift;
    my %p;
    for my $n (@{ $net->{nodes} }[1 .. $#{ $net->{nodes} }]) {
        next if $n->{id} eq 'REF';
        $p{ $n->{id} } = $n->{h} - $HardyCross::GAMMA_W * $n->{z};
    }
    return \%p;
}

# The worst disagreement between two flow maps, over the keys they share.
sub worst {
    my ($a, $b, $map) = @_;
    my $w = 0;
    for my $k (keys %$a) {
        my $kb = $map ? $map->($k) : $k;
        return 1e30 unless exists $b->{$kb};
        my $d = abs($a->{$k} - $b->{$kb});
        $w = $d if $d > $w;
    }
    return $w;
}

# Direct checks on one solution, independent of any other solve.
sub audit {
    my ($tag, $net) = @_;
    my $finite = 1;
    for my $e (@{ $net->{elems} }[1 .. $#{ $net->{elems} }]) {
        $finite = 0 if $e->{q} != $e->{q} || abs($e->{q}) > 1e12;
    }
    for my $n (@{ $net->{nodes} }[1 .. $#{ $net->{nodes} }]) {
        $finite = 0 if $n->{h} != $n->{h} || abs($n->{h}) > 1e12;
    }
    check('finite', $finite, "$tag: a NaN or runaway value in the solution");
    my $cont = HardyCross::continuity_error($net);
    check('continuity', $cont < 1e-6, sprintf("%s: continuity %.2e L/min", $tag, $cont));
    my $wl = 0;
    for my $lp (@{ $net->{loops} }) {
        my $s = 0;
        for my $st (@$lp) {
            my $e = $net->{elems}[ $st->[0] ];
            my ($hf) = HardyCross::elem_hf($e, $e->{q}, $net->{opts});
            $s += $st->[1] * $hf;
        }
        $wl = abs $s if abs $s > $wl;
    }
    check('loop closure', $wl < 1e-4, sprintf("%s: worst loop closure %.2e kPa", $tag, $wl));
}

#------------------------------------------------------------------------------
# Transforms.  Each takes a model and returns the new .phc text, plus how to
# map an id across where one changes.
#------------------------------------------------------------------------------
sub t_shuffle {
    my $m = copy(shift);
    # Every line in a different order; a pipe keeps its USE line in front.
    $m->{$_} = [ shuffle @{ $m->{$_} } ] for qw(nodes pipes settings units);
    return render($m);
}

sub t_reverse {
    my $m = copy(shift);
    my %rev;
    for my $p (@{ $m->{pipes} }) {
        next unless rand() < 0.5;
        @{$p}{qw(a b)} = @{$p}{qw(b a)};
        $rev{ $p->{id} } = 1;
    }
    return (render($m), \%rev);
}

sub t_datum {
    my ($m, $dz) = @_;
    $m = copy($m);
    $_->[2] = sprintf '%.4f', $_->[2] + $dz for @{ $m->{nodes} };
    return render($m);
}

sub t_split {
    my $m = copy(shift);
    my $p = $m->{pipes}[ int rand @{ $m->{pipes} } ];
    my $f = 0.2 + rand 0.6;
    # The fitting allowance stays on the first half; it is a length like any
    # other, so where it sits along the pipe cannot change the flow.
    push @{ $m->{pipes} }, { %$p, id => "$p->{id}B", a => 'MIDSPLIT',
                             len => sprintf('%.6f', $p->{len} * (1 - $f)), eqv => undef };
    @{$p}{qw(b len)} = ('MIDSPLIT', sprintf '%.6f', $p->{len} * $f);
    push @{ $m->{nodes} }, [ 'NODE', 'MIDSPLIT', '5.0' ];
    return (render($m), $p->{id});
}

# rename_id -- the new name of a node (and of the supply or outlet at it).
sub rename_id { (my $k = shift) =~ s/\bN(\d+)_(\d+)\b/JX$2Y$1/g; $k }
sub t_rename { return rename_id(render(shift)) }

sub t_units {
    my $m = copy(shift);
    # L/s, bar, mm lengths, cm elevations, inch bores, K in L/s per root bar:
    # every quantity in a different unit.
    my ($qf, $pf, $lf, $zf, $sf) = (1 / 60, 1 / 100, 1000, 100, 1 / 25.4);
    my $kf = $qf / sqrt $pf;
    $m->{units} = [ [qw(FLOW LPS)], [qw(PRESSURE BAR)], [qw(LENGTH MM)], [qw(ELEVATION CM)],
                    [qw(SIZE IN)], [ 'KFACTOR', 'LPS/BAR' ] ];
    for (@{ $m->{settings} }) {
        s/TOL_FLOW (\S+)/'TOL_FLOW ' . $1 * $qf/e;
        s/TOL_LOOP (\S+)/'TOL_LOOP ' . $1 * $pf/e;
    }
    for my $n (@{ $m->{nodes} }) {
        my ($cmd, $name, $z, @f) = @$n;
        $z *= $zf;
        if ($cmd eq 'WATER') {
            $f[0] *= $pf;
            for (my $k = 1; $k + 1 <= $#f; $k += 2) { $f[$k] *= $qf; $f[ $k + 1 ] *= $pf }
        } elsif ($cmd ne 'NODE') {
            $f[0] *= $f[0] < 0 ? $pf : $qf;
            $f[1] *= $kf;
        }
        @$n = ($cmd, $name, $z, @f);
    }
    for my $p (@{ $m->{pipes} }) {
        $p->{len} *= $lf;
        $p->{eqv} *= $lf if defined $p->{eqv};
        $p->{size} *= $sf;
        $p->{c} *= $sf if $m->{settings}[0] eq 'METHOD DW';
    }
    $_->[2] *= $qf for @{ $m->{fixed} };
    return render($m);
}

#------------------------------------------------------------------------------
print "HARDY CROSS PERL ENGINE - INVARIANCE STRESS\n";
printf "cases %d, seed %d\n\n", $CASES, $SEED;

my %worst;
my ($solved, $notconv) = (0, 0);
for my $case (1 .. $CASES) {
    my $base = random_model();
    my ($n0, $ok0) = solve(render($base));
    unless ($n0) {
        check('base solve', 0, "case $case: " . (ref $ok0 ? $ok0->{msg} : $ok0));
        next;
    }
    $notconv++, next unless $ok0;
    $solved++;
    audit("case $case base", $n0);
    my ($q0, $p0) = (flows($n0), gauge($n0));
    my $tag = "case $case";

    # repeat: identical text, identical answer
    my ($nr) = solve(render($base));
    my $wr = worst($q0, flows($nr));
    check('repeat', $wr == 0, sprintf("%s: second solve differs by %.2e", $tag, $wr));
    $worst{repeat} = max($worst{repeat} // 0, $wr);

    # shuffle
    my ($ns) = solve(t_shuffle($base));
    if ($ns) {
        audit("$tag shuffle", $ns);
        my $w = worst($q0, flows($ns));
        check('shuffle', $w < 1e-3, sprintf("%s: flows moved %.2e L/min", $tag, $w));
        $worst{shuffle} = max($worst{shuffle} // 0, $w);
    } else { check('shuffle', 0, "$tag: shuffled model did not solve") }

    # reverse
    my ($rtxt, $rev) = t_reverse($base);
    my ($nv) = solve($rtxt);
    if ($nv) {
        my $qv = flows($nv);
        my $w = 0;
        for my $k (keys %$q0) {
            my $want = $rev->{$k} ? -$q0->{$k} : $q0->{$k};
            $w = max($w, abs($qv->{$k} - $want));
        }
        check('reverse', $w < 1e-3, sprintf("%s: reversed pipes off by %.2e L/min", $tag, $w));
        $worst{reverse} = max($worst{reverse} // 0, $w);
    } else { check('reverse', 0, "$tag: reversed model did not solve") }

    # datum
    my $dz = -20 + rand 60;
    my ($nd) = solve(t_datum($base, $dz));
    if ($nd) {
        my $wq = worst($q0, flows($nd));
        my $wp = worst($p0, gauge($nd));
        check('datum', $wq < 1e-3 && $wp < 1e-3,
              sprintf("%s: raising the site %.1f m moved flows %.2e, pressures %.2e", $tag, $dz, $wq, $wp));
        $worst{datum} = max($worst{datum} // 0, $wq);
    } else { check('datum', 0, "$tag: datum-shifted model did not solve") }

    # split
    my ($stxt, $sid) = t_split($base);
    my ($nsp) = solve($stxt);
    if ($nsp) {
        my $qs = flows($nsp);
        my $w = 0;
        for my $k (keys %$q0) { $w = max($w, abs($qs->{$k} - $q0->{$k})) }
        $w = max($w, abs($qs->{"${sid}B"} - $q0->{$sid}));   # the new half carries the same flow
        check('split', $w < 1e-3, sprintf("%s: splitting %s moved flows %.2e L/min", $tag, $sid, $w));
        $worst{split} = max($worst{split} // 0, $w);
    } else { check('split', 0, "$tag: split model did not solve") }

    # rename
    my ($nn) = solve(t_rename($base));
    if ($nn) {
        my $w = worst($q0, flows($nn), \&rename_id);
        check('rename', $w < 1e-3, sprintf("%s: renaming nodes moved flows %.2e", $tag, $w));
        $worst{rename} = max($worst{rename} // 0, $w);
    } else { check('rename', 0, "$tag: renamed model did not solve") }

    # units
    my ($nu, $oku) = solve(t_units($base));
    if ($nu) {
        my $qu = flows($nu);        # internal L/min regardless of input units
        my $w = worst($q0, $qu);
        my $pu = gauge($nu);
        my $wp = worst($p0, $pu);
        check('units', $w < 1e-2 && $wp < 1e-2,
              sprintf("%s: L/s-bar-mm-cm-in model differs by %.2e L/min, %.2e kPa", $tag, $w, $wp));
        $worst{units} = max($worst{units} // 0, $w);
    } else { check('units', 0, "$tag: unit-converted model did not solve: " .
                               (ref $oku ? $oku->{msg} : $oku // '')) }
}

#------------------------------------------------------------------------------
# The pipe database resolver, fuzzed.  It must never return a number for a
# fitting the database does not hold, never die on bad input, and its total must
# always equal the sum of its records.
#------------------------------------------------------------------------------
print "PIPE DATABASE RESOLVER FUZZ\n";
HardyCross::PipeData::load();
my @types = HardyCross::PipeData::pipe_types();
my @codes = ((qw(E E45 T GV CV)) x 6, qw(EF EL GV75 GV50 GV25 CVM CVB BV AV GLV TR CPL EM1 EM3 E15 XX Q9));
# steel sizes weighted up; PE sizes and a nonsense DN kept for the refusal path
my @dns   = ((25, 32, 40, 50, 65, 80, 100, 150, 200, 250, 300) x 3,
             15, 20, 125, 350, 400, 450, 500, 600, 75, 90, 110, 999);
my ($rn, $rdash, $rok) = (0, 0, 0);
for (1 .. 4000) {
    my $type = $types[ int rand @types ];
    my $dn   = $dns[ int rand @dns ];
    my $spec = join((rand() < 0.5 ? ',' : ''),
                    map { (int(rand 4) || '') . $codes[ int rand @codes ] } 1 .. 1 + int rand 4);
    $spec = join '', map { chr(33 + int rand 90) } 1 .. 1 + int rand 8 if rand() < 0.05;
    my $r = eval { HardyCross::PipeData::resolve(type => $type, dn => $dn, spec => $spec) };
    $rn++;
    check('resolver never dies', defined $r, "resolve($type, DN$dn, '$spec') died: $@") or next;
    my $any_dr = grep { ($_->{status} // '') eq 'DATA_REQUIRED' } @{ $r->{records} };
    if ($any_dr || @{ $r->{errors} }) {
        $rdash++;
        check('gap is never a number', !defined $r->{total},
              "resolve($type, DN$dn, '$spec') returned " . ($r->{total} // 'undef') . " despite a gap");
    } else {
        $rok++;
        my $sum = 0;
        $sum += $_->{total} // 0 for @{ $r->{records} };
        check('total = sum of records', abs($sum - ($r->{total} // -1)) < 1e-9,
              "resolve($type, DN$dn, '$spec'): total " . ($r->{total} // 'undef') . " vs sum $sum");
        check('allowance never negative', ($r->{total} // 0) >= 0,
              "resolve($type, DN$dn, '$spec') negative");
    }
}
printf "  %d strings: %d resolved, %d refused as DATA_REQUIRED or invalid\n\n", $rn, $rok, $rdash;

#------------------------------------------------------------------------------
print "RESULTS\n";
printf "  %d random networks, %d converged, %d did not\n", $CASES, $solved, $notconv;
print "\n  worst disagreement per transform (L/min)\n";
printf "    %-10s %.3e\n", $_, $worst{$_} for sort keys %worst;
printf "\n  %d checks, %d failed\n", $checks, $fails // 0;
if (%fail_by) {
    print "\n  failures by kind\n";
    printf "    %-28s %d\n", $_, $fail_by{$_} for sort keys %fail_by;
    print "\n  first failures\n";
    print "    $_\n" for @failures;
}
exit($fails ? 1 : 0);
