#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# epanet_adapter.pl -- makes the Perl engine look like the reference binary to
# validation/run_suite.py, which drives every implementation the same way:
#
#     <binary> <model.hcx> <report.txt>
#
# and then reads node heads and element flows out of the report's schedules.
#
# This engine deliberately does not write a report -- eight other
# implementations already agree on that text, and a ninth would prove nothing.
# So this writes ONLY the two sections the suite parses, in the columns it
# expects, and nothing else.  It is a validation shim, not a report writer, and
# the header says so in the file it produces.
#==============================================================================

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use HardyCross;
use HardyCross::Parse;

@ARGV >= 2 or die "usage: epanet_adapter.pl <model.hcx> <out.txt>\n";
my ($in, $out) = @ARGV;

# An error message can quote the very token that was corrupted, so anything
# written to the report passes through here first.
sub printable { my $t = shift; $t =~ s/[^\x20-\x7E\n]/?/g; $t }

my $net = eval { HardyCross::Parse::read_model($in) };
unless ($net) {
    my $e = $@;
    open my $fh, '>', $out or exit 2;
    print $fh " MODEL ERROR: ",
        printable(HardyCross::is_model_error($e) ? $e->{msg} : "$e"), "\n";
    close $fh;
    exit 2;
}
my $ok = eval { HardyCross::solve_model($net) };
unless (defined $ok) {
    my $e = $@;
    open my $fh, '>', $out or exit 2;
    print $fh " MODEL ERROR: ",
        printable(HardyCross::is_model_error($e) ? $e->{msg} : "$e"), "\n";
    close $fh;
    exit 2;
}

open my $fh, '>', $out or die "cannot write $out: $!\n";
print $fh "# validation adapter output - not a calculation report\n";
printf $fh " %s in %d iterations\n",
    ($ok ? 'CONVERGED' : 'NOT CONVERGED'), $net->{iters};
# The scale suite reads these two facts; both come from the solved network.
printf $fh "   chords = loops        : %d\n", scalar @{ $net->{loops} };
printf $fh "   max nodal continuity error : %.3e L/min\n", HardyCross::continuity_error($net);

# The suite reads the FIFTH field as total head in kPa, and recognises a row by
# shape: an identifier followed by at least four numbers.
print $fh " NODE SCHEDULE\n";
for my $i (1 .. $#{ $net->{nodes} }) {
    my $n = $net->{nodes}[$i];
    next if $n->{id} eq 'REF';
    printf $fh "   %-12s %10.3f %12.2f %14.2f %14.2f\n",
        $n->{id}, $n->{z}, $HardyCross::GAMMA_W * $n->{z},
        $n->{h} - $HardyCross::GAMMA_W * $n->{z}, $n->{h};
}

# The suite reads the FIFTH field as flow in L/min, from a row of at least
# seven fields.
print $fh " PIPE SCHEDULE\n";
print $fh " ELEMENT RESULTS\n";
my %kind = (PIPE => 'PIPE', PUMP => 'PUMP', SUPPLY_STATIC => 'STATIC',
            SUPPLY_CURVE => 'CURVE', DISCHARGE => 'SPRINKLER',
            FIXED_DROP => 'PRV', ORIFICE => 'ORIFICE_D',
            ORIFICE_REQUIRED => 'ORIFICE_P', BFP => 'BFP');
for my $ei (1 .. $#{ $net->{elems} }) {
    my $e = $net->{elems}[$ei];
    my ($hf) = HardyCross::elem_hf($e, $e->{q}, $net->{opts});
    my $vel = $e->{kind} eq 'PIPE'
            ? HardyCross::pipe_velocity($e->{q}, $e->{dia}) : 0;
    printf $fh "   %-20s %-12s %-12s %-12s %11.2f %9.2f %11.2f\n",
        $e->{id}, $kind{ $e->{kind} } // $e->{kind},
        $net->{nodes}[ $e->{n1} ]{id}, $net->{nodes}[ $e->{n2} ]{id},
        $e->{q}, $vel, $hf;
}
# Pump status.  Written only from the engine's own closed flag, so the words
# appear if and only if the check valve really shut -- the harness looks for
# them, and printing them unconditionally would make the test prove nothing.
for my $ei (1 .. $#{ $net->{elems} }) {
    my $e = $net->{elems}[$ei];
    printf $fh "   %-20s PUMP   CHECK VALVE CLOSED - would run backwards\n", $e->{id}
        if $e->{kind} eq 'PUMP' && $e->{closed};
}
print $fh " WARNING: ", printable($_), "\n" for @{ $net->{warnings} || [] };
print $fh " FLOW PATH ANALYSIS\n";
close $fh;
exit($ok ? 0 : 1);
