#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_pdf.py -- check the PDF report without any PDF tool installed.
# Python port of test_pdf.pl, check for check.
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
#   python3 tools/test_pdf.py [model.phc ...]
#
# The PDF and the text report are read as bytes (latin-1), as the Perl reads
# them, so a byte offset in the file is an index in the string.
#==============================================================================
import glob
import os
import re
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)

models = sys.argv[1:] if len(sys.argv) > 1 else \
    [m for m in sorted(glob.glob(os.path.join(ROOT, 'examples', '*.phc'))) if 'grid1000' not in m]
checks, fails = 0, 0


def ok(what, c):
    global checks, fails
    checks += 1
    if c:
        return 1
    fails += 1
    print('  FAIL %s' % what)
    return 0


def num(s):
    # Perl numification: the leading number of a string, undef as 0.
    if s is None:
        return 0.0
    m = re.match(r'\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)', s)
    return float(m.group(1)) if m else 0.0


def perl_split_lines(t):
    # split /\n/: trailing empty fields are dropped.
    f = t.split('\n')
    while f and f[-1] == '':
        f.pop()
    return f


# run -- phcp on a model, quietly, by this Python and without a shell, so it
# runs the same on Windows (no /dev/null, no #! line there).
def run(*args):
    subprocess.run([sys.executable, os.path.join(ROOT, 'phcp')] + list(args),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def slurp(p):
    with open(p, 'rb') as f:
        return f.read().decode('latin-1')


def slurp_text(p):
    # As the Perl's open '<': text mode, so CRLF is read as LF on Windows.
    with open(p, 'rb') as f:
        b = f.read()
    if os.name == 'nt':
        b = b.replace(b'\r\n', b'\n')
    return b.decode('latin-1')


tmpfiles = []
for m in models:
    name = os.path.basename(m)
    fd, txt = tempfile.mkstemp(suffix='.txt')
    os.close(fd)
    fd, pdf = tempfile.mkstemp(suffix='.pdf')
    os.close(fd)
    tmpfiles += [txt, pdf]
    run(m, txt)
    run(m, pdf)
    try:
        P = slurp(pdf)
        T = slurp_text(txt)
    except OSError:
        continue

    ok('%s: PDF header' % name, re.match(r'%PDF-1\.\d\n', P) is not None)
    ok('%s: ends with %%%%EOF' % name, re.search(r'%%EOF\n?\Z', P) is not None)
    mo = re.search(r'startxref\n(\d+)\n%%EOF', P)
    sx = int(mo.group(1)) if mo else None
    ok('%s: startxref points at the xref table' % name,
       sx is not None and P[sx:sx + 4] == 'xref')

    # every in-use xref entry must land exactly on its object
    tail = P[sx or 0:]
    mo = re.match(r'xref\n(\d+) (\d+)\n', tail)
    first, count = (int(mo.group(1)), int(mo.group(2))) if mo else (0, 0)
    entries = re.findall(r'^(\d{10}) (\d{5}) ([nf]) ?\r?\n', tail, re.M)
    bad = 0
    for k, (off, gen, typ) in enumerate(entries):
        if typ != 'n':
            continue
        n = first + k
        want = '%d 0 obj' % n
        off = int(off)
        if P[off:off + len(want)] != want:
            bad += 1
    ok('%s: all %d xref offsets land on their objects' % (name, count - 1), bad == 0)

    mo = re.search(r'/Type /Pages /Kids \[[^\]]*\] /Count (\d+)', P)
    declared = mo.group(1) if mo else None
    actual = len(re.findall(r'/Type /Page /Parent', P))
    ok('%s: page tree counts %s, file holds %d' % (name, declared or '', actual),
       declared not in (None, '', '0') and int(declared) == actual)

    lenbad = 0
    streams = ''
    for mo in re.finditer(r'<< /Length (\d+) >>\nstream\n', P):
        ln, at = int(mo.group(1)), mo.end()
        if P[at + ln:at + ln + 9] != 'endstream':
            lenbad += 1
        streams += P[at:at + ln]
    ok('%s: every stream /Length is exact' % name, lenbad == 0)

    # completeness: undo the PDF string escapes and look for every report line
    have = {}
    for mo in re.finditer(r'\(((?:[^\\()]|\\.)*)\) Tj', streams):
        s = re.sub(r'\\(.)', r'\1', mo.group(1))
        have[s] = have.get(s, 0) + 1
    # Rules are drawn, not typed; the supply graph's character drawing is
    # replaced by the drawn graph.  Neither is looked for as text.
    tl = perl_split_lines(T)
    gs_ = [i for i in range(len(tl)) if re.search(r'^ SUPPLY GRAPH', tl[i])]
    skip = {}
    for gs in gs_:
        ge = gs
        while ge < len(tl) - 1 and not re.search(r'O\s+operating point|D\s+combined duty', tl[ge]):
            ge += 1
        for i in range(gs + 1, ge + 1):
            skip[i] = 1

    def is_rule(s):
        mo = re.search(r'^\s*(=+|-+)\s*$', s)
        return mo is not None and len(mo.group(1)) >= 20
    missing = [tl[i] for i in range(len(tl)) if i not in skip]
    missing = [s for s in missing if re.search(r'\S', s) and not is_rule(s) and not have.get(s)]
    ok('%s: every text line present in the PDF (%d missing)' % (name, len(missing)), not missing)
    if missing:
        print('      e.g. [%s]' % missing[0])
    nrules = len([s for s in tl if is_rule(s)])
    drawn = len(re.findall(r'% PHCP-RULE', streams))
    ok('%s: every rule drawn as a line (%d in the text, %d drawn)' % (name, nrules, drawn),
       drawn >= nrules and nrules > 0)
    ok('%s: the typeface is embedded (DejaVu Sans Mono, regular and bold)' % name,
       '/BaseFont /DejaVuSansMono /' in P and '/BaseFont /DejaVuSansMono-Bold ' in P
       and '/FontFile2 ' in P)

    # The drawn graphs, each checked against the report's own figures by
    # hand: one for a single supply, with its demand point; one per supply
    # when several share the load, each with its operating point.
    if not gs_:
        continue
    plots = re.split(r'(?=% PHCP-GRAPH PLOT )', streams)
    # Perl's split makes no empty leading field from a zero-width match at
    # the very start; Python's does.  Drop it so the shift below is the same.
    if streams.startswith('% PHCP-GRAPH PLOT ') and plots and plots[0] == '':
        plots.pop(0)
    plots.pop(0)
    ok('%s: every supply graph is drawn (%d in the text, %d drawn)' % (name, len(gs_), len(plots)),
       len(plots) == len(gs_))
    oper = [x for t in re.findall(r'^ (\S+)\s+operating at\s+([\d.]+) \S+ and\s+([\d.]+)', T, re.M)
            for x in t]

    def at(lst, i):
        return lst[i] if 0 <= i < len(lst) else None

    for k in range(len(plots)):
        st = plots[k]
        gname = '%s graph %d' % (name, k + 1) if len(plots) > 1 else name
        mo = re.search(r'% PHCP-GRAPH PLOT (\S+) (\S+) (\S+) (\S+) (\S+) (\S+)', st)
        if not mo:
            continue
        pl, pb, pw, ph, qmax, pmax = [num(x) for x in mo.groups()]

        def X(q, pl=pl, qmax=qmax, pw=pw):
            return pl + (q / qmax) ** 1.85 * pw

        def Y(p, pb=pb, pmax=pmax, ph=ph):
            return pb + p / pmax * ph
        # Which graph this is: one supply; one of several (an operating point,
        # no demand point); or all of them combined (the combined duty, and an
        # operating point only when they run at one pressure).
        kind = 'single' if len(plots) == 1 else \
            'combined' if re.search(r'% PHCP-GRAPH PART ', st) else 'shared'
        mo = re.search(r'^\s+COMBINED DUTY\s+([\d.]+) \S+\s+at\s+([\d.]+)', T, re.M) \
            if kind == 'combined' else \
            re.search(r'^\s+DEMAND\s+([\d.]+) \S+\s+at\s+([\d.]+)', T, re.M)
        qd, pd = mo.groups() if mo else (None, None)
        mo = re.search(r'^\s+COMBINED OPERATING POINT\s+([\d.]+) \S+\s+at\s+([\d.]+)', T, re.M) \
            if kind == 'combined' else \
            re.search(r'^\s+OPERATING POINT\s+([\d.]+) \S+\s+at\s+([\d.]+)', T, re.M)
        qo, po = mo.groups() if mo else (None, None)
        if kind == 'shared':
            qo, po = at(oper, 3 * k + 1), at(oper, 3 * k + 2)
        mo = re.search(r'% PHCP-GRAPH D (\S+) (\S+)', st)
        dx, dy = mo.groups() if mo else (None, None)
        mo = re.search(r'% PHCP-GRAPH O (\S+) (\S+)', st)
        ox, oy = mo.groups() if mo else (None, None)

        # The report prints to 0.1, so a figure read from it is good to 0.05 of
        # its unit; on the page that is whatever 0.05 spans at that point of the
        # axis (more in bar than in kPa), plus rounding of the coordinates.
        def tx(q):
            return abs(X(q + 0.05) - X(q - 0.05 if q > 0.05 else 0)) / 2 + 0.01
        ty = 0.05 / pmax * ph + 0.01
        if kind != 'shared':
            ok('%s: D drawn at the %s, x = %.2f + %.2f (%.1f/%.1f)^1.85'
               % (gname, 'combined duty' if kind == 'combined' else 'demand point',
                  pl, pw, num(qd), qmax),
               dx is not None and abs(num(dx) - X(num(qd))) <= tx(num(qd))
               and abs(num(dy) - Y(num(pd))) <= ty)
        else:
            ok('%s: no demand point drawn for a supply that shares the load' % gname, dx is None)
        if kind == 'combined':
            parts = re.findall(r'% PHCP-GRAPH PART (\S+)', st)
            ids = [at(oper, 3 * i) or '' for i in range(len(plots) - 1)]
            ok("%s: each supply's own curve drawn under the combined one (%s)"
               % (gname, ' '.join(parts)), ' '.join(parts) == ' '.join(ids))
            if qo is None:
                ok('%s: no operating point drawn where the supplies run at different pressures'
                   % gname, ox is None)
        if qo is not None:
            ok('%s: O drawn at the operating point' % gname,
               ox is not None and abs(num(ox) - X(num(qo))) <= tx(num(qo))
               and abs(num(oy) - Y(num(po))) <= ty)
        xt = re.findall(r'% PHCP-GRAPH XTICK (\S+) (\S+)', st)
        tbad, prev = 0, None
        for t, x in xt:
            t, x = num(t), num(x)
            if abs(x - X(t)) > 0.01:
                tbad += 1
            if prev is not None and x - prev < 6:
                tbad += 1
            prev = x
        ok('%s: every flow label at (q/qmax)^1.85 along the axis, none overlapping' % gname,
           bool(xt) and not tbad)
        mo = re.search(r'% PHCP-GRAPH SUPPLY (\d+)', st)
        nsup = mo.group(1) if mo else None
        ok('%s: the supply drawn as a line of %s points' % (gname, nsup or ''),
           (int(nsup) if nsup is not None else 0) > 100)
        ok('%s: the graph clears the page footer' % gname, pb - 3 * 10.8 > 38)

# ------------------------------------------------------------------------
# As the Perl.  Each of these was a difference between the port and the Perl
# 1.6.0, found by reading the two side by side and by comparing the PDFs the
# two write byte for byte; what is asserted is what the Perl gives.  With
# them, a report PDF differs from the Perl's only in the creation date and
# the program's name and version (and the lengths and offsets that follow).
# ------------------------------------------------------------------------
sys.path.insert(0, ROOT)
import zlib                                  # noqa: E402
from hardycross import pdfout as P           # noqa: E402

tmpdir = tempfile.mkdtemp()
out = os.path.join(tmpdir, 'a.pdf')
P.write_pdf('A\n', out, title='T', job='0', revision='0', date='0', model='m.phc', program='X')
with open(out, 'rb') as fh:
    pdf = fh.read()
for face in ('DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf'):
    with open(os.path.join(P.font_dir(), face), 'rb') as fh:
        ttf = fh.read()
    # Compress::Zlib::compress: the default level, memLevel 9 (MAX_MEM_LEVEL)
    zc = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION, zlib.DEFLATED, zlib.MAX_WBITS, 9)
    z = zc.compress(ttf) + zc.flush()
    ok('as the Perl: %s is deflated as Compress::Zlib deflates it (memLevel 9), its /Length right' % face,
       (b'<< /Length %d /Length1 %d /Filter /FlateDecode >>\nstream\n' % (len(z), len(ttf))) + z + b'\nendstream' in pdf)
