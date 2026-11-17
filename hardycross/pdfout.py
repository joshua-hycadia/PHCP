#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# pdfout.py -- Python port of HardyCross/PDF.pm.
#
# The calculation report as a PDF.
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
#   The port keeps the program dependent on nothing beyond the standard
#   library: a PDF library would be the first module a user had to install
#   before the program could print.  The report is 7-bit ASCII by
#   construction, so one simple font encoding covers it.  What remains is a
#   few objects and a cross-reference table, set out in ISO 32000-1, and
#   short enough to read in one sitting.
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
#

import math
import os
import re
import struct
import time
import zlib

PAGE_W, PAGE_H = 842, 595                # A4 landscape
FONT_SIZE = 9
LEADING   = 10.8
COLS      = 132
BODY_TOP  = 545                          # first baseline on a page
BODY_BOT  = 50                           # no baseline below this
PER_PAGE  = int(math.floor((BODY_TOP - BODY_BOT) / LEADING)) + 1
# The width of one character, in em, and so the left margin, are those of
# the face in use: set by write_pdf once the fonts are loaded.
ADVANCE   = 0.6
CHAR_W    = None
LEFT      = None

def set_advance(a):
    global ADVANCE, CHAR_W, LEFT
    ADVANCE = a
    CHAR_W  = ADVANCE * FONT_SIZE
    LEFT    = (PAGE_W - COLS * CHAR_W) / 2

set_advance(0.6)

# The supply graph's box on the page, in lines of text.
GRAPH_LINES = 30

def is_thick(l):
    return re.match(r'^={20,}\s*$', l) is not None

def is_thin(l):
    return re.match(r'^-{20,}\s*$', l) is not None

def blank(l):
    return re.search(r'\S', l) is None

# An indented light rule separates the blocks of a multi-line table -- the
# four lines that describe one pipe in the NFPA schedule.
def is_sub(l):
    return re.match(r'^\s+-{20,}\s*$', l) is not None

