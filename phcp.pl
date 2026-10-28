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
#   phcp.pl --json model.phc           the results as JSON (HardyCross::Json),
#                                      for another program to read
#   phcp.pl --json -                   ...the model read from standard input
#   phcp.pl --json model.phc --report out.pdf
#                                      ...and the report written as well
#
# The model is a .phc command file, the one file type PHCP reads
# (HardyCross::Parse::read_model).  A .hcx file is refused with the reason,
# exit status 2.  "-" reads the model text from standard input, as a caller
# that builds the model in memory sends it.
#
# The printed Q and P lines are for scripts and for the validation harnesses:
# one element or node per line, in the units the model declared.  With
# --json, one JSON object is printed instead -- in every case, an error
# included, so a caller always has something to read.
#
# Exit status is the contract other programs rely on:
#   0  solved and converged        the results can be used
#   1  ran but did not converge    the results must NOT be used
#   2  input or topology error     nothing was solved; the reason is on stderr
#                                  (and in the JSON, with --json)
#==============================================================================
# Command line driver.  Prints element flows and node pressures in the units
# the MODEL declared -- not the engine's internal ones, because printing
# internal L/min for a model written in L/s is a factor of sixty that looks
# exactly like a solver disagreement.

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use HardyCross;
use HardyCross::Parse;
use HardyCross::Report;

my $USAGE = "usage: phcp.pl [--json] model.phc|- [report.txt|report.pdf] [--report report.pdf]\n";
my ($json, $model, $report_path) = (0, undef, undef);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--json')   { $json = 1 }
    elsif ($a eq '--report') { $report_path = shift @ARGV // die $USAGE }
    elsif (!defined $model)  { $model = $a }
    elsif (!defined $report_path) { $report_path = $a }
    else  { die $USAGE }
}
defined $model or die $USAGE;
binmode STDOUT;

# fail -- an input or topology error: the reason, then exit 2.
sub fail_out {
    my $e = shift;
    if ($json) {
        require HardyCross::Json;
        print HardyCross::Json::encode(HardyCross::Json::error_result($e, $model));
    }
    print STDERR "MODEL ERROR: ", (HardyCross::is_model_error($e) ? $e->{msg} : $e), "\n";
    exit 2;
}

my $net = eval {
    if ($model eq '-') {
        my $text = do { local $/; <STDIN> };
        require HardyCross::Phc;
        HardyCross::Phc::read_string($text);
    } else {
        HardyCross::Parse::read_model($model);
    }
};
fail_out($@) unless $net;
my $ok = eval { HardyCross::solve_model($net) };
fail_out($@) unless defined $ok;
# With design areas (AREA), each is solved and the governing one reported.
if ($net->{areas}) {
    require HardyCross::Areas;
    ($net, $ok) = eval { HardyCross::Areas::governing($net, $ok) } or fail_out($@);
}

# With a report path, write the full calculation report there.
if (defined $report_path) {
    my $name = $model eq '-' ? 'STDIN.PHC' : $model;
    # The extension chooses the format: report.pdf is paginated for print,
    # anything else is the plain ASCII text.
    if ($report_path =~ /\.pdf$/i) {
        HardyCross::Report::write_pdf_report($net, $ok, $name, $report_path);
    } else {
        open my $rf, '>', $report_path or die "cannot write $report_path: $!\n";
        print $rf HardyCross::Report::write_report($net, $ok, $name);
        close $rf;
    }
}

if ($json) {
    require HardyCross::Json;
    print HardyCross::Json::encode(HardyCross::Json::results($net, $ok, $model));
    exit($ok ? 0 : 1);
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

