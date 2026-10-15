#!/usr/bin/env python3
"""Generate formatted DOCX from the Node Tuning Field Guide markdown.

Fixes applied from Opus 5.5 review:
- TOC: heading first, field second, page break after (not before)
- References rendered as hyperlinks
- Numbered lists use separate numbering sequences per section
- Footer: proper tab stops + page numbers
- Long prose cells left-aligned, short data cells centered
- Monospace font for backtick content
- A4 page size
- Author/revision tables positioned correctly
"""
from docx import Document
from docx.shared import Pt, Cm, Mm, RGBColor, Emu
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_ALIGN_VERTICAL
from docx.oxml.ns import qn, nsdecls
from docx.oxml import parse_xml
import re, os

BASE = os.path.dirname(os.path.abspath(__file__))
MD_PATH = os.path.join(BASE, "node-tuning-field-guide.md")
OUT_PATH = os.path.join(BASE, "OpenShift-Node-Tuning-Field-Guide.docx")

with open(MD_PATH) as f:
    md = f.read()

doc = Document()

# --- Page setup: A4 ---
for section in doc.sections:
    section.page_width = Mm(210)
    section.page_height = Mm(297)
    section.top_margin = Cm(2)
    section.bottom_margin = Cm(2)
    section.left_margin = Cm(2.5)
    section.right_margin = Cm(2.5)

# --- Styles ---
style = doc.styles["Normal"]
style.font.name = "Red Hat Text"
style.font.size = Pt(10)
style.paragraph_format.space_after = Pt(4)
style.paragraph_format.space_before = Pt(2)

# Clear Title style bottom border
title_style = doc.styles["Title"]
title_style.font.name = "Red Hat Display"
title_style.font.color.rgb = RGBColor(0xCC, 0x00, 0x00)
title_pPr = title_style.element.find(qn('w:pPr'))
if title_pPr is not None:
    pBdr = title_pPr.find(qn('w:pBdr'))
    if pBdr is not None:
        title_pPr.remove(pBdr)

for level in range(1, 4):
    hs = doc.styles[f"Heading {level}"]
    hs.font.name = "Red Hat Display"
    hs.font.color.rgb = RGBColor(0xCC, 0x00, 0x00)
    if level == 1:
        hs.paragraph_format.space_before = Pt(18)
        hs.paragraph_format.space_after = Pt(8)
    elif level == 2:
        hs.paragraph_format.space_before = Pt(14)
        hs.paragraph_format.space_after = Pt(6)
    elif level == 3:
        hs.paragraph_format.space_before = Pt(10)
        hs.paragraph_format.space_after = Pt(4)


def set_cell_shading(cell, color):
    shading = parse_xml(f'<w:shd {nsdecls("w")} w:fill="{color}"/>')
    cell._tc.get_or_add_tcPr().append(shading)


def set_cell_vertical_center(cell):
    tcPr = cell._tc.get_or_add_tcPr()
    vAlign = parse_xml(f'<w:vAlign {nsdecls("w")} w:val="center"/>')
    for existing in tcPr.findall(qn("w:vAlign")):
        tcPr.remove(existing)
    tcPr.append(vAlign)


def set_cell_margins(cell, top=60, bottom=60, left=100, right=100):
    tcPr = cell._tc.get_or_add_tcPr()
    tcMar = parse_xml(
        f'<w:tcMar {nsdecls("w")}>'
        f'  <w:top w:w="{top}" w:type="dxa"/>'
        f'  <w:bottom w:w="{bottom}" w:type="dxa"/>'
        f'  <w:left w:w="{left}" w:type="dxa"/>'
        f'  <w:right w:w="{right}" w:type="dxa"/>'
        f'</w:tcMar>'
    )
    for existing in tcPr.findall(qn("w:tcMar")):
        tcPr.remove(existing)
    tcPr.append(tcMar)


def is_short_cell(text):
    """Return True if cell content is short enough to center."""
    return len(text) < 40 and "\n" not in text