#------------------------------------------------------------------------------
# Paginate.
#
# Returns a list of pages, each a list of [text, bold] lines.  Works on the
# report's own structure -- heavy rules around section titles, light rules
# under table headings -- so the text report stays the single source and the
# PDF needs no separate description of its layout.
#------------------------------------------------------------------------------
def paginate(text, graphs=None):
    graphs = graphs or []
    gi = 0                    # the next drawn graph to place
    L = text.split('\n')
    while L and blank(L[-1]):
        L.pop()

    pages = []
    page = []
    table_head = []           # column headings of the table we are inside
    state = {'in_table': 0}

    def new_page():
        nonlocal page
        if page:
            pages.append(page)
        page = []

    def room():
        return PER_PAGE - len(page)

    def put(t, bold=0):
        if not page and blank(t):       # never open a page on a gap
            return
        page.append([t, 1 if bold else 0])

    i = 0
    while i < len(L):
        l = L[i]

        # A section heading: heavy rule, title, heavy rule.  Keep it with at
        # least the next few lines of its section.
        if is_thick(l) and i + 2 <= len(L) - 1 and is_thick(L[i + 2]) and not is_thick(L[i + 1]):
            # Every numbered section starts on a page of its own, so each part
            # of the calculation can be found, filed and replaced by itself -
            # the pipe schedule of a revision can be swapped without reprinting
            # the rest.  The cover sheet, which has no number, keeps page 1.
            if re.match(r'^\s*\d+\.\s', L[i + 1]):
                if page:
                    new_page()
            else:
                need = 3
                k = i + 3
                while k <= len(L) - 1 and k < i + 9:
                    need += 1
                    k += 1
                if room() < need and page:
                    new_page()
            put(l)
            put(L[i + 1], 1)             # the title itself in bold
            put(L[i + 2])
            i += 2
            state['in_table'] = 0
            table_head = []
            i += 1
            continue

        # The supply graph moves to a new page whole rather than be cut.
        # With the graph's numbers to hand, its character drawing is left out
        # and a box of $GRAPH_LINES lines is kept for the drawn graph: the
        # heading stays as text, the first line of the box carries the mark
        # 'graph', and write_pdf draws into it.
        # Each graph in the text, in order, is drawn from the next set of
        # numbers in @$graphs; one supply gives one graph, several give one each.
        if re.match(r'^ SUPPLY GRAPH', l):
            j = i
            while j < len(L) - 1 and not re.search(r'O\s+operating point|D\s+combined duty', L[j]):
                j += 1
            graph = graphs[gi] if gi < len(graphs) else None
            gi += 1
            h = (GRAPH_LINES + 2) if graph else (j - i + 1)
            if room() < h and h <= PER_PAGE and page:
                new_page()
            if graph:
                put(l, 1)
                page.append(['', 0, 'graph', graph])
                for _ in range(2, GRAPH_LINES + 1):
                    page.append(['', 0])
            else:
                for k in range(i, j + 1):
                    put(L[k])
            i = j
            i += 1
            continue

        # A light rule directly under non-blank lines is the underline of a
        # table's column headings: remember them, so a page break inside the
        # table can repeat them.  A light rule after data closes the table.
        if is_thin(l):
            if state['in_table']:
                state['in_table'] = 0
                table_head = []
                # a closing rule is pulled back to the page its table ended on
                if room() < 1:
                    new_page()
                put(l)
                i += 1
                continue
            head = []
            k = i - 1
            while k >= 0 and k >= i - 3:
                if blank(L[k]) or is_thick(L[k]) or is_thin(L[k]):
                    break
                head.insert(0, L[k])
                k -= 1
            if head:
                # Headings and at least two rows of data go together.
                if room() < 3 and len(page) >= len(head):
                    del page[-len(head):]       # take the headings off this page
                    new_page()
                    for x in head:
                        put(x)
                table_head = head + [l]
                state['in_table'] = 1
            put(l)
            i += 1
            continue

        if state['in_table'] and blank(l):
            state['in_table'] = 0

        # A block of a multi-line table moves to the next page whole, under
        # repeated headings.  Split, a pipe's pressure at one end would sit on
        # one page and at the other end on the next -- the sum Pt BEG - Pe - Pf
        # = Pt END could not be done without turning the page.
        if (state['in_table'] and not blank(l) and not is_sub(l)
                and (i == 0 or is_thin(L[i - 1]) or is_sub(L[i - 1]))):
            k = 0
            while (i + k <= len(L) - 1 and not blank(L[i + k])
                   and not is_sub(L[i + k]) and not is_thin(L[i + k])):
                k += 1
            block_has_room = k <= PER_PAGE - len(table_head) - 1
            if block_has_room and room() < k and page:
                # a separator left dangling at the foot of the page goes too
                while page and is_sub(page[-1][0]):
                    page.pop()
                new_page()
                put(' (continued)')
                for x in table_head:
                    put(x)
        # A block separator is never the first line of a page.
        if is_sub(l) and not page:
            i += 1
            continue

        # A short paragraph -- the notes and checks under a table, a numbered
        # assumption -- moves to the next page whole rather than split.  Table
        # rows may break, because their headings are repeated; a paragraph has
        # nothing to repeat, and its second half read alone at the top of a
        # page is a set of checks with no table in sight.
        if (not state['in_table'] and not blank(l)
                and (i == 0 or blank(L[i - 1]) or is_thin(L[i - 1]) or is_thick(L[i - 1]))):
            k = 0
            while (i + k <= len(L) - 1 and not blank(L[i + k])
                   and not is_thin(L[i + k]) and not is_thick(L[i + k])):
                k += 1
            if k <= 8 and room() < k and page:
                new_page()

        if room() < 1:
            new_page()
            if state['in_table'] and table_head:
                put(' (continued)')
                for x in table_head:
                    put(x)
        put(l)
        i += 1
    new_page()
    return pages

#------------------------------------------------------------------------------
# PDF string escaping.  Backslash and both parentheses; anything outside
# printable ASCII cannot reach here, because the report writer forbids it, but
# is replaced rather than trusted if it ever does.
#------------------------------------------------------------------------------
def esc(t):
    t = re.sub(r'[^\x20-\x7E]', '?', t)
    t = re.sub(r'([\\()])', r'\\\1', t)
    return t

