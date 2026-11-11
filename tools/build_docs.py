"""Build the user guide and the reference manual as Word and PDF documents.

    python tools/build_docs.py                 both documents, .docx and .pdf
    python tools/build_docs.py --no-pdf        the .docx only
    python tools/build_docs.py --release       in a release commit: the version
                                               alone, as the tag will name it

The text is written once, in Markdown: docs/USER_GUIDE.md and
docs/PHC_REFERENCE.md.  Those stay the source because tools/test_manual.pl
checks the reference manual against the program line by line, and a binary
document cannot be checked or reviewed in a diff.  This script turns each into
a formatted A4 document:

    docs/PHCP_User_Guide.docx        docs/PHCP_User_Guide.pdf
    docs/PHCP_Reference_Manual.docx  docs/PHCP_Reference_Manual.pdf

with a title page (the program version and the date), a table of contents,
headings, tables, code in a fixed-pitch face, the user guide's screenshots
from docs/images/, and page numbers.

The .docx is written with python-docx.  The PDF, and the table of contents's
page numbers, come from Microsoft Word through COM on Windows (pywin32), or
from LibreOffice (soffice) elsewhere.  With neither, the .docx is written and
the PDF is skipped with a message; the contents fill in when the .docx is
first opened in Word.

Only the Markdown the two documents use is understood: # to #### headings,
paragraphs, **bold**, `code`, [links](...), - and 1. lists, | tables |,
``` code blocks, ![pictures](...) on a line of their own, and --- rules.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import shutil
import subprocess
import sys
from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
BLUE = RGBColor(0x1A, 0x5F, 0xD0)       # the windows' one blue
INK = RGBColor(0x1C, 0x1F, 0x24)        # the windows' ink
MUTED = RGBColor(0x5A, 0x63, 0x70)
BODY_FONT = "Arial"
CODE_FONT = "Consolas"
RELEASE = False                         # --release: see version()

DOCUMENTS = [
    ("USER_GUIDE.md", "PHCP_User_Guide", "PHCP User Guide",
     "The windows, a first calculation, and how to read the result"),
    ("PHC_REFERENCE.md", "PHCP_Reference_Manual", "PHCP Reference Manual",
     "The .phc model language, command by command"),
]


def version() -> str:
    """The program version, as HardyCross.pm states it; with the commit when
    the checkout is not exactly a release tag, so a document built from main
    between releases does not claim to describe the release.  --release drops
    the commit: the release commit is built before its tag exists."""
    m = re.search(r"\$VERSION\s*=\s*'([^']+)'", (ROOT / "HardyCross.pm").read_text(encoding="utf-8"))
    v = m.group(1) if m else "unknown"
    if RELEASE:
        return v
    try:
        d = subprocess.run(["git", "describe", "--tags", "--always"], cwd=ROOT, capture_output=True,
                           text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return v
    return v if d == f"v{v}" else f"{v}+ ({d})"


def fix_fonts(style, font: str):
    """Set a style's face for every script, and drop the theme fonts that
    Word would otherwise use in place of it (the headings' Calibri Light)."""
    rpr = style.element.get_or_add_rPr()
    rf = rpr.get_or_add_rFonts()
    for k in ("asciiTheme", "hAnsiTheme", "eastAsiaTheme", "cstheme"):
        rf.attrib.pop(qn(f"w:{k}"), None)
    for k in ("ascii", "hAnsi", "eastAsia", "cs"):
        rf.set(qn(f"w:{k}"), font)


#------------------------------------------------------------------------------
# Low-level Word XML: fields, shading, borders.  python-docx has no API for
# these, so the elements are made directly.
#------------------------------------------------------------------------------
def add_field(paragraph, instr: str, placeholder: str = ""):
    """A Word field (PAGE, NUMPAGES, TOC ...) in a paragraph."""
    run = paragraph.add_run()
    begin = OxmlElement("w:fldChar")
    begin.set(qn("w:fldCharType"), "begin")
    begin.set(qn("w:dirty"), "true")          # Word recomputes it on open
    run._r.append(begin)
    run = paragraph.add_run()
    text = OxmlElement("w:instrText")
    text.set(qn("xml:space"), "preserve")
    text.text = f" {instr} "
    run._r.append(text)
    run = paragraph.add_run()
    sep = OxmlElement("w:fldChar")
    sep.set(qn("w:fldCharType"), "separate")
    run._r.append(sep)
    paragraph.add_run(placeholder)
    run = paragraph.add_run()
    end = OxmlElement("w:fldChar")
    end.set(qn("w:fldCharType"), "end")
    run._r.append(end)


def shade(element, fill: str):
    """Background shading on a paragraph or table cell (ShadingType clear)."""
    pr = element.get_or_add_pPr() if hasattr(element, "get_or_add_pPr") else element.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    pr.append(shd)


def bottom_rule(paragraph, color: str = "C9CED6", size: int = 6):
    """A horizontal rule: the paragraph's bottom border."""
    ppr = paragraph._p.get_or_add_pPr()
    bdr = OxmlElement("w:pBdr")
    b = OxmlElement("w:bottom")
    b.set(qn("w:val"), "single")
    b.set(qn("w:sz"), str(size))
    b.set(qn("w:space"), "1")
    b.set(qn("w:color"), color)
    bdr.append(b)
    ppr.append(bdr)


def repeat_header(row):
    """A table's first row repeated at the top of each page it runs onto."""
    trpr = row._tr.get_or_add_trPr()
    h = OxmlElement("w:tblHeader")
    h.set(qn("w:val"), "true")
    trpr.append(h)


def no_split(row):
    trpr = row._tr.get_or_add_trPr()
    c = OxmlElement("w:cantSplit")
    c.set(qn("w:val"), "true")
    trpr.append(c)


#------------------------------------------------------------------------------
# Styles.
#------------------------------------------------------------------------------
def setup_styles(doc: Document):
    st = doc.styles
    normal = st["Normal"]
    fix_fonts(normal, BODY_FONT)
    normal.font.size = Pt(10)
    normal.font.color.rgb = INK
    normal.paragraph_format.space_after = Pt(6)
    normal.paragraph_format.line_spacing = 1.15
    for lvl, size, before in ((1, 18, 18), (2, 14, 14), (3, 12, 10), (4, 10.5, 8)):
        s = st[f"Heading {lvl}"]
        fix_fonts(s, BODY_FONT)
        s.font.size = Pt(size)
        s.font.bold = True
        s.font.italic = False
        s.font.color.rgb = BLUE if lvl <= 2 else INK
        s.paragraph_format.space_before = Pt(before)
        s.paragraph_format.space_after = Pt(6)
        s.paragraph_format.keep_with_next = True
    title = st["Title"]
    fix_fonts(title, BODY_FONT)
    title.font.size = Pt(30)
    title.font.bold = True
    title.font.color.rgb = BLUE
    # code: a paragraph style of its own, so Word keeps it apart from body text
    if "PHCP Code" not in [s.name for s in st]:
        code = st.add_style("PHCP Code", 1)
        code.base_style = normal
        code.font.name = CODE_FONT
        code.element.get_or_add_rPr().get_or_add_rFonts().set(qn("w:eastAsia"), CODE_FONT)
        code.font.size = Pt(8.5)
        code.paragraph_format.space_after = Pt(0)
        code.paragraph_format.line_spacing = 1.0
        code.paragraph_format.left_indent = Cm(0.3)
        code.paragraph_format.keep_with_next = True


#------------------------------------------------------------------------------
# Inline text: **bold**, `code`, [link](target), *italic*.
#------------------------------------------------------------------------------
INLINE = re.compile(r"(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\)|\*[^*\s][^*]*\*)")


def add_inline(paragraph, text: str, bold: bool = False, size: float | None = None):
    for part in INLINE.split(text):
        if not part:
            continue
        b, code, italic = bold, False, False
        if part.startswith("**") and part.endswith("**"):
            part, b = part[2:-2], True
        elif part.startswith("`") and part.endswith("`"):
            part, code = part[1:-1], True
        elif part.startswith("[") and "](" in part:
            # the link's text; a link to another file or an anchor means
            # nothing in a printed document, so the target is dropped
            part = part[1:part.index("](")]
        elif part.startswith("*") and part.endswith("*") and len(part) > 2:
            part, italic = part[1:-1], True
        r = paragraph.add_run(part)
        r.bold = b
        r.italic = italic
        if code:
            r.font.name = CODE_FONT
            r._element.get_or_add_rPr().get_or_add_rFonts().set(qn("w:eastAsia"), CODE_FONT)
            r.font.size = Pt((size or 10) - 1)
            r.font.color.rgb = RGBColor(0x14, 0x3E, 0x8C)
        elif size:
            r.font.size = Pt(size)


#------------------------------------------------------------------------------
# The Markdown, block by block.
#------------------------------------------------------------------------------
def table_rows(lines):
    rows = []
    for ln in lines:
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
            continue                      # the |---|---| line
        rows.append(cells)
    return rows


def add_table(doc, lines, width_cm: float):
    rows = table_rows(lines)
    if not rows:
        return
    n = max(len(r) for r in rows)
    t = doc.add_table(rows=len(rows), cols=n)
    t.style = "Table Grid"
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    # widths: by the longest text in each column, within limits, scaled to
    # the page; Word refines them (autofit) when it makes the PDF
    longest = [max(len(r[i]) if i < len(r) else 0 for r in rows) for i in range(n)]
    weights = [min(max(x, 6), 60) for x in longest]
    total = sum(weights)
    widths = [Cm(width_cm * w / total) for w in weights]
    for ri, r in enumerate(rows):
        row = t.rows[ri]
        no_split(row)
        for ci in range(n):
            cell = row.cells[ci]
            cell.width = widths[ci]
            p = cell.paragraphs[0]
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = 1.0
            add_inline(p, r[ci] if ci < len(r) else "", bold=(ri == 0), size=8.5)
            if ri == 0:
                shade(cell._tc, "E8EDF5")
    repeat_header(t.rows[0])
    doc.add_paragraph().paragraph_format.space_after = Pt(2)


def add_code(doc, lines):
    for i, ln in enumerate(lines or [""]):
        p = doc.add_paragraph(style="PHCP Code")
        shade(p._p, "F3F5F8")
        r = p.add_run(ln.rstrip() if ln.strip() else " ")
        if i == len(lines) - 1:
            p.paragraph_format.keep_with_next = False
            p.paragraph_format.space_after = Pt(8)


def add_picture(doc, src: str, alt: str, base: Path, width_cm: float):
    path = (base / src).resolve()
    if not path.is_file():
        raise SystemExit(f"build_docs: picture not found: {src}")
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.keep_with_next = True
    p.add_run().add_picture(str(path), width=Cm(width_cm))
    cap = doc.add_paragraph()
    cap.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = cap.add_run(alt)
    r.italic = True
    r.font.size = Pt(8.5)
    r.font.color.rgb = MUTED


def is_contents(text: str) -> bool:
    return text.strip().strip("#").strip().lower() == "contents"


def convert(md: str, doc: Document, base: Path, width_cm: float):
    lines = md.splitlines()
    i = 0
    first_h1 = True
    para: list[str] = []

    def flush():
        if para:
            p = doc.add_paragraph()
            add_inline(p, " ".join(s.strip() for s in para))
            para.clear()

    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        # the Markdown's own contents list is replaced by Word's table of
        # contents, on the page after the title
        if is_contents(s):
            flush()
            i += 1
            while i < len(lines) and (not lines[i].strip() or re.match(r"\s*(\d+\.|-)\s", lines[i])):
                i += 1
            continue
        if s.startswith("```"):
            flush()
            j = i + 1
            while j < len(lines) and not lines[j].strip().startswith("```"):
                j += 1
            add_code(doc, lines[i + 1:j])
            i = j + 1
            continue
        m = re.match(r"^(#{1,4})\s+(.*)", s)
        if m:
            flush()
            level = len(m.group(1))
            if level == 1 and first_h1:
                first_h1 = False      # the title page holds the document's title
            else:
                h = doc.add_heading(level=min(level, 4))
                add_inline(h, m.group(2))
                if level == 2:
                    bottom_rule(h, "1A5FD0", 4)
            i += 1
            continue
        if s == "---":
            flush()
            i += 1
            continue
        if s.startswith("|"):
            flush()
            j = i
            while j < len(lines) and lines[j].strip().startswith("|"):
                j += 1
            add_table(doc, lines[i:j], width_cm)
            i = j
            continue
        m = re.match(r"^!\[([^\]]*)\]\(([^)]+)\)$", s)
        if m:
            flush()
            add_picture(doc, m.group(2), m.group(1), base, width_cm)
            i += 1
            continue
        m = re.match(r"^(\s*)(-|\d+\.)\s+(.*)", ln)
        if m:
            flush()
            # a list item and the lines that continue it
            item = [m.group(3)]
            j = i + 1
            while j < len(lines) and lines[j].strip() and not re.match(r"^\s*(-|\d+\.)\s", lines[j]) \
                    and not lines[j].strip().startswith(("|", "```", "#", "![")):
                item.append(lines[j].strip())
                j += 1
            style = "List Bullet" if m.group(2) == "-" else "List Number"
            if len(m.group(1)) >= 2:
                style += " 2"
            p = doc.add_paragraph(style=style)
            p.paragraph_format.space_after = Pt(3)
            add_inline(p, " ".join(item))
            i = j
            continue
        if not s:
            flush()
            i += 1
            continue
        para.append(ln)
        i += 1
    flush()


#------------------------------------------------------------------------------
# One document.
#------------------------------------------------------------------------------
def build(src: Path, out: Path, title: str, subtitle: str):
    doc = Document()
    setup_styles(doc)
    sec = doc.sections[0]
    sec.page_height, sec.page_width = Cm(29.7), Cm(21.0)     # A4
    for side in ("left_margin", "right_margin"):
        setattr(sec, side, Cm(2.0))
    sec.top_margin, sec.bottom_margin = Cm(2.0), Cm(2.0)
    width = 21.0 - 4.0

    # the title page
    for _ in range(6):
        doc.add_paragraph()
    p = doc.add_paragraph(style="Title")
    p.add_run(title)
    bottom_rule(p, "1A5FD0", 12)
    p = doc.add_paragraph()
    r = p.add_run(subtitle)
    r.font.size = Pt(14)
    r.font.color.rgb = MUTED
    for _ in range(3):
        doc.add_paragraph()
    for text in (f"PHCP {version()}  -  Perl Hydraulic Calculation Program",
                 f"Built {dt.date.today():%d %B %Y} from {src.relative_to(ROOT).as_posix()}",
                 "Copyright (c) 2026 Hycadia Pty Ltd"):
        p = doc.add_paragraph()
        r = p.add_run(text)
        r.font.size = Pt(10)
        r.font.color.rgb = MUTED
    doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)

    # the contents, filled in by Word
    h = doc.add_paragraph()
    r = h.add_run("Contents")
    r.bold = True
    r.font.size = Pt(18)
    r.font.color.rgb = BLUE
    add_field(doc.add_paragraph(), 'TOC \\o "1-2" \\h \\z \\u',
              "The contents fill in when Word updates the fields (F9).")
    doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)

    convert(src.read_text(encoding="utf-8"), doc, src.parent, width)

    # the footer: the title, and the page of the pages
    for s in doc.sections:
        fp = s.footer.paragraphs[0]
        fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r = fp.add_run(f"{title}  -  PHCP {version()}  -  page ")
        r.font.size = Pt(8)
        r.font.color.rgb = MUTED
        add_field(fp, "PAGE", "1")
        r = fp.add_run(" of ")
        r.font.size = Pt(8)
        r.font.color.rgb = MUTED
        add_field(fp, "NUMPAGES", "1")
    doc.save(out)