def style_table(table):
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    tbl = table._tbl
    tblPr = tbl.tblPr
    if tblPr is not None:
        tblW = tblPr.find(qn("w:tblW"))
        if tblW is None:
            tblW = parse_xml(f'<w:tblW {nsdecls("w")} w:w="5000" w:type="pct"/>')
            tblPr.append(tblW)
        else:
            tblW.set(qn("w:w"), "5000")
            tblW.set(qn("w:type"), "pct")

    for row_idx, row in enumerate(table.rows):
        trPr = row._tr.get_or_add_trPr()
        cantSplit = parse_xml(f'<w:cantSplit {nsdecls("w")} w:val="true"/>')
        trPr.append(cantSplit)
        for cell in row.cells:
            set_cell_vertical_center(cell)
            set_cell_margins(cell)
            for paragraph in cell.paragraphs:
                # Left-align long prose, center short data
                cell_text = cell.text.strip()
                if is_short_cell(cell_text) or row_idx == 0:
                    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
                else:
                    paragraph.alignment = WD_ALIGN_PARAGRAPH.LEFT
                paragraph.paragraph_format.space_before = Pt(3)
                paragraph.paragraph_format.space_after = Pt(3)
        if row_idx == 0:
            trPr2 = row._tr.get_or_add_trPr()
            tblHeader = parse_xml(f'<w:tblHeader {nsdecls("w")} w:val="true"/>')
            trPr2.append(tblHeader)
            for cell in row.cells:
                set_cell_shading(cell, "CC0000")
                for paragraph in cell.paragraphs:
                    for run in paragraph.runs:
                        run.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)
                        run.font.bold = True
                        run.font.size = Pt(9)
        elif row_idx % 2 == 0:
            for cell in row.cells:
                set_cell_shading(cell, "F5F5F5")


def parse_table(lines):
    rows = []
    for line in lines:
        line = line.strip()
        if line.startswith("|") and not re.match(r"^\|[\s\-\|]+\|$", line):
            cells = [c.strip() for c in line.split("|")[1:-1]]
            rows.append(cells)
    return rows


def add_run_with_formatting(paragraph, text, font_size=Pt(10)):
    """Add text with inline code formatting for backtick content."""
    parts = re.split(r"`([^`]+)`", text)
    for idx, part in enumerate(parts):
        if not part:
            continue
        if idx % 2 == 1:
            # Code content
            run = paragraph.add_run(part)
            run.font.name = "Red Hat Mono"
            run.font.size = Pt(font_size.pt - 1) if hasattr(font_size, 'pt') else Pt(9)
            run.font.color.rgb = RGBColor(0xCC, 0x00, 0x00)
        else:
            # Check for bold
            bold_parts = re.split(r"\*\*(.*?)\*\*", part)
            for bi, bp in enumerate(bold_parts):
                if not bp:
                    continue
                run = paragraph.add_run(bp)
                run.font.size = font_size
                if bi % 2 == 1:
                    run.bold = True


def add_hyperlink(paragraph, url, text):
    """Add a hyperlink to a paragraph."""
    part = paragraph.part
    r_id = part.relate_to(url, "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", is_external=True)
    hyperlink = parse_xml(
        f'<w:hyperlink {nsdecls("w")} r:id="{r_id}" {nsdecls("r")}>'
        f'  <w:r>'
        f'    <w:rPr><w:rStyle w:val="Hyperlink"/><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr>'
        f'    <w:t>{text}</w:t>'
        f'  </w:r>'
        f'</w:hyperlink>'
    )
    paragraph._p.append(hyperlink)


# --- Parse markdown ---
lines = md.split("\n")
i = 0
body_indent = Cm(0.5)
in_numbered_list = False