st = pdf.decode('latin-1')
ok("as the Perl: a job or revision of '0' is not printed in the header; a date of '0' is",
   'Job 0' not in st and 'Rev 0' not in st and re.search(r'^BT /F2 9 Tf [\d.]+ 566\.00 Td \(PHCP  HYDRAULIC CALCULATION +T +0\) Tj ET$', st, re.M))
fr = P.frame(1, 1, header='', title='', program='', job='J1', revision='B', model='0')
ok("as the Perl: a header, title or program given as '' is '', not the default; a model of '0' is none",
   re.search(r'Td \( {%d}Job J1   Rev B\) Tj ET' % (132 - len('Job J1   Rev B')), fr)
   and re.search(r'^BT /F1 8 Tf [\d.]+ 26\.00 Td \(\) Tj ET$', fr, re.M))
P.write_pdf('A\n', out, title='', designer='D', program='')
with open(out, 'rb') as fh:
    ok("as the Perl: a title of '' is '' in the document information",
       b'/Title () /Author (D) /Subject (Hydraulic calculation) /Creator () /Producer ()' in fh.read())
# the report is bytes to the Perl: only ASCII white space is white space
pg = P.paginate('\n'.join(['A', '\x1f', '\xa0', '=' * 20 + '\x1f', '-' * 25 + '\xa0', '\x1c' + '-' * 25, 'B']))
ok('as the Perl: a no-break space or a control character is not white space - no blank line, no rule',
   len(pg) == 1 and len(pg[0]) == 7
   and not [l for l in pg[0] if P.blank(l[0]) or P.is_thick(l[0]) or P.is_thin(l[0]) or P.is_sub(l[0])])