def fit(t, w):
    return t[:w - 3] + '...' if len(t) > w else t

#------------------------------------------------------------------------------
# The typeface.
#
# load_font reads a TrueType file and returns what the PDF needs to embed it:
# the bytes, and from the font's own tables the units per em, the advance
# width (one for every character -- it is a monospace face), the bounding
# box, ascent, descent and cap height.  Returns None if the file is not
# there.  The tables are read as the TrueType specification sets them out;
# nothing else in the file is touched.
#------------------------------------------------------------------------------
def _module_dir():
    return os.path.dirname(os.path.abspath(__file__))

def font_dir():
    # This file is hardycross/pdfout.py, so the fonts are one folder up from
    # its own, in data/fonts.
    here = _module_dir()
    try_dirs = [os.path.join(here, os.pardir, 'data', 'fonts')]
    par = os.environ.get('PAR_TEMP')
    if par:
        try_dirs.append(os.path.join(par, 'inc', 'lib', 'data', 'fonts'))
    try_dirs.append(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])),
                                 'data', 'fonts'))
    for d in try_dirs:
        if os.path.isdir(d):
            return d
    return try_dirs[0]

import sys

def load_font(name):
    path = os.path.join(font_dir(), name)
    try:
        with open(path, 'rb') as fh:
            b = fh.read()
    except OSError:
        return None
    n = struct.unpack('>H', b[4:6])[0]
    t = {}
    for i in range(n):
        tag = b[12 + 16 * i:12 + 16 * i + 4]
        off, ln = struct.unpack('>II', b[12 + 16 * i + 8:12 + 16 * i + 16])
        t[tag] = (off, ln)
    if not (b'head' in t and b'hhea' in t and b'hmtx' in t):
        return None

    def i16(off):
        v = struct.unpack('>H', b[off:off + 2])[0]
        return v - 65536 if v >= 32768 else v

    def u16(off):
        return struct.unpack('>H', b[off:off + 2])[0]

    h = t[b'head'][0]
    upm = u16(h + 18)
    k = 1000 / upm
    f = {'bytes': b, 'upm': upm,
         'advance': u16(t[b'hmtx'][0]) * k,
         'bbox': [int(i16(h + off) * k) for off in (36, 38, 40, 42)],
         'ascent': int(i16(t[b'hhea'][0] + 4) * k),
         'descent': int(i16(t[b'hhea'][0] + 6) * k)}
    f['cap'] = (int(i16(t[b'OS/2'][0] + 88) * k)
                if (b'OS/2' in t and u16(t[b'OS/2'][0]) >= 2) else f['ascent'])
    return f

#------------------------------------------------------------------------------
# Write the PDF.
#   %meta: title, job, revision, date, designer, model, program, and graphs --
#   the supply graphs' numbers (report.supply_graph_data), in
#   the order the graphs appear in the text, which draw each graph in place of
#   the report's character drawing.  (graph, one set, is still taken.)  And
#   sheets: pages added after the text, each a sub given (page, pages) that
#   returns its content stream -- a supply graph sheet (SUPPLYGRAPH), numbered
#   with the report.
#------------------------------------------------------------------------------
def write_pdf(text, path, **meta):
    reg, bold = fonts()
    graphs = meta.get('graphs') or ([meta['graph']] if meta.get('graph') else [])
    pages = paginate(text, graphs)
    sheets = list(meta.get('sheets') or [])
    n = len(pages) + len(sheets)

    # Build each page's content stream.
    streams = []
    for p in range(len(pages)):
        s = frame(p + 1, n, **meta)

        # The body, one Tj per line, bold only for section titles.  A rule is
        # not typed: its line is left empty and the rule drawn after -- heavy
        # for '=', light for '-', and an indented light rule from its indent.
        s += 'BT /F1 %s Tf %s TL %.2f %.2f Td\n' % (_fmt(FONT_SIZE), _fmt(LEADING), LEFT, BODY_TOP)
        fb = 0
        rules = []
        gy = []
        y = BODY_TOP
        for ln in pages[p]:
            t, b = ln[0], ln[1]
            mark = ln[2] if len(ln) > 2 else None
            g = ln[3] if len(ln) > 3 else None
            if (mark or '') == 'graph':
                gy.append((y, g))
            if is_thick(t) or is_thin(t) or is_sub(t):
                ind = len(re.match(r'^(\s*)', t).group(1))
                ln_m = re.match(r'^\s*(\S+)', t)
                length = len(ln_m.group(1)) if ln_m else 0
                rules.append((y + FONT_SIZE * 0.3, ind, length, 1.0 if is_thick(t) else 0.4))
                s += 'T*\n'
            else:
                if b != fb:
                    s += ('/F2' if b else '/F1') + ' %s Tf\n' % _fmt(FONT_SIZE)
                    fb = b
                s += '(%s) Tj T*\n' % esc(t)
            y -= LEADING
        s += 'ET\n'
        for r in rules:
            ry, ind, length, wt = r
            s += ('%% PHCP-RULE %.1f\n%.2f w %.2f %.2f m %.2f %.2f l S\n'
                  % (wt, wt, LEFT + ind * CHAR_W, ry, LEFT + (ind + length) * CHAR_W, ry))
        for yy, gg in gy:
            s += draw_graph(gg, yy + LEADING * 0.6, GRAPH_LINES * LEADING)
        streams.append(s)
    for i in range(len(sheets)):
        streams.append(sheets[i](len(pages) + i + 1, n))

    return write_pages(streams, path, reg, bold, **meta)

