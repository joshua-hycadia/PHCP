#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# HardyCross/PDF.pm -- the calculation report as a PDF, in core Perl.
#
# WHAT THIS IS
#   A faithful, paginated print of the ASCII report -- the same characters in
#   the same columns, set in Courier on A4 landscape -- with a running header,
#   a page footer and page breaks placed where a reader expects them.  It is
#   not a redesign.  The text report and the PDF are made from the same solved
#   network in the same run, so the two cannot disagree.
#
# WHY WRITE THE PDF BY HAND
#   PHCP is Perl with no dependencies beyond Tk.  A PDF library would be the
#   first module a user had to install before the program could print.  The
#   report is 7-bit ASCII by construction, so it needs only Courier -- one of
#   the fourteen fonts every PDF reader must supply -- and no font is embedded.
#   What remains is a few objects and a cross-reference table, set out in
#   ISO 32000-1, and short enough to read in one sitting.
#
# THE PAGE
#   A4 landscape, 842 x 595 pt.  Courier advances 600/1000 em, so 132 columns
#   at 9 pt are 712.8 pt wide and sit centred with 64.6 pt margins -- the full
#   page width is used without shrinking the type below what reads comfortably
#   on paper.  46 lines of 10.8 pt leading fit between header and footer.
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

my ($PAGE_W, $PAGE_H) = (842, 595);          # A4 landscape
my $FONT_SIZE = 9;
my $LEADING   = 10.8;
my $COLS      = 132;
my $CHAR_W    = 0.6 * $FONT_SIZE;             # Courier: 600 units per em
my $LEFT      = ($PAGE_W - $COLS * $CHAR_W) / 2;
my $BODY_TOP  = 545;                          # first baseline on a page
my $BODY_BOT  = 50;                           # no baseline below this
my $PER_PAGE  = floor(($BODY_TOP - $BODY_BOT) / $LEADING) + 1;

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
    my @L = split /\n/, shift, -1;
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
        if ($l =~ /^ SUPPLY GRAPH/) {
            my $j = $i;
            $j++ while $j < $#L && $L[$j] !~ /O\s+operating point/;
            my $h = $j - $i + 1;
            $new_page->() if $room->() < $h && $h <= $PER_PAGE && @page;
            $put->($L[$_]) for $i .. $j;
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
# Write the PDF.
#   %meta: title, job, revision, date, designer, model, program
#------------------------------------------------------------------------------
sub write_pdf {
    my ($text, $path, %meta) = @_;
    my $pages = paginate($text);
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
        my $pg = sprintf 'Page %d of %d', $p + 1, $n;
        my $fl = fit(($meta{program} // 'PHCP') . ($meta{model} ? "   $meta{model}" : ''),
                     $COLS - length($pg) - 2);
        my $f = $fl . ' ' x ($COLS - length($fl) - length($pg)) . $pg;
        $s .= sprintf "BT /F1 %s Tf %.2f %.2f Td (%s) Tj ET\n", 8, $LEFT, 26, esc($f);

        # the body, one Tj per line, switching to bold only for section titles
        $s .= sprintf "BT /F1 %s Tf %s TL %.2f %.2f Td\n", $FONT_SIZE, $LEADING, $LEFT, $BODY_TOP;
        my $bold = 0;
        for my $ln (@{ $pages->[$p] }) {
            my ($t, $b) = @$ln;
            if ($b != $bold) { $s .= ($b ? '/F2' : '/F1') . " $FONT_SIZE Tf\n"; $bold = $b }
            $s .= '(' . esc($t) . ") Tj T*\n";
        }
        $s .= "ET\n";
        push @streams, $s;
    }

    # Object numbers: 1 catalog, 2 page tree, 3 Courier, 4 Courier-Bold,
    # 5 document info, then for each page a page object and its content.
    my @obj;
    my @kids = map { 6 + 2 * $_ } 0 .. $n - 1;
    $obj[1] = "<< /Type /Catalog /Pages 2 0 R >>";
    $obj[2] = "<< /Type /Pages /Kids [" . join(' ', map { "$_ 0 R" } @kids) . "] /Count $n >>";
    $obj[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>";
    $obj[4] = "<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>";
    my $now = strftime('D:%Y%m%d%H%M%S', localtime);
    $obj[5] = sprintf "<< /Title (%s) /Author (%s) /Subject (Hydraulic calculation) "
                    . "/Creator (%s) /Producer (%s) /CreationDate (%s) >>",
        esc($meta{title} // 'Hydraulic calculation'), esc($meta{designer} // ''),
        esc($meta{program} // 'PHCP'), esc($meta{program} // 'PHCP'), $now;
    for my $p (0 .. $n - 1) {
        my ($po, $co) = (6 + 2 * $p, 7 + 2 * $p);
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

1;