# a font file cut short: Courier, and the report still written
real_dir = P.font_dir
for cut in (0, 5, 12, 100):
    with open(os.path.join(tmpdir, 'DejaVuSansMono.ttf'), 'wb') as fh:
        with open(os.path.join(real_dir(), 'DejaVuSansMono.ttf'), 'rb') as src:
            fh.write(src.read()[:cut])
    P.font_dir = lambda: tmpdir
    try:
        n = P.write_pdf('A\n', out, title='T')
        with open(out, 'rb') as fh:
            b = fh.read()
        ok('as the Perl: a font file of %d bytes is no font - the report is written in Courier' % cut,
           n == 1 and b'/BaseFont /Courier ' in b and b'/BaseFont /Courier-Bold ' in b and b'FontFile2' not in b)
    except Exception as e:      # noqa: BLE001
        ok('as the Perl: a font file of %d bytes is no font - the report is written in Courier (%s)' % (cut, e), False)
    finally:
        P.font_dir = real_dir
P.fonts()
# a file that cannot be written reads as the Perl's die does
try:
    P.write_pdf('A\n', os.path.join(tmpdir, 'nonesuch', 'x.pdf'))
    ok('as the Perl: a PDF that cannot be written is refused', False)
except OSError as e:
    ok('as the Perl: a PDF that cannot be written says "cannot write PATH: reason"',
       str(e) == 'cannot write %s: %s\n' % (os.path.join(tmpdir, 'nonesuch', 'x.pdf'), e.strerror) and e.errno == 2)
import shutil                                # noqa: E402
shutil.rmtree(tmpdir, ignore_errors=True)

for t in tmpfiles:
    try:
        os.unlink(t)
    except OSError:
        pass
print('PDF report: %d checks across %d models, %d failed' % (checks, len(models), fails))
sys.exit(1 if fails else 0)