#------------------------------------------------------------------------------
# fonts -- the regular and bold faces, loaded and set as the face in use; both
# None (Courier) if either file is missing.
#------------------------------------------------------------------------------
def fonts():
    reg = load_font('DejaVuSansMono.ttf')
    bold = load_font('DejaVuSansMono-Bold.ttf') if reg else None
    if not (reg and bold):
        reg = bold = None
    set_advance(reg['advance'] / 1000 if reg else 0.6)
    return reg, bold

#------------------------------------------------------------------------------
# frame -- the hairlines, running header and footer of page $p of $n, as a
# content stream.  %meta as write_pdf; header names the left-hand header
# ('PHCP  HYDRAULIC CALCULATION' unless given).
#------------------------------------------------------------------------------
def frame(p, n, **meta):
    hdr_left  = meta.get('header') or 'PHCP  HYDRAULIC CALCULATION'
    hdr_right = '   '.join(x for x in (('%s' % ('Job %s' % meta['job'])) if meta.get('job') else '',
                                      ('%s' % ('Rev %s' % meta['revision'])) if meta.get('revision') else '',
                                      meta.get('date') or '') if len(x))
    hdr_mid   = fit(meta.get('title') or '', COLS - len(hdr_left) - len(hdr_right) - 6)
    s = ''
    # hairlines under the header and over the footer
    s += '0.5 w %.2f %.2f m %.2f %.2f l S\n' % (LEFT, 560, PAGE_W - LEFT, 560)
    s += '0.5 w %.2f %.2f m %.2f %.2f l S\n' % (LEFT, 38, PAGE_W - LEFT, 38)

    # running header, laid out on the same 132-column grid as the body
    h = hdr_left
    mid_at = int((COLS - len(hdr_mid)) / 2)
    if len(h) < mid_at:
        h += ' ' * (mid_at - len(h))
    h += hdr_mid
    h += ' ' * (COLS - len(h) - len(hdr_right)) + hdr_right
    s += 'BT /F2 %s Tf %.2f %.2f Td (%s) Tj ET\n' % (_fmt(FONT_SIZE), LEFT, 566, esc(h))

    # footer: what was calculated, and where this page sits in it
    # The footer is set smaller than the body, so the page number is
    # placed by its width in points against the right margin, not by
    # counting columns of the body's size.
    pg = 'Page %d of %d' % (p, n)
    fl = fit((meta.get('program') or 'PHCP')
             + ('   %s' % meta['model'] if meta.get('model') else ''),
             COLS - len(pg) - 2)
    s += 'BT /F1 %s Tf %.2f %.2f Td (%s) Tj ET\n' % (_fmt(8), LEFT, 26, esc(fl))
    s += 'BT /F1 %s Tf %.2f %.2f Td (%s) Tj ET\n' % (_fmt(8),
        LEFT + COLS * CHAR_W - len(pg) * ADVANCE * 8, 26, esc(pg))
    return s

