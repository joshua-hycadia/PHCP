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
#                 break, nothing altered; every rule is drawn as a line
#   typeface      DejaVu Sans Mono embedded, regular and bold
#   the graph     D and O drawn where the report's own figures put them on
#                 q^1.85 paper, worked here independently; the flow labels
#                 at their places and clear of each other; the graph above
#                 the footer
#
#   perl tools/test_pdf.pl [model.hcx ...]
#==============================================================================
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempfile);

my @models = @ARGV ? @ARGV : grep { !/grid1000/ } glob("$FindBin::Bin/../examples/*.{hcx,phc}");
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
    # Rules are drawn, not typed; the supply graph's character drawing is
    # replaced by the drawn graph.  Neither is looked for as text.
    my @tl = split /\n/, $T;
    my ($gs) = grep { $tl[$_] =~ /^ SUPPLY GRAPH/ } 0 .. $#tl;
    my %skip;
    if (defined $gs) {
        my $ge = $gs;
        $ge++ while $ge < $#tl && $tl[$ge] !~ /O\s+operating point/;
        $skip{$_} = 1 for $gs + 1 .. $ge;
    }
    my $is_rule = sub { $_[0] =~ /^\s*(=+|-+)\s*$/ && length($1) >= 20 };
    my @missing = grep { /\S/ && !$is_rule->($_) && !$have{$_} } map { $tl[$_] } grep { !$skip{$_} } 0 .. $#tl;
    ok("$name: every text line present in the PDF (" . scalar(@missing) . ' missing)', !@missing);
    print "      e.g. [$missing[0]]\n" if @missing;
    my $nrules = grep { $is_rule->($_) } @tl;
    my $drawn = () = $streams =~ /% PHCP-RULE/g;
    ok("$name: every rule drawn as a line ($nrules in the text, $drawn drawn)", $drawn >= $nrules && $nrules > 0);
    ok("$name: the typeface is embedded (DejaVu Sans Mono, regular and bold)",
       $P =~ m{/BaseFont /DejaVuSansMono /} && $P =~ m{/BaseFont /DejaVuSansMono-Bold } && $P =~ m{/FontFile2 });

    # The drawn graph, checked against the report's own figures by hand.
    next unless defined $gs;
    my ($pl, $pb, $pw, $ph, $qmax, $pmax) = $streams =~ /% PHCP-GRAPH PLOT (\S+) (\S+) (\S+) (\S+) (\S+) (\S+)/;
    ok("$name: the supply graph is drawn", defined $pl);
    next unless defined $pl;
    my $X = sub { $pl + ($_[0] / $qmax) ** 1.85 * $pw };
    my $Y = sub { $pb + $_[0] / $pmax * $ph };
    my ($qd, $pd) = $T =~ /^\s+DEMAND\s+([\d.]+) \S+\s+at\s+([\d.]+)/m;
    my ($qo, $po) = $T =~ /^\s+OPERATING POINT\s+([\d.]+) \S+\s+at\s+([\d.]+)/m;
    my ($dx, $dy) = $streams =~ /% PHCP-GRAPH D (\S+) (\S+)/;
    my ($ox, $oy) = $streams =~ /% PHCP-GRAPH O (\S+) (\S+)/;
    # The report prints to 0.1, so a figure read from it is good to 0.05 of
    # its unit; on the page that is whatever 0.05 spans at that point of the
    # axis (more in bar than in kPa), plus rounding of the coordinates.
    my $tx = sub { (abs($X->($_[0] + 0.05) - $X->($_[0] > 0.05 ? $_[0] - 0.05 : 0))) / 2 + 0.01 };
    my $ty = 0.05 / $pmax * $ph + 0.01;
    ok(sprintf("$name: D drawn at the demand point, x = %.2f + %.2f (%.1f/%.1f)^1.85", $pl, $pw, $qd, $qmax),
       abs($dx - $X->($qd)) <= $tx->($qd) && abs($dy - $Y->($pd)) <= $ty);
    ok("$name: O drawn at the operating point",
       abs($ox - $X->($qo)) <= $tx->($qo) && abs($oy - $Y->($po)) <= $ty);
    my @xt = $streams =~ /% PHCP-GRAPH XTICK (\S+) (\S+)/g;
    my ($tbad, $prev) = (0, undef);
    for (my $k = 0; $k < @xt; $k += 2) {
        my ($t, $x) = @xt[$k, $k + 1];
        $tbad++ if abs($x - $X->($t)) > 0.01;
        $tbad++ if defined $prev && $x - $prev < 6;
        $prev = $x;
    }
    ok("$name: every flow label at (q/qmax)^1.85 along the axis, none overlapping", @xt && !$tbad);
    my ($nsup) = $streams =~ /% PHCP-GRAPH SUPPLY (\d+)/;
    ok("$name: the supply drawn as a line of $nsup points", ($nsup // 0) > 100);
    ok("$name: the graph clears the page footer", $pb - 3 * 10.8 > 38);
}
printf "PDF report: %d checks across %d models, %d failed\n", $checks, scalar @models, $fails;
exit($fails ? 1 : 0);
