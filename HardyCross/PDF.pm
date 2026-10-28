#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/PDF.pm -- the calculation report as a PDF, in core Perl.
#
# WHAT THIS IS
#   A faithful, paginated print of the ASCII report -- the same characters in
#   the same columns, on A4 landscape -- with a running header, a page footer
#   and page breaks placed where a reader expects them.  Two things are drawn
#   rather than typed: the rules (a line of '=' or '-' in the text report is a
#   ruled line on the page) and the supply graph, which the text report draws
#   in characters and the PDF draws with lines from the same numbers
#   (draw_graph).  The text report and the PDF are made from the same solved
#   network in the same run, so the two cannot disagree.
#
# THE TYPEFACE
#   DejaVu Sans Mono, embedded (data/fonts, under its own licence -- see
#   LICENSE).  Courier, the one monospace face every PDF reader supplies, is
#   a thin typewriter face that printed faint and looked dated; an embedded
#   face prints the same on every machine.  The font files are compressed
#   into the PDF whole -- about 300 kB -- rather than subset, which would need
#   a TrueType rewriter.  If the files are missing the PDF falls back to
#   Courier, so a report is never lost for want of a font.
#
# WHY WRITE THE PDF BY HAND
#   PHCP is Perl with no dependencies beyond Tk.  A PDF library would be the
#   first module a user had to install before the program could print.  The
#   report is 7-bit ASCII by construction, so one simple font encoding covers
#   it.  What remains is a few objects and a cross-reference table, set out in
#   ISO 32000-1, and short enough to read in one sitting.
#
# THE PAGE
#   A4 landscape, 842 x 595 pt.  DejaVu Sans Mono advances 602/1000 em
#   (Courier 600), so 132 columns at 9 pt are 715 pt wide and sit centred
#   with 63 pt margins -- the full page width is used without shrinking the
#   type below what reads comfortably on paper.  46 lines of 10.8 pt leading
#   fit between header and footer.
#
# WHERE THE PAGES BREAK
#   A calculation read on paper has three things that must not be split:
#     - a section heading must not sit alone at the foot of a page;
#     - a table continued onto a new page must repeat its column headings, or
#       the second half is columns of numbers with no names;
#     - the supply graph must not be cut in half.
#   Everything else flows.  A page never starts with blank lines.

package HardyCross::PDF;

use strict;
use warnings;
use POSIX qw(strftime floor);
use File::Spec;
use Compress::Zlib ();

my ($PAGE_W, $PAGE_H) = (842, 595);          # A4 landscape
my $FONT_SIZE = 9;
my $LEADING   = 10.8;
my $COLS      = 132;
my $BODY_TOP  = 545;                          # first baseline on a page
my $BODY_BOT  = 50;                           # no baseline below this
my $PER_PAGE  = floor(($BODY_TOP - $BODY_BOT) / $LEADING) + 1;
# The width of one character, in em, and so the left margin, are those of
# the face in use: set by write_pdf once the fonts are loaded.
my $ADVANCE   = 0.6;
my ($CHAR_W, $LEFT);
sub set_advance {
    $ADVANCE = shift;
    $CHAR_W  = $ADVANCE * $FONT_SIZE;
    $LEFT    = ($PAGE_W - $COLS * $CHAR_W) / 2;
}
set_advance(0.6);

# The supply graph's box on the page, in lines of text.
my $GRAPH_LINES = 30;

sub is_thick { $_[0] =~ /^={20,}\s*$/ }
sub is_thin  { $_[0] =~ /^-{20,}\s*$/ }
sub blank    { $_[0] !~ /\S/ }
# An indented light rule separates the blocks of a multi-line table -- the
# four lines that describe one pipe in the NFPA schedule.
sub is_sub   { $_[0] =~ /^\s+-{20,}\s*$/ }

