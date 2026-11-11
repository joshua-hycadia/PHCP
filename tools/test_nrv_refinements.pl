#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.
#
# These are targeted regressions for documented supply valve loss curves,
# re-evaluation after isolation, pump switch caps, and portable saved results.
# No manufacturer performance figure is asserted by the example data.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use HardyCross;
use HardyCross::Phc;
use HardyCross::Validate;
use HardyCross::Supplies;
use HardyCross::Results;
use HardyCross::Json;
use JSON::PP;

my ($pass, $fail) = (0, 0);
sub check {
    my ($name, $good, $why) = @_;
    printf "  %-72s %s\n", $name, $good ? 'ok' : '*** FAIL';
    print "    $why\n" if !$good && defined $why;
    $good ? $pass++ : $fail++;
}
sub approx { defined $_[0] && defined $_[1] && abs($_[0] - $_[1]) <= $_[2] }
sub elem {
    my ($net, $id) = @_;
    my ($e) = grep { $_->{id} eq $id } @{ $net->{elems} }[1 .. $#{ $net->{elems} }];
    return $e;
}
sub refusal {
    my $net = eval { HardyCross::Phc::read_string($_[0]) };
    return undef if $net;
    return ref($@) ? $@->{msg} : "$@";
}
sub solve {
    my $net = HardyCross::Phc::read_string($_[0]);
    my $ok = HardyCross::solve_model($net);
    return ($net, $ok, HardyCross::Validate::assess($net, $ok));
}

my $U = "UNITS FLOW LPM\nUNITS PRESSURE KPA\nUNITS LENGTH M\n";
my $S = $U . "USE BORE 120\nWATER W 0 800\nSPRINKLER S 0 60 10\nPIPE P W S 10 100\n";
my $DATA = "NRV W 0 7\nNRVMODEL W EXAMPLE MODEL DATA SHEET REVISION\nNRVLOSS W 0 0 500 5 1000 18\n";

print "1. MANUFACTURER LOSS DATA\n";
check('sourced non-return valve loss curve parses', !refusal($S . $DATA));
my $bad = [
    ['missing NRV', "NRVMODEL W EXAMPLE\nNRVLOSS W 0 0 500 5\n"],
    ['unidentified data source', "NRV W 0\nNRVLOSS W 0 0 500 5\n"],
    ['double-counted Cv', "NRV W 900\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 0 500 5\n"],
    ['nonzero zero-flow loss', "NRV W 0\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 2 500 5\n"],
    ['duplicate flow', "NRV W 0\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 0 500 5 500 9\n"],
    ['decreasing loss', "NRV W 0\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 0 500 12 1000 5\n"],
];
for my $b (@$bad) {
    check("invalid NRVLOSS rejected: $b->[0]", defined refusal($S . $b->[1]));
}
my ($n, $ok, $a) = solve($S . $DATA);
my $v = elem($n, 'W');
check('curve basis is retained on supply', $v->{nrv}{basis} eq 'CURVE');
check('published 500 L/min point is reproduced including cracking pressure',
      approx((HardyCross::check_valve_loss($v, 500))[0], 12, 1e-9));
check('published 1000 L/min point is reproduced including cracking pressure',
      approx((HardyCross::check_valve_loss($v, 1000))[0], 25, 1e-9));
my $json = decode_json(HardyCross::Json::encode(HardyCross::Json::results($n, $ok, 'model.phc')));
check('JSON reports manufacturer curve basis and range',
      $json->{supply_check_valves}[0]{loss_basis} eq 'CURVE'
      && $json->{supply_check_valves}[0]{loss_curve_max_flow} == 1000);
(my $short = $DATA) =~ s/1000 18/100 2/;
my ($outside, $outside_ok, $outside_a) = solve($S . "NRV W 0 7\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 0 100 2\n");
check('operating beyond published loss curve cannot be accepted',
      $outside_a->{validation}{acceptance} ne 'ACCEPTED');
check('curve range issue is explicitly identified',
      scalar(grep { $_->{code} eq 'NRV_CURVE_RANGE' } @{ $outside_a->{validation}{findings} }) > 0);

print "2. PERSISTED VALVE RESULTS\n";
my $saved = HardyCross::Results::with_results($S . $DATA, $n, $ok);
my $recs = HardyCross::Results::read_block($saved);
my ($valve) = grep { $_->[0] eq 'CHECKVALVE' && $_->[1] eq 'W' } @$recs;
check('saved PHC includes check valve record', $valve);
check('saved PHC includes curve, model and final state',
      $valve && join(' ', @$valve) =~ /BASIS CURVE/ && join(' ', @$valve) =~ /MODEL EXAMPLE_MODEL_DATA_SHEET_REVISION/
      && join(' ', @$valve) =~ /STATE DELIVERING/);
check('saved PHC record checksum is current', HardyCross::Results::status($saved) eq 'CURRENT');

print "3. ISOLATED SUPPLY RE-EVALUATION\n";
my $LIFT = $U . "USE BORE 120\nWATER W 0 50\nNODE J 0\nSPRINKLER S 10 60 80\nPIPE P W J 10 100\nPIPE R J S 10 65\nNRV W 0\n";
my ($iso, $iso_ok) = solve($LIFT);
check('weak supply initially isolated', elem($iso,'W')->{isolated} && elem($iso,'W')->{closed});
elem($iso, 'W')->{pstat} = 600;    # New external supply condition on same model.
my $new_ok = HardyCross::solve_model($iso);
my $new_validation = HardyCross::Validate::validate($iso, $new_ok);
check('isolated supply is reconsidered and can reopen after pressure recovers',
      $new_ok && !elem($iso, 'W')->{closed} && !elem($iso, 'W')->{isolated},
      $new_validation->{acceptance});
check('recovered supply delivers positive flow and its outlet is reconnected',
      elem($iso,'W')->{q} > 0 && !elem($iso,'S')->{isolated});
check('recovered solution passes mandatory validation',
      $new_validation->{acceptance} eq 'ACCEPTED' || $new_validation->{acceptance} eq 'NONCOMPLIANT',
      $new_validation->{acceptance});

print "4. PUMP SWITCHING STATE\n";
# Two supplies, one behind a pump (churn 300 kPa on a 700 kPa supply, so at
# most 1000 kPa on its outlet).  With W2 at 900 kPa the pump can beat it and
# must run, on its curve; with W2 at 1100 kPa it cannot, and its check valve
# must shut.  The closed one is the reference for the switch-limit checks.
my $PUMP = $U . "USE BORE 120\nWATER W1 0 700\nWATER W2 0 %d\nNODE A 0\nNODE B 0\nSPRINKLER S1 0 -50 80\nPIPE P1 W1 A 10 100\nPUMP PU A B 300 500 280 1000 200\nPIPE P2 W2 B 10 100\nPIPE P3 B S1 10 50\n";
my ($runnet) = solve(sprintf $PUMP, 900);
my $run = elem($runnet, 'PU');
my $boost = $runnet->{nodes}[ $run->{n2} ]{h} - $runnet->{nodes}[ $run->{n1} ]{h};
my $curve = HardyCross::curve_eval($run->{curve}, $run->{q});
check('a pump that can beat the other supply runs forward, on its curve',
      !$run->{closed} && $run->{q} > 0 && abs($boost - $curve) < 0.01,
      sprintf('closed %d, q %.2f, boost %.3f against the curve\'s %.3f',
              $run->{closed} // 0, $run->{q}, $boost, $curve));
my ($pumpnet, $pumpok) = solve(sprintf $PUMP, 1100);
my $pu = elem($pumpnet, 'PU');
check('a pump that cannot reach the other supply\'s pressure settles closed', $pu->{closed} && $pumpok);
$pu->{nflips} = 99;
my $pumpok2 = HardyCross::solve_model($pumpnet);
check('settled pump at flip limit is not spuriously unresolved',
      !($pu->{flip_limit} // 0));
$pu->{q} = -5;
$pu->{closed} = 0;
$pu->{nflips} = 99;
HardyCross::pump_status($pumpnet);
check('pump at flip limit in impossible open reverse-flow state is flagged',
      $pu->{flip_limit} // 0);

print "$pass passed; $fail failed\n";
exit($fail ? 1 : 0);