# geometry -- the page and the text grid, for a caller drawing its own page:
# page width and height, left margin, width of a character at the body size,
# the advance in em, the body size and leading, and the number of columns.
def geometry():
    return {'page_w': PAGE_W, 'page_h': PAGE_H, 'left': LEFT, 'char_w': CHAR_W,
            'advance': ADVANCE, 'size': FONT_SIZE, 'leading': LEADING, 'cols': COLS,
            'top': BODY_TOP, 'bottom': BODY_BOT}

#------------------------------------------------------------------------------
# write_pages -- the PDF file itself from finished page content streams: the
# fonts (embedded, or Courier), the document information from %meta, and a
# byte-exact cross-reference table.  Returns the number of pages.
#------------------------------------------------------------------------------
def write_pages(streams, path, reg, bold, **meta):
    streams = list(streams)
    n = len(streams)
    # Objects: 1 catalog, 2 page tree, 3 regular font, 4 bold font, 5
    # document info; then, for embedded fonts, each font's descriptor and
    # file; then each page and its content.
    obj = {}

    def font(f, name):
        base = '/Type /Font /Subtype /Type1 /BaseFont /%s /Encoding /WinAnsiEncoding' % name
        if not f:
            return '<< %s >>' % base
        nonlocal next_id
        desc, file = next_id, next_id + 1
        next_id += 2
        z = zlib.compress(f['bytes'])
        obj[desc] = ('<< /Type /FontDescriptor /FontName /%s /Flags 33 /FontBBox [%s] '
                     '/ItalicAngle 0 /Ascent %d /Descent %d /CapHeight %d /StemV %d /FontFile2 %d 0 R >>'
                     % (name, ' '.join(str(x) for x in f['bbox']), f['ascent'], f['descent'],
                        f['cap'], 140 if re.search(r'Bold', name) else 80, file))
        obj[file] = ('<< /Length %d /Length1 %d /Filter /FlateDecode >>\nstream\n%sendstream'
                     % (len(z), len(f['bytes']), (z + b'\n').decode('latin-1')))
        w = '%d' % int(f['advance'] + 0.5)
        return ('<< /Type /Font /Subtype /TrueType /BaseFont /%s /FirstChar 32 /LastChar 126 '
                '/Widths [%s] /Encoding /WinAnsiEncoding /FontDescriptor %d 0 R >>'
                % (name, ' '.join([w] * 95), desc))

    next_id = 6
    obj[3] = font(reg, 'DejaVuSansMono' if reg else 'Courier')
    obj[4] = font(bold, 'DejaVuSansMono-Bold' if bold else 'Courier-Bold')
    kids = [next_id + 2 * i for i in range(n)]
    obj[1] = '<< /Type /Catalog /Pages 2 0 R >>'
    obj[2] = ('<< /Type /Pages /Kids [%s] /Count %d >>'
              % (' '.join('%d 0 R' % k for k in kids), n))
    now = time.strftime('D:%Y%m%d%H%M%S')
    obj[5] = ('<< /Title (%s) /Author (%s) /Subject (Hydraulic calculation) '
              '/Creator (%s) /Producer (%s) /CreationDate (%s) >>'
              % (esc(meta.get('title') or 'Hydraulic calculation'), esc(meta.get('designer') or ''),
                 esc(meta.get('program') or 'PHCP'), esc(meta.get('program') or 'PHCP'), now))
    for p in range(n):
        po, co = kids[p], kids[p] + 1
        obj[po] = ('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] '
                   '/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents %d 0 R >>'
                   % (PAGE_W, PAGE_H, co))
        obj[co] = '<< /Length %d >>\nstream\n%sendstream' % (len(streams[p]), streams[p])

    # Serialise with a byte-exact cross-reference table.  The four high bytes
    # on the second line mark the file as binary to transfer programs, which is
    # what the specification recommends.
    out = b'%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'
    off = {}
    for i in range(1, len(obj) + 1):
        off[i] = len(out)
        out += ('%d 0 obj\n%s\nendobj\n' % (i, obj[i])).encode('latin-1')
    xref = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(obj) + 1)
    for i in range(1, len(obj) + 1):
        out += ('%010d 00000 n \n' % off[i]).encode('latin-1')
    out += (('trailer\n<< /Size %d /Root 1 0 R /Info 5 0 R >>\nstartxref\n%d\n%%%%EOF\n'
             % (len(obj) + 1, xref)).encode('latin-1'))

    with open(path, 'wb') as fh:
        fh.write(out)
    return n

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
def draw_graph(g, top, hgt):
    o = ''
    cw = CHAR_W
    # The plot's rectangle: room on the left for the pressure labels, below
    # for the flow labels and the axis title; the key from column 92.
    pl = LEFT + 9 * cw
    pr = LEFT + 86 * cw
    pt = top - 14
    pb = top - hgt + 3 * LEADING
    pw, ph = pr - pl, pt - pb
    qmax, pmax = g['qmax'], g['pmax']

    def X(q):
        return pl + ((q / qmax) ** 1.85 if q > 0 else 0) * pw

    def Y(p):
        return pb + p / pmax * ph

    def txt(x, y, t, size, b=0, al='l'):    # text at (x, y): size, bold, alignment l / c / r
        w = len(t) * ADVANCE * size
        if al == 'r':
            x -= w
        elif al == 'c':
            x -= w / 2
        return 'BT /F%d %s Tf %.2f %.2f Td (%s) Tj ET\n' % (2 if b else 1, _fmt(size), x, y, esc(t))

    def num(v):
        return '%.6g' % v
    # The plot's rectangle and its extents in the units the report prints.
    o += '%% PHCP-GRAPH PLOT %.3f %.3f %.3f %.3f %.10g %.10g\n' % (
        pl, pb, pw, ph, qmax / g['uf'], pmax / g['up'])

    # Grid: pressure lines evenly spaced, flow lines at round flows.
    o += 'q 0.82 G 0.3 w\n'
    for p in g['yticks']:
        if p > pmax:
            continue
        o += '%.2f %.2f m %.2f %.2f l S\n' % (pl, Y(p), pr, Y(p))
    for q in g['xticks']:
        if q > qmax:
            continue
        o += '%.2f %.2f m %.2f %.2f l S\n' % (X(q), pb, X(q), pt)
    o += 'Q\n'
    # Labels: every pressure line; a flow label only where it clears the last.
    for p in g['yticks']:
        if p > pmax:
            continue
        o += txt(pl - 4, Y(p) - 2.4, num(p / g['up']), 7, 0, 'r')
    last = -1e9
    for q in g['xticks']:
        if q > qmax:
            continue
        t = num(q / g['uf'])
        w = len(t) * ADVANCE * 7
        x = X(q)
        if x - w / 2 < last + 6:
            continue
        o += '%% PHCP-GRAPH XTICK %s %.3f\n' % (t, x)
        o += txt(x, pb - 10, t, 7, 0, 'c')
        last = x + w / 2
    o += txt(pl - 4, pt + 6, 'PRESSURE, %s' % g['pu'], 7, 1, 'l')
    o += txt((pl + pr) / 2, pb - 22, 'FLOW, %s, ON A FLOW^1.85 SCALE' % g['qu'], 7, 1, 'c')
    # The frame.
    o += '0 G 0.6 w %.2f %.2f %.2f %.2f re S\n' % (pl, pb, pw, ph)

    # Curves and points, clipped to the plot.
    o += 'q %.2f %.2f %.2f %.2f re W n\n' % (pl, pb, pw, ph)
    # Combined: each supply's own curve, thin and grey, under the combined.
    labels = []
    for part in (g.get('parts') or []):
        id_, pts = part
        in_ = [p for p in pts if p[1] >= 0]
        if not len(in_) > 1:
            continue
        o += '%% PHCP-GRAPH PART %s\n' % id_
        o += '0.55 G 0.6 w %.2f %.2f m\n' % (X(in_[0][0]), Y(in_[0][1]))
        for p in in_[1:]:
            o += '%.2f %.2f l\n' % (X(p[0]), Y(p[1]))
        o += 'S 0 G\n'
        # Its name just above the curve, a fifth of the way along the axis.
        at_ = next((p for p in in_ if X(p[0]) >= pl + 0.2 * pw), None)
        if not at_:
            continue
        # Curves that coincide (two identical pumps) would print their names
        # on top of each other: each later name steps down a line.
        lx, ly = X(at_[0]), Y(at_[1]) + 3
        while any(abs(l[0] - lx) < 1 and abs(l[1] - ly) < 8 for l in labels):
            ly -= 9
        labels.append((lx, ly, id_))
    sp = g['supply']
    o += '%% PHCP-GRAPH SUPPLY %d\n' % len(sp)
    o += '0 G 1.4 w 1 J 1 j %.2f %.2f m\n' % (X(sp[0][0]), Y(sp[0][1]))
    for p in sp[1:]:
        o += '%.2f %.2f l\n' % (X(p[0]), Y(p[1]))
    o += 'S\n'
    sy = g['sys']
    if len(sy) > 1:
        o += '[3 2] 0 d 0.9 w %.2f %.2f m\n' % (X(sy[0][0]), Y(sy[0][1]))
        for p in sy[1:]:
            o += '%.2f %.2f l\n' % (X(p[0]), Y(p[1]))
        o += 'S [] 0 d\n'
    for p in sy:
        o += circle(X(p[0]), Y(p[1]), 1.5, 'f')
    for t in g.get('tests') or []:
        o += '%% PHCP-GRAPH TEST %.3f %.3f\n' % (X(t[0]), Y(t[1]))
        o += '0.7 w 1 g\n' + circle(X(t[0]), Y(t[1]), 2.4, 'B') + '0 g\n'

    # The margin, dimensioned at the demand flow: from D up (or down) to the
    # supply, with an arrowhead at each end.  A supply sharing the load with
    # others has no demand point, so no D and no margin.
    if g.get('demand'):
        qd, pd = g['demand']
        xd, yd, ya = X(qd), Y(pd), Y(g['p_avail'])
    else:
        qd = pd = xd = yd = ya = 0
    has_margin = bool(g.get('demand')) and g.get('margin') is not None
    if has_margin and abs(ya - yd) > 8:
        dir_ = 1 if ya > yd else -1
        o += '0.6 w %.2f %.2f m %.2f %.2f l S\n' % (xd, yd + 4 * dir_, xd, ya - 4 * dir_)
        for ey, d in ((yd + 3 * dir_, dir_), (ya - 3 * dir_, -dir_)):
            o += '%.2f %.2f m %.2f %.2f l %.2f %.2f l f\n' % (
                xd, ey - 3 * d, xd - 2, ey + 1 * d, xd + 2, ey + 1 * d)
    o += 'Q\n'
    if g.get('demand'):
        mlabel, mval = g['figures'][2][0], g['figures'][2][2]
        if has_margin and abs(ya - yd) > 8:
            o += txt(xd + 5, (yd + ya) / 2 - 2.4, '%s %s' % (mlabel, mval), 7, 0, 'l')

        # D and O, drawn last so nothing covers them.
        o += '%% PHCP-GRAPH D %.3f %.3f\n' % (xd, yd)
        o += '0 g %.2f %.2f 5 5 re f\n' % (xd - 2.5, yd - 2.5)
        o += txt(xd - 5, yd - 2.6, 'D', 8, 1, 'r')
    for lx, ly, id_ in labels:
        o += txt(lx, ly, id_, 7, 0, 'l')
    if g.get('oper'):
        xo, yo = X(g['oper'][0]), Y(g['oper'][1])
        o += '%% PHCP-GRAPH O %.3f %.3f\n' % (xo, yo)
        o += circle(xo, yo, 3, 'f')
        o += txt(xo + 5, yo + 4, 'O', 8, 1, 'l')

    # The key, and the figures.
    kx = LEFT + 92 * cw
    ky = [pt - 2]

    def line():
        ky[0] -= 13
    o += txt(kx, ky[0], 'KEY', 8, 1, 'l')
    o += '0.4 w %.2f %.2f m %.2f %.2f l S\n' % (kx, ky[0] - 4, LEFT + COLS * cw, ky[0] - 4)
    line()
    o += '1.4 w %.2f %.2f m %.2f %.2f l S\n' % (kx, ky[0] + 2.5, kx + 22, ky[0] + 2.5)
    if g.get('combined'):
        o += txt(kx + 30, ky[0], 'ALL SUPPLIES - FLOWS ADDED AT EQUAL PRESSURE', 7, 0, 'l')
        line()
        o += '0.55 G 0.6 w %.2f %.2f m %.2f %.2f l S 0 G\n' % (kx, ky[0] + 2.5, kx + 22, ky[0] + 2.5)
        o += txt(kx + 30, ky[0], 'EACH SUPPLY ON ITS OWN, NAMED ON ITS CURVE', 7, 0, 'l')
    else:
        o += txt(kx + 30, ky[0], 'SUPPLY AVAILABLE - %s AT NODE %s' % (g['id'], g['node']), 7, 0, 'l')
    if len(g['sys']) or not g.get('combined'):
        line()
        o += '[3 2] 0 d 0.9 w %.2f %.2f m %.2f %.2f l S [] 0 d\n' % (kx, ky[0] + 2.5, kx + 22, ky[0] + 2.5)
        o += circle(kx + 11, ky[0] + 2.5, 1.5, 'f')
        o += txt(kx + 30, ky[0], 'SYSTEM CURVE - EACH POINT A FULL SOLVE', 7, 0, 'l')
    if g.get('shared'):
        line()
        o += txt(kx + 30, ky[0], 'WITH THE OTHER SUPPLIES CONNECTED', 7, 0, 'l')
    if g.get('tests'):
        line()
        o += '0.7 w 1 g\n' + circle(kx + 11, ky[0] + 2.5, 2.4, 'B') + '0 g\n'
        o += txt(kx + 30, ky[0], 'SUPPLY CURVE POINTS AS ENTERED', 7, 0, 'l')
    if g.get('demand'):
        line()
        o += '%.2f %.2f 5 5 re f\n' % (kx + 8.5, ky[0])
        o += txt(kx + 30, ky[0], 'D  COMBINED DUTY' if g.get('combined') else 'D  DEMAND POINT', 7, 0, 'l')
    if g.get('oper'):
        line()
        o += circle(kx + 11, ky[0] + 2.5, 3, 'f')
        o += txt(kx + 30, ky[0], 'O  OPERATING POINT', 7, 0, 'l')
    line()
    line()
    o += txt(kx, ky[0], 'ALL SUPPLIES COMBINED' if g.get('combined')
             else ('THIS SUPPLY' if g.get('shared') else 'SUPPLY AND DEMAND'), 8, 1, 'l')
    o += '0.4 w %.2f %.2f m %.2f %.2f l S\n' % (kx, ky[0] - 4, LEFT + COLS * cw, ky[0] - 4)
    for f in g['figures']:
        line()
        lab, q, p = f
        o += txt(kx, ky[0], lab, 7, 0, 'l')
        if len(q):
            o += txt(kx + 22 * ADVANCE * 7 + 50, ky[0], q, 7, 0, 'r')
        o += txt(LEFT + COLS * cw, ky[0], ('AT ' if q else '') + p, 7, 0, 'r')
    return o

# circle -- a circle of radius r at (x, y), from four Bezier arcs; $op is the
# paint operator: f fill, S stroke, B both.
def circle(x, y, r, op):
    k = 0.5523 * r
    return ('%.2f %.2f m %.2f %.2f %.2f %.2f %.2f %.2f c %.2f %.2f %.2f %.2f %.2f %.2f c '
            '%.2f %.2f %.2f %.2f %.2f %.2f c %.2f %.2f %.2f %.2f %.2f %.2f c %s\n'
            % (x + r, y,
               x + r, y + k, x + k, y + r, x, y + r,
               x - k, y + r, x - r, y + k, x - r, y,
               x - r, y - k, x - k, y - r, x, y - r,
               x + k, y - r, x + r, y - k, x + r, y, op))

# Perl stringifies a number in a PDF operator without trailing zeros.
def _fmt(v):
    return '%g' % v