#------------------------------------------------------------------------------
# Paginate.
#
# Returns a list of pages, each a list of [text, bold] lines.  Works on the
# report's own structure -- heavy rules around section titles, light rules
# under table headings -- so the text report stays the single source and the
# PDF needs no separate description of its layout.
#------------------------------------------------------------------------------
sub paginate {
    my ($text, $graphs) = @_;
    $graphs ||= [];
    my $gi = 0;                # the next drawn graph to place
    my @L = split /\n/, $text, -1;
    pop @L while @L && blank($L[-1]);

    my (@pages, @page);
    my @table_head;            # column headings of the table we are inside
    my $in_table = 0;

    my $new_page = sub {
        push @pages, [@page] if @page;
        @page = ();
    };
    my $room = sub { $PER_PAGE - scalar @page };
    my $put = sub {
        my ($text, $bold) = @_;
        return if !@page && blank($text);       # never open a page on a gap
        push @page, [ $text, $bold ? 1 : 0 ];
    };

    for (my $i = 0; $i < @L; $i++) {
        my $l = $L[$i];

        # A section heading: heavy rule, title, heavy rule.  Keep it with at
        # least the next few lines of its section.
        if (is_thick($l) && $i + 2 <= $#L && is_thick($L[ $i + 2 ]) && !is_thick($L[ $i + 1 ])) {
            # Every numbered section starts on a page of its own, so each part
            # of the calculation can be found, filed and replaced by itself -
            # the pipe schedule of a revision can be swapped without reprinting
            # the rest.  The cover sheet, which has no number, keeps page 1.
            if ($L[ $i + 1 ] =~ /^\s*\d+\.\s/) {
                $new_page->() if @page;
            } else {
                my $need = 3;
                for (my $k = $i + 3; $k <= $#L && $k < $i + 9; $k++) { $need++ }
                $new_page->() if $room->() < $need && @page;
            }
            $put->($l);
            $put->($L[ $i + 1 ], 1);            # the title itself in bold
            $put->($L[ $i + 2 ]);
            $i += 2;
            $in_table = 0;
            @table_head = ();
            next;
        }

        # The supply graph moves to a new page whole rather than be cut.
        # With the graph's numbers to hand, its character drawing is left out
        # and a box of $GRAPH_LINES lines is kept for the drawn graph: the
        # heading stays as text, the first line of the box carries the mark
        # 'graph', and write_pdf draws into it.
        # Each graph in the text, in order, is drawn from the next set of
        # numbers in @$graphs; one supply gives one graph, several give one each.
        if ($l =~ /^ SUPPLY GRAPH/) {
            my $j = $i;
            $j++ while $j < $#L && $L[$j] !~ /O\s+operating point/;
            my $graph = $graphs->[ $gi++ ];
            my $h = $graph ? $GRAPH_LINES + 2 : $j - $i + 1;
            $new_page->() if $room->() < $h && $h <= $PER_PAGE && @page;
            if ($graph) {
                $put->($l, 1);
                push @page, [ '', 0, 'graph', $graph ];
                push @page, [ '', 0 ] for 2 .. $GRAPH_LINES;
            } else {
                $put->($L[$_]) for $i .. $j;
            }
            $i = $j;
            next;
        }

        # A light rule directly under non-blank lines is the underline of a
        # table's column headings: remember them, so a page break inside the
        # table can repeat them.  A light rule after data closes the table.
        if (is_thin($l)) {
            if ($in_table) {
                $in_table = 0;
                @table_head = ();
                # a closing rule is pulled back to the page its table ended on
                if ($room->() < 1) { $new_page->() }
                $put->($l);
                next;
            }
            my @head;
            for (my $k = $i - 1; $k >= 0 && $k >= $i - 3; $k--) {
                last if blank($L[$k]) || is_thick($L[$k]) || is_thin($L[$k]);
                unshift @head, $L[$k];
            }
            if (@head) {
                # Headings and at least two rows of data go together.
                if ($room->() < 3 && @page >= @head) {
                    splice @page, -@head;       # take the headings off this page
                    $new_page->();
                    $put->($_) for @head;
                }
                @table_head = (@head, $l);
                $in_table = 1;
            }
            $put->($l);
            next;
        }

        $in_table = 0 if $in_table && blank($l);

        # A block of a multi-line table moves to the next page whole, under
        # repeated headings.  Split, a pipe's pressure at one end would sit on
        # one page and at the other end on the next -- the sum Pt BEG - Pe - Pf
        # = Pt END could not be done without turning the page.
        if ($in_table && !blank($l) && !is_sub($l)
            && ($i == 0 || is_thin($L[ $i - 1 ]) || is_sub($L[ $i - 1 ]))) {
            my $k = 0;
            $k++ while $i + $k <= $#L && !blank($L[ $i + $k ])
                    && !is_sub($L[ $i + $k ]) && !is_thin($L[ $i + $k ]);
            my $block_has_room = $k <= $PER_PAGE - @table_head - 1;
            if ($block_has_room && $room->() < $k && @page) {
                # a separator left dangling at the foot of the page goes too
                pop @page while @page && is_sub($page[-1][0]);
                $new_page->();
                $put->(' (continued)');
                $put->($_) for @table_head;
            }
        }
        # A block separator is never the first line of a page.
        next if is_sub($l) && !@page;

        # A short paragraph -- the notes and checks under a table, a numbered
        # assumption -- moves to the next page whole rather than split.  Table
        # rows may break, because their headings are repeated; a paragraph has
        # nothing to repeat, and its second half read alone at the top of a
        # page is a set of checks with no table in sight.
        if (!$in_table && !blank($l) && ($i == 0 || blank($L[ $i - 1 ])
                || is_thin($L[ $i - 1 ]) || is_thick($L[ $i - 1 ]))) {
            my $k = 0;
            $k++ while $i + $k <= $#L && !blank($L[ $i + $k ])
                    && !is_thin($L[ $i + $k ]) && !is_thick($L[ $i + $k ]);
            $new_page->() if $k <= 8 && $room->() < $k && @page;
        }

        if ($room->() < 1) {
            $new_page->();
            if ($in_table && @table_head) {
                $put->(' (continued)');
                $put->($_) for @table_head;
            }
        }
        $put->($l);
    }
    $new_page->();
    return \@pages;
}

#------------------------------------------------------------------------------
# PDF string escaping.  Backslash and both parentheses; anything outside
# printable ASCII cannot reach here, because the report writer forbids it, but
# is replaced rather than trusted if it ever does.
#------------------------------------------------------------------------------
sub esc {
    my $t = shift;
    $t =~ s/[^\x20-\x7E]/?/g;
    $t =~ s/([\\()])/\\$1/g;
    return $t;
}

sub fit { my ($t, $w) = @_; length $t > $w ? substr($t, 0, $w - 3) . '...' : $t }

#------------------------------------------------------------------------------
# The typeface.
#
# load_font reads a TrueType file and returns what the PDF needs to embed it:
# the bytes, and from the font's own tables the units per em, the advance
# width (one for every character -- it is a monospace face), the bounding
# box, ascent, descent and cap height.  Returns undef if the file is not
# there.  The tables are read with unpack as the TrueType specification sets
# them out; nothing else in the file is touched.
#------------------------------------------------------------------------------
sub font_dir {
    my ($vol, $dir) = File::Spec->splitpath(File::Spec->rel2abs(__FILE__));
    my @try = (File::Spec->catdir($vol . $dir, File::Spec->updir, File::Spec->updir, 'data', 'fonts'));
    push @try, File::Spec->catdir($ENV{PAR_TEMP}, 'inc', 'lib', 'data', 'fonts') if $ENV{PAR_TEMP};
    my ($pv, $pd) = File::Spec->splitpath(File::Spec->rel2abs($0));
    push @try, File::Spec->catdir($pv . $pd, 'data', 'fonts');
    for (@try) { return $_ if -d $_ }
    return $try[0];
}

sub load_font {
    my $file = File::Spec->catfile(font_dir(), shift);
    open my $fh, '<:raw', $file or return undef;
    my $b = do { local $/; <$fh> };
    close $fh;
    my $n = unpack 'n', substr($b, 4, 2);
    my %t;
    for my $i (0 .. $n - 1) {
        my ($tag, undef, $off, $len) = unpack 'a4 N N N', substr($b, 12 + 16 * $i, 16);
        $t{$tag} = [ $off, $len ];
    }
    return undef unless $t{head} && $t{hhea} && $t{hmtx};
    my $i16 = sub { my $v = unpack 'n', substr($b, $_[0], 2); $v >= 32768 ? $v - 65536 : $v };
    my $u16 = sub { unpack 'n', substr($b, $_[0], 2) };
    my $h = $t{head}[0];
    my $upm = $u16->($h + 18);
    my $k = 1000 / $upm;
    my %f = (bytes => $b, upm => $upm,
             advance => $u16->($t{hmtx}[0]) * $k,
             bbox => [ map { int($i16->($h + $_) * $k) } 36, 38, 40, 42 ],
             ascent => int($i16->($t{hhea}[0] + 4) * $k), descent => int($i16->($t{hhea}[0] + 6) * $k));
    $f{cap} = $t{'OS/2'} && $u16->($t{'OS/2'}[0]) >= 2 ? int($i16->($t{'OS/2'}[0] + 88) * $k) : $f{ascent};
    return \%f;
}

#------------------------------------------------------------------------------
# Write the PDF.
#   %meta: title, job, revision, date, designer, model, program, and graphs --
#   the supply graphs' numbers (HardyCross::Report::supply_graph_data), in
#   the order the graphs appear in the text, which draw each graph in place of
#   the report's character drawing.  (graph, one set, is still taken.)
#------------------------------------------------------------------------------
sub write_pdf {
    my ($text, $path, %meta) = @_;
    my $reg  = load_font('DejaVuSansMono.ttf');
    my $bold = $reg && load_font('DejaVuSansMono-Bold.ttf');
    $reg = $bold = undef unless $reg && $bold;
    set_advance($reg ? $reg->{advance} / 1000 : 0.6);

    my $graphs = $meta{graphs} || ($meta{graph} ? [ $meta{graph} ] : []);
    my $pages = paginate($text, $graphs);
    my $n = @$pages;

    my $hdr_left  = 'PHCP  HYDRAULIC CALCULATION';
    my $hdr_right = join '   ', grep { length }
        ($meta{job} ? "Job $meta{job}" : ''), ($meta{revision} ? "Rev $meta{revision}" : ''),
        ($meta{date} // '');
    my $hdr_mid   = fit($meta{title} // '', $COLS - length($hdr_left) - length($hdr_right) - 6);

    # Build each page's content stream.
    my @streams;
    for my $p (0 .. $n - 1) {
        my $s = '';
        # hairlines under the header and over the footer
        $s .= sprintf "0.5 w %.2f %.2f m %.2f %.2f l S\n", $LEFT, 560, $PAGE_W - $LEFT, 560;
        $s .= sprintf "0.5 w %.2f %.2f m %.2f %.2f l S\n", $LEFT, 38, $PAGE_W - $LEFT, 38;

        # running header, laid out on the same 132-column grid as the body
        my $h = $hdr_left;
        my $mid_at = int(($COLS - length $hdr_mid) / 2);
        $h .= ' ' x ($mid_at - length $h) if length $h < $mid_at;
        $h .= $hdr_mid;
        $h .= ' ' x ($COLS - length($h) - length($hdr_right)) . $hdr_right;
        $s .= sprintf "BT /F2 %s Tf %.2f %.2f Td (%s) Tj ET\n", $FONT_SIZE, $LEFT, 566, esc($h);

        # footer: what was calculated, and where this page sits in it
        # The footer is set smaller than the body, so the page number is
        # placed by its width in points against the right margin, not by
        # counting columns of the body's size.
        my $pg = sprintf 'Page %d of %d', $p + 1, $n;
        my $fl = fit(($meta{program} // 'PHCP') . ($meta{model} ? "   $meta{model}" : ''),
                     $COLS - length($pg) - 2);
        $s .= sprintf "BT /F1 %s Tf %.2f %.2f Td (%s) Tj ET\n", 8, $LEFT, 26, esc($fl);
        $s .= sprintf "BT /F1 %s Tf %.2f %.2f Td (%s) Tj ET\n", 8,
            $LEFT + $COLS * $CHAR_W - length($pg) * $ADVANCE * 8, 26, esc($pg);

        # The body, one Tj per line, bold only for section titles.  A rule is
        # not typed: its line is left empty and the rule drawn after -- heavy
        # for '=', light for '-', and an indented light rule from its indent.
        $s .= sprintf "BT /F1 %s Tf %s TL %.2f %.2f Td\n", $FONT_SIZE, $LEADING, $LEFT, $BODY_TOP;
        my $fb = 0;
        my (@rules, @gy);
        my $y = $BODY_TOP;
        for my $ln (@{ $pages->[$p] }) {
            my ($t, $b, $mark, $g) = @$ln;
            push @gy, [ $y, $g ] if ($mark // '') eq 'graph';
            if (is_thick($t) || is_thin($t) || is_sub($t)) {
                my $ind = length(($t =~ /^(\s*)/)[0]);
                my $len = length(($t =~ /^\s*(\S+)/)[0]);
                push @rules, [ $y + $FONT_SIZE * 0.3, $ind, $len, is_thick($t) ? 1.0 : 0.4 ];
                $s .= "T*\n";
            } else {
                if ($b != $fb) { $s .= ($b ? '/F2' : '/F1') . " $FONT_SIZE Tf\n"; $fb = $b }
                $s .= '(' . esc($t) . ") Tj T*\n";
            }
            $y -= $LEADING;
        }
        $s .= "ET\n";
        for my $r (@rules) {
            my ($ry, $ind, $len, $wt) = @$r;
            $s .= sprintf "%% PHCP-RULE %.1f\n%.2f w %.2f %.2f m %.2f %.2f l S\n", $wt, $wt,
                $LEFT + $ind * $CHAR_W, $ry, $LEFT + ($ind + $len) * $CHAR_W, $ry;
        }
        $s .= draw_graph($_->[1], $_->[0] + $LEADING * 0.6, $GRAPH_LINES * $LEADING) for @gy;
        push @streams, $s;
    }

    # Objects: 1 catalog, 2 page tree, 3 regular font, 4 bold font, 5
    # document info; then, for embedded fonts, each font's descriptor and
    # file; then each page and its content.
    my @obj;
    my $next = 6;
    my $font = sub {
        my ($f, $name) = @_;
        my $base = "/Type /Font /Subtype /Type1 /BaseFont /$name /Encoding /WinAnsiEncoding";
        return "<< $base >>" unless $f;
        my ($desc, $file) = ($next, $next + 1);
        $next += 2;
        my $z = Compress::Zlib::compress($f->{bytes});
        $obj[$desc] = sprintf '<< /Type /FontDescriptor /FontName /%s /Flags 33 /FontBBox [%s] '
                    . '/ItalicAngle 0 /Ascent %d /Descent %d /CapHeight %d /StemV %d /FontFile2 %d 0 R >>',
            $name, join(' ', @{ $f->{bbox} }), $f->{ascent}, $f->{descent}, $f->{cap},
            $name =~ /Bold/ ? 140 : 80, $file;
        $obj[$file] = sprintf "<< /Length %d /Length1 %d /Filter /FlateDecode >>\nstream\n%sendstream",
            length $z, length $f->{bytes}, $z . "\n";
        my $w = sprintf '%d', $f->{advance} + 0.5;
        return sprintf '<< /Type /Font /Subtype /TrueType /BaseFont /%s /FirstChar 32 /LastChar 126 '
                     . '/Widths [%s] /Encoding /WinAnsiEncoding /FontDescriptor %d 0 R >>',
            $name, join(' ', ($w) x 95), $desc;
    };
    $obj[3] = $font->($reg,  $reg  ? 'DejaVuSansMono'      : 'Courier');
    $obj[4] = $font->($bold, $bold ? 'DejaVuSansMono-Bold' : 'Courier-Bold');
    my @kids = map { $next + 2 * $_ } 0 .. $n - 1;
    $obj[1] = "<< /Type /Catalog /Pages 2 0 R >>";
    $obj[2] = "<< /Type /Pages /Kids [" . join(' ', map { "$_ 0 R" } @kids) . "] /Count $n >>";
    my $now = strftime('D:%Y%m%d%H%M%S', localtime);
    $obj[5] = sprintf "<< /Title (%s) /Author (%s) /Subject (Hydraulic calculation) "
                    . "/Creator (%s) /Producer (%s) /CreationDate (%s) >>",
        esc($meta{title} // 'Hydraulic calculation'), esc($meta{designer} // ''),
        esc($meta{program} // 'PHCP'), esc($meta{program} // 'PHCP'), $now;
    for my $p (0 .. $n - 1) {
        my ($po, $co) = ($kids[$p], $kids[$p] + 1);
        $obj[$po] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $PAGE_W $PAGE_H] "
                  . "/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents $co 0 R >>";
        $obj[$co] = "<< /Length " . length($streams[$p]) . " >>\nstream\n$streams[$p]endstream";
    }

    # Serialise with a byte-exact cross-reference table.  The four high bytes
    # on the second line mark the file as binary to transfer programs, which is
    # what the specification recommends.
    my $out = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n";
    my @off;
    for my $i (1 .. $#obj) {
        $off[$i] = length $out;
        $out .= "$i 0 obj\n$obj[$i]\nendobj\n";
    }
    my $xref = length $out;
    $out .= "xref\n0 " . scalar(@obj) . "\n0000000000 65535 f \n";
    $out .= sprintf "%010d 00000 n \n", $off[$_] for 1 .. $#obj;
    $out .= "trailer\n<< /Size " . scalar(@obj) . " /Root 1 0 R /Info 5 0 R >>\n"
          . "startxref\n$xref\n%%EOF\n";

    open my $fh, '>:raw', $path or die "cannot write $path: $!\n";
    print $fh $out;
    close $fh;
    return $n;
}

#------------------------------------------------------------------------------
# draw_graph -- the supply graph drawn on Q^1.85 graph paper, into a box the
# full width of the text and $hgt points high below $top.
#
# Left, the plot: pressure up, flow along on a q^1.85 scale -- gridlines at
# round flows crowd to the right as on printed hydraulic graph paper, and a
# Hazen-Williams system curve comes out near straight.  The supply is a solid
# heavy line (straight between its entered points on this paper; its points
# are open circles), the system a dashed line through the solved points
# (dots), the demand point D a square and the operating point O a disc; at
# the demand flow a dimension line shows the margin.  Right, the key and the
# four figures Section 9 states above.
#
# Black on white in the report's typeface, so it reads and photocopies like
# the rest of the calculation.  Each element is preceded by a comment
# (% PHCP-GRAPH ...) giving the coordinates it was drawn at, which a PDF
# reader ignores and tools/test_pdf.pl checks against figures worked
# independently.
#------------------------------------------------------------------------------
sub draw_graph {
    my ($g, $top, $hgt) = @_;
    my $o = '';
    my $cw = $CHAR_W;
    # The plot's rectangle: room on the left for the pressure labels, below
    # for the flow labels and the axis title; the key from column 92.
    my $pl = $LEFT + 9 * $cw;
    my $pr = $LEFT + 86 * $cw;
    my $pt = $top - 14;
    my $pb = $top - $hgt + 3 * $LEADING;
    my ($pw, $ph) = ($pr - $pl, $pt - $pb);
    my ($qmax, $pmax) = @{$g}{qw(qmax pmax)};
    my $X = sub { $pl + ($_[0] > 0 ? ($_[0] / $qmax) ** 1.85 : 0) * $pw };
    my $Y = sub { $pb + $_[0] / $pmax * $ph };
    my $txt = sub {               # text at (x, y): size, bold, alignment l / c / r
        my ($x, $y, $t, $size, $b, $al) = @_;
        my $w = length($t) * $ADVANCE * $size;
        $x -= $al eq 'r' ? $w : $al eq 'c' ? $w / 2 : 0;
        sprintf "BT /F%d %s Tf %.2f %.2f Td (%s) Tj ET\n", $b ? 2 : 1, $size, $x, $y, esc($t);
    };
    my $num = sub { my ($v) = @_; my $t = sprintf '%.6g', $v; $t };
    # The plot's rectangle and its extents in the units the report prints.
    $o .= sprintf "%% PHCP-GRAPH PLOT %.3f %.3f %.3f %.3f %.10g %.10g\n", $pl, $pb, $pw, $ph,
        $qmax / $g->{uf}, $pmax / $g->{up};

    # Grid: pressure lines evenly spaced, flow lines at round flows.
    $o .= "q 0.82 G 0.3 w\n";
    for my $p (@{ $g->{yticks} }) {
        next if $p > $pmax;
        $o .= sprintf "%.2f %.2f m %.2f %.2f l S\n", $pl, $Y->($p), $pr, $Y->($p);
    }
    for my $q (@{ $g->{xticks} }) {
        next if $q > $qmax;
        $o .= sprintf "%.2f %.2f m %.2f %.2f l S\n", $X->($q), $pb, $X->($q), $pt;
    }
    $o .= "Q\n";
    # Labels: every pressure line; a flow label only where it clears the last.
    for my $p (@{ $g->{yticks} }) {
        next if $p > $pmax;
        $o .= $txt->($pl - 4, $Y->($p) - 2.4, $num->($p / $g->{up}), 7, 0, 'r');
    }
    my $last = -1e9;
    for my $q (@{ $g->{xticks} }) {
        next if $q > $qmax;
        my $t = $num->($q / $g->{uf});
        my $w = length($t) * $ADVANCE * 7;
        my $x = $X->($q);
        next if $x - $w / 2 < $last + 6;
        $o .= sprintf "%% PHCP-GRAPH XTICK %s %.3f\n", $t, $x;
        $o .= $txt->($x, $pb - 10, $t, 7, 0, 'c');
        $last = $x + $w / 2;
    }
    $o .= $txt->($pl - 4, $pt + 6, "PRESSURE, $g->{pu}", 7, 1, 'l');
    $o .= $txt->(($pl + $pr) / 2, $pb - 22, "FLOW, $g->{qu}, ON A FLOW^1.85 SCALE", 7, 1, 'c');
    # The frame.
    $o .= sprintf "0 G 0.6 w %.2f %.2f %.2f %.2f re S\n", $pl, $pb, $pw, $ph;

    # Curves and points, clipped to the plot.
    $o .= sprintf "q %.2f %.2f %.2f %.2f re W n\n", $pl, $pb, $pw, $ph;
    my @sp = @{ $g->{supply} };
    $o .= sprintf "%% PHCP-GRAPH SUPPLY %d\n", scalar @sp;
    $o .= sprintf "0 G 1.4 w 1 J 1 j %.2f %.2f m\n", $X->($sp[0][0]), $Y->($sp[0][1]);
    $o .= sprintf "%.2f %.2f l\n", $X->($_->[0]), $Y->($_->[1]) for @sp[1 .. $#sp];
    $o .= "S\n";
    my @sy = @{ $g->{sys} };
    if (@sy > 1) {
        $o .= sprintf "[3 2] 0 d 0.9 w %.2f %.2f m\n", $X->($sy[0][0]), $Y->($sy[0][1]);
        $o .= sprintf "%.2f %.2f l\n", $X->($_->[0]), $Y->($_->[1]) for @sy[1 .. $#sy];
        $o .= "S [] 0 d\n";
    }
    $o .= circle($X->($_->[0]), $Y->($_->[1]), 1.5, 'f') for @sy;
    for my $t (@{ $g->{tests} }) {
        $o .= sprintf "%% PHCP-GRAPH TEST %.3f %.3f\n", $X->($t->[0]), $Y->($t->[1]);
        $o .= "0.7 w 1 g\n" . circle($X->($t->[0]), $Y->($t->[1]), 2.4, 'B') . "0 g\n";
    }

    # The margin, dimensioned at the demand flow: from D up (or down) to the
    # supply, with an arrowhead at each end.  A supply sharing the load with
    # others has no demand point, so no D and no margin.
    my ($qd, $pd) = $g->{demand} ? @{ $g->{demand} } : (0, 0);
    my ($xd, $yd, $ya) = $g->{demand} ? ($X->($qd), $Y->($pd), $Y->($g->{p_avail})) : (0, 0, 0);
    if ($g->{demand} && abs($ya - $yd) > 8) {
        my $dir = $ya > $yd ? 1 : -1;
        $o .= sprintf "0.6 w %.2f %.2f m %.2f %.2f l S\n", $xd, $yd + 4 * $dir, $xd, $ya - 4 * $dir;
        for my $end ([ $yd + 3 * $dir, $dir ], [ $ya - 3 * $dir, -$dir ]) {
            my ($ey, $d) = @$end;
            $o .= sprintf "%.2f %.2f m %.2f %.2f l %.2f %.2f l f\n",
                $xd, $ey - 3 * $d, $xd - 2, $ey + 1 * $d, $xd + 2, $ey + 1 * $d;
        }
    }
    $o .= "Q\n";
    if ($g->{demand}) {
        my ($mlabel, undef, $mval) = @{ $g->{figures}[2] };
        $o .= $txt->($xd + 5, ($yd + $ya) / 2 - 2.4, "$mlabel $mval", 7, 0, 'l') if abs($ya - $yd) > 8;

        # D and O, drawn last so nothing covers them.
        $o .= sprintf "%% PHCP-GRAPH D %.3f %.3f\n", $xd, $yd;
        $o .= sprintf "0 g %.2f %.2f 5 5 re f\n", $xd - 2.5, $yd - 2.5;
        $o .= $txt->($xd - 5, $yd - 2.6, 'D', 8, 1, 'r');
    }
    my ($xo, $yo) = ($X->($g->{oper}[0]), $Y->($g->{oper}[1]));
    $o .= sprintf "%% PHCP-GRAPH O %.3f %.3f\n", $xo, $yo;
    $o .= circle($xo, $yo, 3, 'f');
    $o .= $txt->($xo + 5, $yo + 4, 'O', 8, 1, 'l');

    # The key, and the figures.
    my $kx = $LEFT + 92 * $cw;
    my $ky = $pt - 2;
    my $line = sub { $ky -= 13 };
    $o .= $txt->($kx, $ky, 'KEY', 8, 1, 'l');
    $o .= sprintf "0.4 w %.2f %.2f m %.2f %.2f l S\n", $kx, $ky - 4, $LEFT + $COLS * $cw, $ky - 4;
    $line->();
    $o .= sprintf "1.4 w %.2f %.2f m %.2f %.2f l S\n", $kx, $ky + 2.5, $kx + 22, $ky + 2.5;
    $o .= $txt->($kx + 30, $ky, "SUPPLY AVAILABLE - $g->{id} AT NODE $g->{node}", 7, 0, 'l');
    $line->();
    $o .= sprintf "[3 2] 0 d 0.9 w %.2f %.2f m %.2f %.2f l S [] 0 d\n", $kx, $ky + 2.5, $kx + 22, $ky + 2.5;
    $o .= circle($kx + 11, $ky + 2.5, 1.5, 'f');
    $o .= $txt->($kx + 30, $ky, 'SYSTEM CURVE - EACH POINT A FULL SOLVE', 7, 0, 'l');
    if ($g->{shared}) {
        $line->();
        $o .= $txt->($kx + 30, $ky, 'WITH THE OTHER SUPPLIES CONNECTED', 7, 0, 'l');
    }
    if (@{ $g->{tests} }) {
        $line->();
        $o .= "0.7 w 1 g\n" . circle($kx + 11, $ky + 2.5, 2.4, 'B') . "0 g\n";
        $o .= $txt->($kx + 30, $ky, 'SUPPLY CURVE POINTS AS ENTERED', 7, 0, 'l');
    }
    if ($g->{demand}) {
        $line->();
        $o .= sprintf "%.2f %.2f 5 5 re f\n", $kx + 8.5, $ky;
        $o .= $txt->($kx + 30, $ky, 'D  DEMAND POINT', 7, 0, 'l');
    }
    $line->();
    $o .= circle($kx + 11, $ky + 2.5, 3, 'f');
    $o .= $txt->($kx + 30, $ky, 'O  OPERATING POINT', 7, 0, 'l');
    $line->();
    $line->();
    $o .= $txt->($kx, $ky, $g->{shared} ? 'THIS SUPPLY' : 'SUPPLY AND DEMAND', 8, 1, 'l');
    $o .= sprintf "0.4 w %.2f %.2f m %.2f %.2f l S\n", $kx, $ky - 4, $LEFT + $COLS * $cw, $ky - 4;
    for my $f (@{ $g->{figures} }) {
        $line->();
        my ($lab, $q, $p) = @$f;
        $o .= $txt->($kx, $ky, $lab, 7, 0, 'l');
        $o .= $txt->($kx + 22 * $ADVANCE * 7 + 50, $ky, $q, 7, 0, 'r') if length $q;
        $o .= $txt->($LEFT + $COLS * $cw, $ky, ($q ? 'AT ' : '') . $p, 7, 0, 'r');
    }
    return $o;
}

# circle -- a circle of radius r at (x, y), from four Bezier arcs; $op is the
# paint operator: f fill, S stroke, B both.
sub circle {
    my ($x, $y, $r, $op) = @_;
    my $k = 0.5523 * $r;
    return sprintf "%.2f %.2f m %.2f %.2f %.2f %.2f %.2f %.2f c %.2f %.2f %.2f %.2f %.2f %.2f c "
                 . "%.2f %.2f %.2f %.2f %.2f %.2f c %.2f %.2f %.2f %.2f %.2f %.2f c %s\n",
        $x + $r, $y,
        $x + $r, $y + $k, $x + $k, $y + $r, $x, $y + $r,
        $x - $k, $y + $r, $x - $r, $y + $k, $x - $r, $y,
        $x - $r, $y - $k, $x - $k, $y - $r, $x, $y - $r,
        $x + $k, $y - $r, $x + $r, $y - $k, $x + $r, $y, $op;
}

1;
