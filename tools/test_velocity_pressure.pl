#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_velocity_pressure.pl -- OPTION VELOCITY_PRESSURE, AS 2118.1 Cl 14.15.
#
#   perl tools/test_velocity_pressure.pl           # the checks
#   perl tools/test_velocity_pressure.pl --freeze  # write the OFF fingerprint
#
# Four parts:
#   1. A HAND CHECK.  A three-head range worked from the end head back to the
#      supply the way a checker does it with a calculator -- end head on total
#      pressure, each in-line head on Pn = Pt - Pv with Pv from the pipe
#      feeding it, found by trial -- written here without the engine.  The
#      supply pressure that gives is put into a model, solved with the option
#      ON, and must give back the same flows.
#   2. OFF CHANGES NOTHING.  Every example solves to exactly the same flows and
#      pressures with no option, with OPTION VELOCITY_PRESSURE OFF, and as
#      frozen from the solver before the option existed
#      (tools/baseline/velocity_pressure_off.txt, written by --freeze on that
#      solver).  No outlet carries a velocity pressure.
#   3. ON AGAINST OFF on the examples: ON converges; every in-line sprinkler
#      meets q = K sqrt(Pt - Pv) with Pv = 0.5 v^2 of its feed pipe; end
#      sprinklers, hydrants and hose reels stay on Pt; and the table of total
#      sprinkler flow, ON against OFF, is printed for the pull request.
#   4. THE LANGUAGE AND THE OUTPUT.  A bad value is refused on its line; the
#      report, the editor's outlet table and the JSON state the basis.
#
# Example 04 (the 1000-pipe grid) is left out: one solve of it takes some 37
# minutes, and 02, 07 and 11 already have loops and in-line heads.  Its OFF
# results are checked by test_phc.pl --full.
#==============================================================================
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Parse;
use HardyCross::Phc;

my $FREEZE = grep { $_ eq '--freeze' } @ARGV;
my $EX     = "$FindBin::Bin/../examples";
my $FROZEN = "$FindBin::Bin/baseline/velocity_pressure_off.txt";
my $GW     = $HardyCross::GAMMA_W;
my ($pass, $fail) = (0, 0);