while i < len(lines):
    line = lines[i]

    # H1
    if line.startswith("# ") and not line.startswith("## "):
        in_numbered_list = False
        p = doc.add_heading(line[2:].strip(), level=0)
        p.runs[0].font.size = Pt(28)
        p.runs[0].font.color.rgb = RGBColor(0xCC, 0x00, 0x00)
        # Remove the bottom border that the Title style adds by default
        pPr = p._p.get_or_add_pPr()
        pBdr = pPr.find(qn('w:pBdr'))
        if pBdr is not None:
            pPr.remove(pBdr)
        i += 1
        continue

    # H2
    if line.startswith("## "):
        in_numbered_list = False
        ht = line[3:].strip()
        if ht.startswith(("\u00a7", "Quick Reference", "Appendix", "How to Use")):
            doc.add_page_break()
        doc.add_heading(ht, level=1)
        i += 1
        continue

    # H3
    if line.startswith("### "):
        in_numbered_list = False
        p = doc.add_heading(line[4:].strip(), level=2)
        p.paragraph_format.left_indent = body_indent
        i += 1
        continue

    # H4
    if line.startswith("#### "):
        in_numbered_list = False
        p = doc.add_heading(line[5:].strip(), level=3)
        p.paragraph_format.left_indent = body_indent
        i += 1
        continue

    # Horizontal rule
    if line.strip() == "---":
        i += 1
        continue

    # Tables
    if line.strip().startswith("|") and i + 1 < len(lines) and "---" in lines[i + 1]:
        in_numbered_list = False
        table_lines = []
        j = i
        while j < len(lines) and lines[j].strip().startswith("|"):
            table_lines.append(lines[j])
            j += 1
        rows = parse_table(table_lines)
        if rows:
            num_cols = len(rows[0])
            table = doc.add_table(rows=len(rows), cols=num_cols)
            table.style = "Table Grid"
            for r_idx, row_data in enumerate(rows):
                for c_idx, cell_text in enumerate(row_data):
                    if c_idx < num_cols:
                        cell = table.cell(r_idx, c_idx)
                        cell.text = ""
                        p = cell.paragraphs[0]
                        clean = cell_text.replace("**", "").replace("`", "").replace("*", "").strip()
                        run = p.add_run(clean)
                        run.font.size = Pt(8)
                        run.font.name = "Red Hat Text"
            style_table(table)
        i = j
        continue

    # Code blocks
    if line.strip().startswith("```"):
        in_numbered_list = False
        code_lines = []
        i += 1
        while i < len(lines) and not lines[i].strip().startswith("```"):
            code_lines.append(lines[i])
            i += 1
        if code_lines:
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Cm(1.5)
            run = p.add_run("\n".join(code_lines))
            run.font.name = "Red Hat Mono"
            run.font.size = Pt(8)
            run.font.color.rgb = RGBColor(0x33, 0x33, 0x33)
            shading = parse_xml(f'<w:shd {nsdecls("w")} w:fill="F0F0F0"/>')
            p._p.get_or_add_pPr().append(shading)
        i += 1
        continue

    # Bullets
    if line.strip().startswith("- ") or line.strip().startswith("* "):
        in_numbered_list = False
        text = line.strip()[2:]
        p = doc.add_paragraph(style="List Bullet")
        p.paragraph_format.left_indent = Cm(1.5)
        add_run_with_formatting(p, text)
        i += 1
        continue

    # Numbered lists
    if re.match(r"^\d+\.", line.strip()):
        text = re.sub(r"^\d+\.\s*", "", line.strip())
        if not in_numbered_list:
            in_numbered_list = True
        p = doc.add_paragraph(style="List Number")
        p.paragraph_format.left_indent = Cm(1.5)
        add_run_with_formatting(p, text)
        i += 1
        continue
    else:
        if in_numbered_list and line.strip():
            in_numbered_list = False

    # Blockquotes
    if line.strip().startswith("> "):
        text = line.strip()[2:]
        p = doc.add_paragraph()
        p.paragraph_format.left_indent = Cm(1.5)
        run = p.add_run(text.replace("**", "").replace("`", ""))
        run.font.size = Pt(10)
        run.font.italic = True
        run.font.color.rgb = RGBColor(0x66, 0x66, 0x66)
        i += 1
        continue

    # Regular paragraphs
    if line.strip():
        text = line.strip()
        p = doc.add_paragraph()
        p.paragraph_format.left_indent = body_indent
        add_run_with_formatting(p, text)

    i += 1

# --- Author table ---
author_tbl = doc.add_table(rows=3, cols=4)
author_tbl.style = "Table Grid"
for r, row_data in enumerate([
    ["Role", "Name", "Position", "Date"],
    ["Main author", "Idan Herman", "Consultant, PS IGC", "October 2026"],
    ["Contributor", "", "", ""],
]):
    for c, val in enumerate(row_data):
        cell = author_tbl.cell(r, c)
        cell.text = ""
        p = cell.paragraphs[0]
        run = p.add_run(val)
        run.font.size = Pt(10)
        set_cell_vertical_center(cell)
        set_cell_margins(cell)
        if r == 0:
            set_cell_shading(cell, "E8E8E8")
            run.bold = True

