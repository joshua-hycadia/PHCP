#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# phcp.pl -- PHCP from the command line.
#
#   phcp.pl model.phc                  solve; print flows and pressures
#   phcp.pl model.phc report.txt       ...and write the ASCII report
#   phcp.pl model.phc report.pdf       ...or the paginated PDF report
#
# The model may be a .phc command file or a .hcx block file; the extension
# decides how it is read (HardyCross::Parse::read_model).  Both give the same
# network, so everything after the read is the same for either.
#
# The printed Q and P lines are for scripts and for the validation harnesses:
# one element or node per line, in the units the model declared.
#
# Exit status is the contract other programs rely on:
#   0  solved and converged        the results can be used
#   1  ran but did not converge    the results must NOT be used
#   2  input or topology error     nothing was solved; the reason is on stderr
#==============================================================================
# Command line driver.  Prints element flows and node pressures in the units
# the MODEL declared -- not the engine's internal ones, because printing
# internal L/min for a model written in L/s is a factor of sixty that looks
# exactly like a solver disagreement.
#
# Exit status: 0 converged, 1 ran but did not converge, 2 input error.

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use HardyCross;
use HardyCross::Parse;
use HardyCross::Report;

my $USAGE = "usage: phcp.pl <model.phc | model.hcx> [report.txt | report.pdf]\n";
@ARGV or die $USAGE;
my $report_path = $ARGV[1];

my $net = eval { HardyCross::Parse::read_model($ARGV[0]) };
if (!$net) {
    my $e = $@;
    print STDERR "MODEL ERROR: ", (HardyCross::is_model_error($e) ? $e->{msg} : $e), "\n";
    exit 2;
}
my $ok = eval { HardyCross::solve_model($net) };
if (!defined $ok) {
    my $e = $@;
    print STDERR "MODEL ERROR: ", (HardyCross::is_model_error($e) ? $e->{msg} : $e), "\n";
    exit 2;
}

# With a second argument, write the full calculation report there.
if (defined $report_path) {
    # The extension chooses the format: report.pdf is paginated for print,
    # anything else is the plain ASCII text.
    if ($report_path =~ /\.pdf$/i) {
        HardyCross::Report::write_pdf_report($net, $ok, $ARGV[0], $report_path);
    } else {
        open my $rf, '>', $report_path or die "cannot write $report_path: $!\n";
        print $rf HardyCross::Report::write_report($net, $ok, $ARGV[0]);
        close $rf;
    }
}

printf "# PHCP - Perl Hydraulic Calculation Program %s\n", $HardyCross::VERSION;
printf "# converged %s  iterations %d  loops %d  continuity %.4e\n",
    ($ok ? 'yes' : 'NO'), $net->{iters}, scalar @{ $net->{loops} },
    HardyCross::continuity_error($net);
printf "# units flow %s pressure %s\n", $net->{u_flow}, $net->{u_pres};
for my $ei (1 .. $#{ $net->{elems} }) {
    my $e = $net->{elems}[$ei];
    printf "Q %s %.4f\n", $e->{id}, $e->{q} / $net->{f_flow};
}
for my $i (1 .. $#{ $net->{nodes} }) {
    my $n = $net->{nodes}[$i];
    next if $n->{id} eq 'REF';
    printf "P %s %.4f\n", $n->{id},
        ($n->{h} - $HardyCross::GAMMA_W * $n->{z}) / $net->{f_pres};
}
exit($ok ? 0 : 1);