sub is {
    my ($name, $ok, $why) = @_;
    printf "  %-68s %s\n", $name, $ok ? 'ok' : '*** FAIL';
    print "      $why\n" if !$ok && defined $why;
    $ok ? $pass++ : $fail++;
}
sub slurp { my $p = shift; open my $f, '<', $p or die "$p: $!\n"; local $/; <$f> }
sub read_phc {
    my $net = eval { HardyCross::Phc::read_string(shift) };
    return ($net, undef) if $net;
    my $e = $@;
    return (undef, HardyCross::is_model_error($e) ? $e->{msg} : "$e");
}
sub elems { my $n = shift; @{ $n->{elems} }[1 .. $#{ $n->{elems} }] }
sub pipe_q { my $n = shift; map { $_->{id} => $_->{q} } grep { $_->{kind} eq 'PIPE' } elems($n) }
sub node_p { my $n = shift; map { $_->{id} => $_->{h} - $GW * $_->{z} } grep { $_->{id} ne 'REF' } @{ $n->{nodes} }[1 .. $#{ $n->{nodes} }] }

my @examples = grep { !/grid1000/ } sort glob("$EX/*.phc");

#------------------------------------------------------------------------------
# --freeze: every example's solved flows and pressures, to 12 significant
# figures.  Run on the solver BEFORE the option, so part 2 compares with it.
#------------------------------------------------------------------------------
if ($FREEZE) {
    open my $o, '>', $FROZEN or die "$FROZEN: $!\n";
    print $o "# Solved pipe flows (Q, L/min) and node gauge pressures (P, kPa) of every example\n"
           . "# frozen from the solver before OPTION VELOCITY_PRESSURE existed (example 04 is not included).\n"
           . "# With the option OFF, or not given, every example must still give these.\n";
    for my $m (@examples) {
        (my $b = $m) =~ s{.*/}{};
        my ($n) = read_phc(slurp($m));
        HardyCross::solve_model($n);
        my %q = pipe_q($n); my %p = node_p($n);
        printf $o "Q %s %s %.12g\n", $b, $_, $q{$_} for sort keys %q;
        printf $o "P %s %s %.12g\n", $b, $_, $p{$_} for sort keys %p;
    }
    close $o;
    print "wrote $FROZEN\n";
    exit 0;
}

#==============================================================================
print "1. HAND CHECK - three heads on one range, worked from the end head\n";
#==============================================================================
# The range: supply A, then H3, H2, H1 along it, each pipe 3.0 m, all at
# datum, C = 120, no fittings.  P1 A-H3 is 36.0 mm bore; P2 H3-H2 and P3
# H2-H1 are 27.0 mm.  K8.0 heads (L/min/kPa^0.5).  H1 is the end head.
{
    my ($K, $C, $L) = (8.0, 120, 3.0);
    # AS 2118.1 Hazen-Williams, kPa: 6.05e7 L Q^1.85 / (C^1.85 d^4.87).
    my $hw = sub { my ($q, $d) = @_; 6.05e7 * $L * $q ** 1.85 / ($C ** 1.85 * $d ** 4.87) };
    # Pv = rho v^2 / 2 in kPa, v in m/s from L/min and mm.
    my $pv = sub { my ($q, $d) = @_; my $v = ($q / 60000) / (3.14159265358979 * ($d / 1000) ** 2 / 4); 0.5 * $v ** 2 };
    # An in-line head: q = K sqrt(Pt - Pv), Pv from the pipe feeding it,
    # which carries q itself plus everything beyond -- so found by trial.
    my $inline = sub {
        my ($pt, $beyond, $d) = @_;
        my $q = $K * sqrt($pt);
        $q = $K * sqrt($pt - $pv->($q + $beyond, $d)) for 1 .. 200;
        return ($q, $pv->($q + $beyond, $d));
    };
    my $pt1 = 100;                                   # end head, chosen
    my $q1  = $K * sqrt($pt1);                       # on total pressure
    my $pt2 = $pt1 + $hw->($q1, 27.0);
    my ($q2, $pv2) = $inline->($pt2, $q1, 27.0);     # fed by P2
    my $pt3 = $pt2 + $hw->($q1 + $q2, 27.0);
    my ($q3, $pv3) = $inline->($pt3, $q1 + $q2, 36.0);   # fed by P1
    my $qt  = $q1 + $q2 + $q3;
    my $pa  = $pt3 + $hw->($qt, 36.0);
    printf "      by hand: q1 %.3f (Pt %.3f)  q2 %.3f (Pt %.3f Pv %.3f)  q3 %.3f (Pt %.3f Pv %.3f)  supply %.3f kPa\n",
        $q1, $pt1, $q2, $pt2, $pv2, $q3, $pt3, $pv3, $pa;

    my $model = join "\n", 'UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
        'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW',
        'OPTION TOL_FLOW 1E-7', 'OPTION TOL_LOOP 1E-8', 'OPTION MAXITER 200000',
        sprintf('WATER A 0 %.10f', $pa),
        'SPRINKLER H3 0 50 8.0', 'SPRINKLER H2 0 50 8.0', 'SPRINKLER H1 0 50 8.0',
        'USE BORE 120', 'PIPE P1 A H3 3.0 36.0', 'PIPE P2 H3 H2 3.0 27.0', 'PIPE P3 H2 H1 3.0 27.0', '';

    my ($on, $err) = read_phc("$model\nOPTION VELOCITY_PRESSURE ON\n");
    is('the hand-check model reads', $on, $err);
    if ($on) {
        is('   solved with the option ON, it converges', HardyCross::solve_model($on));
        my %e = map { $_->{id} => $_ } elems($on);
        my %q = pipe_q($on);
        my $d = 0;
        for ([ $q{P3}, $q1 ], [ $q{P2}, $q1 + $q2 ], [ $q{P1}, $qt ],
             [ abs $e{H1}{q}, $q1 ], [ abs $e{H2}{q}, $q2 ], [ abs $e{H3}{q}, $q3 ]) {
            $d = abs($_->[0] - $_->[1]) if abs($_->[0] - $_->[1]) > $d;
        }
        is(sprintf('   every flow agrees with the hand calculation, worst %.1e L/min', $d), $d < 1e-3);
        is('   H1, the end head: on total pressure, no Pv', !$e{H1}{pv} && $e{H1}{pv_end});
        is(sprintf('   H2: Pv %.4f from pipe P2, as by hand (%.4f)', $e{H2}{pv} // 0, $pv2),
           abs(($e{H2}{pv} // 0) - $pv2) < 1e-4 && ($e{H2}{pv_pipe} // '') eq 'P2');
        is(sprintf('   H3: Pv %.4f from pipe P1, as by hand (%.4f)', $e{H3}{pv} // 0, $pv3),
           abs(($e{H3}{pv} // 0) - $pv3) < 1e-4 && ($e{H3}{pv_pipe} // '') eq 'P1');
        is('   outlet_pressure of an in-line head is Pt - Pv',
           abs(HardyCross::outlet_pressure($on, $e{H2}) - ($pt2 - $pv2)) < 1e-4);
    }
    # The same supply with the option OFF: every head on Pt, so each flows
    # more, and the total is larger.
    my ($off) = read_phc($model);
    if ($off) {
        HardyCross::solve_model($off);
        my %q = pipe_q($off);
        printf "      OFF at the same supply: total %.3f L/min against %.3f ON (+%.2f %%)\n",
            $q{P1}, $qt, 100 * ($q{P1} / $qt - 1);
        is('   OFF at the same supply: more water, since no head is on Pn', $q{P1} > $qt + 1);
    }
}

#==============================================================================
print "\n2. OFF CHANGES NOTHING - every example as before the option existed\n";
#==============================================================================
{
    my %frozen;
    for (split /\n/, slurp($FROZEN)) {
        next if /^#/ || !/\S/;
        my ($k, $b, $id, $v) = split ' ';
        $frozen{$b}{"$k $id"} = $v;
    }
    for my $m (@examples) {
        (my $b = $m) =~ s{.*/}{};
        my $text = slurp($m);
        my ($a) = read_phc($text);
        my ($o) = read_phc("$text\nOPTION VELOCITY_PRESSURE OFF\n");
        HardyCross::solve_model($_) for $a, $o;
        my (%qa, %qo, %pa, %po);
        %qa = pipe_q($a); %qo = pipe_q($o); %pa = node_p($a); %po = node_p($o);
        # Bit for bit: the same solver path, run twice in one process.
        my $same = !grep({ $qa{$_} != $qo{$_} } keys %qa) && !grep({ $pa{$_} != $po{$_} } keys %pa)
                && $a->{iters} == $o->{iters};
        is("$b: no option and OPTION VELOCITY_PRESSURE OFF are identical", $same);
        is('   no outlet carries a velocity pressure', !grep { exists $_->{pv} } elems($a), elems($o));
        # Against the solver before the option: 12 significant figures, so a
        # last-bit difference in a maths library elsewhere cannot fail it.
        my $f = $frozen{$b};
        if (!$f) { is("   frozen results present for $b", 0); next }
        my ($worst, $missing) = (0, 0);
        for my $key (keys %$f) {
            my ($k, $id) = split ' ', $key;
            my $now = $k eq 'Q' ? $qa{$id} : $pa{$id};
            if (!defined $now) { $missing++; next }
            my $rel = abs($now - $f->{$key}) / (abs($f->{$key}) > 1 ? abs($f->{$key}) : 1);
            $worst = $rel if $rel > $worst;
        }
        is(sprintf('   as frozen before the option: worst relative difference %.1e', $worst),
           !$missing && $worst < 1e-10, $missing ? "$missing frozen ids not in the model" : undef);
    }
}

#==============================================================================
print "\n3. ON AGAINST OFF on the examples\n";
#==============================================================================
{
    my @table;
    for my $m (@examples) {
        (my $b = $m) =~ s{.*/}{};
        my $text = slurp($m);
        my ($off) = read_phc($text);
        my ($on)  = read_phc("$text\nOPTION VELOCITY_PRESSURE ON\n");
        my $okf = HardyCross::solve_model($off);
        my $ok  = HardyCross::solve_model($on);
        is("$b: ON converges", !$okf || $ok);
        my @spk = grep { $_->{kind} eq 'DISCHARGE' && $_->{otype} eq 'SPRINKLER' } elems($on);
        my @oth = grep { $_->{kind} eq 'DISCHARGE' && $_->{otype} ne 'SPRINKLER' } elems($on);
        # The rule, checked against the solved network rather than the
        # engine's own bookkeeping: each sprinkler's feed pipe found again
        # here, and its discharge worked on Pt - 0.5 v^2.
        my ($bad, $inl) = (0, 0);
        my $tol = $on->{opts}{tol_loop} // 0.01;
        for my $s (@spk) {
            my ($feed, $fq, $out) = (undef, 0, 0);
            for my $e (elems($on)) {
                next if $e->{closed} || $e->{kind} eq 'DISCHARGE' || abs($e->{q}) <= 1e-6;
                my ($to, $from) = $e->{q} > 0 ? ($e->{n2}, $e->{n1}) : ($e->{n1}, $e->{n2});
                $out = 1 if $from == $s->{n1};
                ($feed, $fq) = ($e, abs $e->{q}) if $to == $s->{n1} && $e->{kind} eq 'PIPE' && abs($e->{q}) > $fq;
            }
            my $v  = $feed && $out ? HardyCross::pipe_velocity($fq, $feed->{dia}) : 0;
            my $pv = 0.5 * $v ** 2;
            $inl++ if $pv > 0;
            my $pt = $on->{nodes}[ $s->{n1} ]{h} - $GW * $s->{z};
            my $want = $s->{k} * sqrt($pt - $pv > 0 ? $pt - $pv : 0);
            # Pv is held from the last pass, so the flow it gives agrees to
            # within what the loop tolerance allows.
            $bad++ if abs(abs($s->{q}) - $want) > 0.05 + $s->{k} * $tol || abs(($s->{pv} // 0) - $pv) > 2 * $tol;
        }
        is(sprintf('   %d sprinkler(s), %d in-line: each q = K sqrt(Pt - Pv), end heads on Pt', scalar @spk, $inl), !$bad);
        is('   hydrants and hose reels: no velocity pressure', !grep { $_->{pv} } @oth);
        my $sum = sub { my $n = shift; my $t = 0; $t += abs $_->{q} for grep { $_->{kind} eq 'DISCHARGE' && $_->{otype} eq 'SPRINKLER' } elems($n); $t };
        push @table, [ $b, scalar @spk, $inl, $sum->($off), $sum->($on) ] if @spk;
    }
    print "\n      EXAMPLE                        HEADS  IN-LINE   SPRINKLER FLOW OFF    ON      CHANGE\n";
    printf "      %-30s %5d  %7d   %18.1f %9.1f  %+7.2f %%\n", @$_[0 .. 4], 100 * ($_->[4] / $_->[3] - 1)
        for @table;
    print "      (L/min at the operating point, each example's own supply.)\n";
}

#==============================================================================
print "\n4. THE LANGUAGE AND THE OUTPUT\n";
#==============================================================================
{
    my ($n, $err) = read_phc("WATER W 0 500\nSPRINKLER S1 0 -50 8\nUSE BORE 120\nPIPE P1 W S1 10 25\nOPTION VELOCITY_PRESSURE MAYBE\n");
    is('OPTION VELOCITY_PRESSURE MAYBE is refused on its line',
       !$n && ($err // '') =~ /^line 5: .*VELOCITY_PRESSURE IS ON .* OR OFF/, $err);
    my ($l) = read_phc("WATER W 0 500\nSPRINKLER S1 0 -50 8\nUSE BORE 120\nPIPE P1 W S1 10 25\nOPTION VELOCITY_PRESSURE on\n");
    is('   lower case is read the same', $l && $l->{opts}{vel_press});
    is('   it is in the option list the editor offers', grep { $_ eq 'VELOCITY_PRESSURE' } @HardyCross::Phc::OPTIONS);

    require HardyCross::Report;
    require HardyCross::Json;
    my $text = slurp("$EX/07_pipe_database_demo.phc");
    for my $case ([ 'OFF', $text, 0 ], [ 'ON', "$text\nOPTION VELOCITY_PRESSURE ON\n", 1 ]) {
        my ($name, $t, $want) = @$case;
        my ($net) = read_phc($t);
        $net->{source_text} = $t;
        my $ok = HardyCross::solve_model($net);
        my $rep = HardyCross::Report::write_report($net, $ok, '07.phc');
        is("report, $name: the cover sheet states the basis",
           $rep =~ /Velocity pressure\s+: \Q@{[ $want ? 'INCLUDED, Cl 14.15' : 'NOT INCLUDED' ]}\E/);
        is("   Section 1 states the outlet discharge basis",
           $rep =~ /Outlet discharge\s+q = K x sqrt\(@{[ $want ? 'Pn' : 'Pt' ]}\)/);
        is("   the flow path notes state it",
           $want ? $rep =~ /Discharge [\d.]+ L\/min = K [\d.]+ x sqrt\(Pn / || $rep =~ /VELOCITY_PRESSURE ON\); this outlet/
                 : $rep =~ /Discharge basis: total pressure; velocity pressure not included/);
        is("   the election is in Section 4 only when it is made", !!($rep =~ /ELECTION: velocity pressures included/) == !!$want);
        my $j = HardyCross::Json::results($net, $ok, '07.phc', demand => 0);
        is("   JSON: velocity_pressure is " . ($want ? 'true' : 'false'), !!$j->{velocity_pressure} == !!$want);
        my $bad = grep { abs($_->{discharge_pressure} - ($_->{pressure} - $_->{velocity_pressure})) > 2e-4
                      || abs($_->{margin} - ($_->{discharge_pressure} - $_->{required_pressure})) > 2e-4 }
                  grep { defined $_->{k} } @{ $j->{outlets} };
        is("   JSON: discharge_pressure = pressure - velocity_pressure; margin on it", !$bad);
        is("   JSON: some outlet has a velocity pressure only when ON",
           !!(grep { $_->{velocity_pressure} > 0 } @{ $j->{outlets} }) == !!$want);
    }
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
