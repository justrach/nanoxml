#!/usr/bin/env python3
"""Generate synthetic OOXML benchmark corpora (stdlib only).

  python3 tools/gen_corpus.py xlsx corpus/big.xlsx 200000
  python3 tools/gen_corpus.py docx corpus/big.docx 50000
  python3 tools/gen_corpus.py pptx corpus/big.pptx 500
"""
import sys
import zipfile

REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
CT_NS = "http://schemas.openxmlformats.org/package/2006/content-types"


def content_types(overrides, defaults=()):
    parts = [f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="{CT_NS}">']
    parts.append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
    parts.append('<Default Extension="xml" ContentType="application/xml"/>')
    for ext, ct in defaults:
        parts.append(f'<Default Extension="{ext}" ContentType="{ct}"/>')
    for name, ct in overrides:
        parts.append(f'<Override PartName="{name}" ContentType="{ct}"/>')
    parts.append("</Types>")
    return "".join(parts)


def root_rels(target):
    return (
        f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="{PKG_REL_NS}">'
        f'<Relationship Id="rId1" Type="{REL_NS}/officeDocument" Target="{target}"/></Relationships>'
    )


def write_zip(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for name, data in files:
            z.writestr(name, data)


def gen_xlsx(path, rows):
    n_shared = 1000
    shared = [f"Vendor {i} &amp; Sons, “dept {i % 37}”" for i in range(n_shared)]
    sst = [f'<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{rows}" uniqueCount="{n_shared}">']
    sst += [f"<si><t>{s}</t></si>" for s in shared]
    sst.append("</sst>")

    sheet = ['<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>']
    for r in range(1, rows + 1):
        sid = (r * 7919) % n_shared
        sheet.append(
            f'<row r="{r}">'
            f'<c r="A{r}" t="s"><v>{sid}</v></c>'
            f'<c r="B{r}"><v>{r}</v></c>'
            f'<c r="C{r}"><v>{r * 0.125}</v></c>'
            f'<c r="D{r}" t="b"><v>{r % 2}</v></c>'
            f'<c r="E{r}" t="inlineStr"><is><t>note {r}</t></is></c>'
            f'<c r="F{r}"><v>{r * r % 99991}</v></c>'
            "</row>"
        )
    sheet.append("</sheetData></worksheet>")

    wb = (
        '<?xml version="1.0"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        f'xmlns:r="{REL_NS}"><sheets>'
        '<sheet name="Data" sheetId="1" r:id="rId1"/>'
        "</sheets></workbook>"
    )
    wb_rels = (
        f'<?xml version="1.0"?><Relationships xmlns="{PKG_REL_NS}">'
        f'<Relationship Id="rId1" Type="{REL_NS}/worksheet" Target="worksheets/sheet1.xml"/>'
        f'<Relationship Id="rId2" Type="{REL_NS}/sharedStrings" Target="sharedStrings.xml"/>'
        "</Relationships>"
    )
    ct = content_types([
        ("/xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
        ("/xl/worksheets/sheet1.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"),
        ("/xl/sharedStrings.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"),
    ])
    write_zip(path, [
        ("[Content_Types].xml", ct),
        ("_rels/.rels", root_rels("xl/workbook.xml")),
        ("xl/workbook.xml", wb),
        ("xl/_rels/workbook.xml.rels", wb_rels),
        ("xl/sharedStrings.xml", "".join(sst)),
        ("xl/worksheets/sheet1.xml", "".join(sheet)),
    ])


def gen_docx(path, paras):
    body = ['<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>']
    for i in range(paras):
        body.append(
            f"<w:p><w:pPr><w:pStyle w:val=\"Normal\"/></w:pPr>"
            f"<w:r><w:rPr><w:b/></w:rPr><w:t>Paragraph {i}</w:t></w:r>"
            f"<w:r><w:t xml:space=\"preserve\"> body text with entities &amp; tabs</w:t></w:r>"
            f"<w:r><w:tab/><w:t>col {i % 17}</w:t></w:r>"
            "</w:p>"
        )
    body.append("</w:body></w:document>")
    ct = content_types([
        ("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
    ])
    write_zip(path, [
        ("[Content_Types].xml", ct),
        ("_rels/.rels", root_rels("word/document.xml")),
        ("word/document.xml", "".join(body)),
    ])


def gen_pptx(path, slides):
    files = []
    sld_ids = []
    pres_rels = [f'<?xml version="1.0"?><Relationships xmlns="{PKG_REL_NS}">']
    overrides = [("/ppt/presentation.xml", "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml")]
    for i in range(1, slides + 1):
        rid = f"rId{i + 1}"
        sld_ids.append(f'<p:sldId id="{255 + i}" r:id="{rid}"/>')
        pres_rels.append(f'<Relationship Id="{rid}" Type="{REL_NS}/slide" Target="slides/slide{i}.xml"/>')
        body = "".join(
            f'<a:p><a:r><a:t>Slide {i} bullet {j}: things &amp; stuff</a:t></a:r></a:p>'
            for j in range(20)
        )
        files.append((
            f"ppt/slides/slide{i}.xml",
            '<?xml version="1.0"?>'
            '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
            'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
            f"<p:cSld><p:spTree>{body}</p:spTree></p:cSld></p:sld>",
        ))
        overrides.append((f"/ppt/slides/slide{i}.xml", "application/vnd.openxmlformats-officedocument.presentationml.slide+xml"))
    pres_rels.append("</Relationships>")
    pres = (
        '<?xml version="1.0"?>'
        '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
        f'xmlns:r="{REL_NS}">'
        f'<p:sldIdLst>{"".join(sld_ids)}</p:sldIdLst></p:presentation>'
    )
    files = [
        ("[Content_Types].xml", content_types(overrides)),
        ("_rels/.rels", root_rels("ppt/presentation.xml")),
        ("ppt/presentation.xml", pres),
        ("ppt/_rels/presentation.xml.rels", "".join(pres_rels)),
    ] + files
    write_zip(path, files)


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    kind, path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    {"xlsx": gen_xlsx, "docx": gen_docx, "pptx": gen_pptx}[kind](path, n)
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
