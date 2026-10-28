#!/usr/bin/perl
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_pdf.pl -- check the PDF report without any PDF tool installed.
#
# A PDF that most readers open can still be malformed: readers repair broken
# cross-reference tables silently, so "it opened on my machine" proves little.
# This test reads PHCP's PDF the way the specification says a reader should,
# and checks what matters for a calculation:
#
#   structure     the header, the trailer, startxref pointing at the xref
#                 table, and every xref offset landing exactly on "n 0 obj"
#   pages         the page tree's /Count equals the pages actually present
#   streams       every content stream's /Length equals its real length
#   completeness  every line of the text report appears in the PDF, once the
#                 PDF string escapes are undone -- nothing dropped at a page
#                 break, nothing altered
#
#   perl tools/test_pdf.pl [model.phc ...]
#==============================================================================
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempfile);

my @models = @ARGV ? @ARGV : grep { !/grid1000/ } glob("$FindBin::Bin/../examples/*.phc");
my ($checks, $fails) = (0, 0);
sub ok {
    my ($what, $c) = @_;
    $checks++;
    return 1 if $c;
    $fails++;
    print "  FAIL $what\n";
    return 0;
}

for my $m (@models) {
    (my $name = $m) =~ s{.*/}{};
    my (undef, $txt) = tempfile(SUFFIX => '.txt', UNLINK => 1);
    my (undef, $pdf) = tempfile(SUFFIX => '.pdf', UNLINK => 1);
    system("\"$FindBin::Bin/../phcp.pl\" \"$m\" \"$txt\" >/dev/null 2>&1");
    system("\"$FindBin::Bin/../phcp.pl\" \"$m\" \"$pdf\" >/dev/null 2>&1");
    my $P = do { open my $f, '<:raw', $pdf or next; local $/; <$f> };
    my $T = do { open my $f, '<', $txt or next; local $/; <$f> };

    ok("$name: PDF header", $P =~ /\A%PDF-1\.\d\n/);
    ok("$name: ends with %%EOF", $P =~ /%%EOF\n?\z/);
    my ($sx) = $P =~ /startxref\n(\d+)\n%%EOF/;
    ok("$name: startxref points at the xref table",
       defined $sx && substr($P, $sx, 4) eq 'xref');

    # every in-use xref entry must land exactly on its object
    my ($first, $count) = substr($P, $sx) =~ /^xref\n(\d+) (\d+)\n/;
    my @entries = substr($P, $sx) =~ /^(\d{10}) (\d{5}) ([nf]) ?\r?\n/mg;
    my $bad = 0;
    for (my $k = 0; $k < @entries; $k += 3) {
        my ($off, $gen, $type) = @entries[$k .. $k + 2];
        next unless $type eq 'n';
        my $num = $first + $k / 3;
        $bad++ unless substr($P, $off, length("$num 0 obj")) eq "$num 0 obj";
    }
    ok("$name: all " . ($count - 1) . " xref offsets land on their objects", $bad == 0);

    my ($declared) = $P =~ m{/Type /Pages /Kids \[[^\]]*\] /Count (\d+)};
    my $actual = () = $P =~ m{/Type /Page /Parent}g;
    ok("$name: page tree counts $declared, file holds $actual", $declared && $declared == $actual);

    my $lenbad = 0;
    my $streams = '';
    while ($P =~ m{<< /Length (\d+) >>\nstream\n}g) {
        my ($len, $at) = ($1, pos $P);
        $lenbad++ unless substr($P, $at + $len, 9) eq 'endstream';
        $streams .= substr($P, $at, $len);
    }
    ok("$name: every stream /Length is exact", $lenbad == 0);

    # completeness: undo the PDF string escapes and look for every report line
    my %have;
    while ($streams =~ /\(((?:[^\\()]|\\.)*)\) Tj/g) {
        (my $s = $1) =~ s/\\(.)/$1/g;
        $have{$s}++;
    }
    my @missing = grep { /\S/ && !$have{$_} } split /\n/, $T;
    ok("$name: every text line present in the PDF (" . scalar(@missing) . ' missing)', !@missing);
    print "      e.g. [$missing[0]]\n" if @missing;
}
printf "PDF report: %d checks across %d models, %d failed\n", $checks, scalar @models, $fails;
exit($fails ? 1 : 0);