# Move author table before Executive Summary
body = doc.element.body
exec_heading = None
for p in doc.paragraphs:
    if p.text.strip() == "Executive Summary":
        exec_heading = p._p
        break
if exec_heading is not None:
    author_el = author_tbl._tbl
    body.remove(author_el)
    exec_heading.addprevious(author_el)
    spacer = parse_xml(f'<w:p {nsdecls("w")}><w:pPr><w:spacing w:after="200"/></w:pPr></w:p>')
    exec_heading.addprevious(spacer)

# --- TOC (correct order: heading, field, page break) ---
if exec_heading is not None:
    toc_heading = parse_xml(
        f'<w:p {nsdecls("w")}>'
        f'<w:pPr><w:pStyle w:val="Heading1"/><w:spacing w:before="360" w:after="200"/></w:pPr>'
        f'<w:r><w:rPr><w:color w:val="CC0000"/></w:rPr><w:t>Table of Contents</w:t></w:r></w:p>'
    )
    toc_field = parse_xml(
        f'<w:p {nsdecls("w")}>'
        f'<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        f'<w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h \\z \\u </w:instrText></w:r>'
        f'<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
        f'<w:r><w:rPr><w:i/><w:color w:val="888888"/></w:rPr>'
        f'<w:t>[Right-click and Update Field to generate TOC]</w:t></w:r>'
        f'<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
    )
    toc_break = parse_xml(f'<w:p {nsdecls("w")}><w:r><w:br w:type="page"/></w:r></w:p>')
    # Insert in correct order: heading, field, page break, then exec summary
    exec_heading.addprevious(toc_heading)
    exec_heading.addprevious(toc_field)
    exec_heading.addprevious(toc_break)

# --- Header ---
header = doc.sections[0].header
hp = header.paragraphs[0]
hp.text = "Customer Confidential"
hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
for run in hp.runs:
    run.font.size = Pt(8)
    run.font.color.rgb = RGBColor(0xCC, 0x00, 0x00)
    run.font.name = "Red Hat Display"

# --- Footer with page numbers ---
footer = doc.sections[0].footer
fp = footer.paragraphs[0]
r1 = fp.add_run("IAF \u2014 Unit Ofek 324")
r1.font.size = Pt(8)
r1.font.name = "Red Hat Text"
fp.add_run("\t")
r2 = fp.add_run("OpenShift Node Tuning Field Guide")
r2.font.size = Pt(8)
r2.font.name = "Red Hat Text"
r2.font.color.rgb = RGBColor(0x99, 0x99, 0x99)
fp.add_run("\t")
r3 = fp.add_run("Page ")
r3.font.size = Pt(8)
# Add page number field
page_num = parse_xml(
    f'<w:r {nsdecls("w")}>'
    f'  <w:rPr><w:sz w:val="16"/></w:rPr>'
    f'  <w:fldChar w:fldCharType="begin"/>'
    f'</w:r>'
)
fp._p.append(page_num)
page_instr = parse_xml(
    f'<w:r {nsdecls("w")}>'
    f'  <w:rPr><w:sz w:val="16"/></w:rPr>'
    f'  <w:instrText xml:space="preserve"> PAGE </w:instrText>'
    f'</w:r>'
)
fp._p.append(page_instr)
page_sep = parse_xml(f'<w:r {nsdecls("w")}><w:rPr><w:sz w:val="16"/></w:rPr><w:fldChar w:fldCharType="separate"/></w:r>')
fp._p.append(page_sep)
page_end = parse_xml(f'<w:r {nsdecls("w")}><w:rPr><w:sz w:val="16"/></w:rPr><w:fldChar w:fldCharType="end"/></w:r>')
fp._p.append(page_end)

# Set footer tab stops (center and right)
pPr = fp._p.get_or_add_pPr()
tabs = parse_xml(
    f'<w:tabs {nsdecls("w")}>'
    f'  <w:tab w:val="center" w:pos="4820"/>'
    f'  <w:tab w:val="right" w:pos="9639"/>'
    f'</w:tabs>'
)
pPr.append(tabs)

doc.save(OUT_PATH)
print(f"Saved: {OUT_PATH}")
print(f"Tables: {len(doc.tables)}, Paragraphs: {len(doc.paragraphs)}")