#------------------------------------------------------------------------------
# The PDF: Word through COM, or LibreOffice.
#------------------------------------------------------------------------------
def pdf_word(docx: Path, pdf: Path) -> bool:
    try:
        import win32com.client  # type: ignore
    except ImportError:
        return False
    word = win32com.client.DispatchEx("Word.Application")
    word.Visible = False
    word.DisplayAlerts = 0
    try:
        d = word.Documents.Open(str(docx))
        for t in d.Tables:
            t.AutoFitBehavior(2)          # wdAutoFitWindow: the page's width
        d.Fields.Update()
        for toc in d.TablesOfContents:
            toc.Update()
        d.Fields.Update()                 # NUMPAGES after the contents grew
        d.Save()                          # the .docx keeps its filled contents
        d.ExportAsFixedFormat(str(pdf), 17)   # wdExportFormatPDF
        d.Close(False)
    finally:
        word.Quit()
    return True


def pdf_soffice(docx: Path, pdf: Path) -> bool:
    exe = shutil.which("soffice") or shutil.which("libreoffice")
    if not exe:
        return False
    subprocess.run([exe, "--headless", "--convert-to", "pdf", "--outdir", str(pdf.parent), str(docx)],
                   check=True, capture_output=True)
    return pdf.is_file()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-pdf", action="store_true")
    ap.add_argument("--release", action="store_true")
    a = ap.parse_args()
    global RELEASE
    RELEASE = a.release
    for src, stem, title, subtitle in DOCUMENTS:
        docx = DOCS / f"{stem}.docx"
        pdf = DOCS / f"{stem}.pdf"
        build(DOCS / src, docx, title, subtitle)
        print(f"wrote {docx.relative_to(ROOT)}")
        if a.no_pdf:
            continue
        if sys.platform == "win32" and pdf_word(docx, pdf) or pdf_soffice(docx, pdf):
            print(f"wrote {pdf.relative_to(ROOT)}")
        else:
            print(f"no PDF for {stem}: needs Microsoft Word (pywin32) or LibreOffice")
    return 0


if __name__ == "__main__":
    sys.exit(main())
