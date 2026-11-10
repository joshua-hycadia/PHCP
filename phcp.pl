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
#   phcp.pl model.phc --annotate out.phc
#                                      pipes given size 0 are sized (auto
#                                      sizing); out.phc is the model with
#                                      each size as a comment, //AS - 25
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
# Exit status is the contract other programs rely on.  It follows the
# calculation's ACCEPTANCE (HardyCross::Validate), not only whether the
# iteration converged:
#   0  ACCEPTED or NONCOMPLIANT    a valid solution: numerically and physically
#                                  sound; the JSON's "acceptance" and the
#                                  report say whether the design passes
#   1  INDETERMINATE               did not converge, or the device states did
#                                  not settle: the results must NOT be used
#   2  input or topology error     nothing was solved; the reason is on stderr
#                                  (and in the JSON, with --json)
#   3  REJECTED                    converged, but the network fails a
#                                  numerical or physical check (a pump running
#                                  backwards, a reverse discharge, continuity
#                                  not holding): the results must NOT be used
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

my $USAGE = "usage: phcp.pl [--json] model.phc|- [report.txt|report.pdf] [--report report.pdf] [--annotate out.phc]\n";
my ($json, $model, $report_path, $annotate) = (0, undef, undef, undef);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--json')   { $json = 1 }
    elsif ($a eq '--report') { $report_path = shift @ARGV // die $USAGE }
    elsif ($a eq '--annotate') { $annotate = shift @ARGV // die $USAGE }
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
        # A supply graph (SUPPLYGRAPH) is then found from the current folder.
        HardyCross::Phc::read_string($text, '.');
    } else {
        HardyCross::Parse::read_model($model);
    }
};
fail_out($@) unless $net;
my $ok = eval { HardyCross::solve_model($net) };
fail_out($@) unless defined $ok;
# Pipes given size 0 are sized (HardyCross::Sizing), then, with design areas
# (AREA), each area is solved and the governing one reported.
if ($net->{auto_sizing}) {
    require HardyCross::Sizing;
    my $text = $net->{source_text};
    ($net, $ok) = eval { HardyCross::Sizing::size($net, $ok) } or fail_out($@);
    if (defined $annotate) {
        open my $af, '>', $annotate or die "cannot write $annotate: $!\n";
        print $af HardyCross::Sizing::annotate($text, $net->{sizing});
        close $af;
    }
}
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

require HardyCross::Json;
require HardyCross::Validate;
if ($json) {
    my $j = HardyCross::Json::results($net, $ok, $model);
    print HardyCross::Json::encode($j);
    exit(HardyCross::Json::exit_code($j->{acceptance}));
}
# Without --json the acceptance is still worked out (with the demand point
# only when a report asked for it, as it re-solves the model many times), so
# the exit status means the same thing either way.
my $va = HardyCross::Validate::assess($net, $ok, demand => defined $report_path ? 1 : 0)->{validation};

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
exit(HardyCross::Json::exit_code($va->{acceptance}));

