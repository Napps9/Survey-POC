#!/usr/bin/env python3
"""Stitch the per-board PDFs from make_pdf.mjs into one numbered document.

Run `node make_pdf.mjs` first; this merges .pdf-parts/*.pdf in filename order
and stamps a footer on every page. Kept separate from the render step because
Chromium can only use one page size per print call, and these pages are
deliberately different heights (see make_pdf.mjs).

    python3 merge_pdf.py            # -> responder-share-mockups.pdf
"""
import pathlib
import sys

import pymupdf

HERE = pathlib.Path(__file__).parent
PARTS = HERE / ".pdf-parts"
OUT = HERE / "responder-share-mockups.pdf"

FOOT_LEFT = "Playverto · Pass it on — respondent share mockups"
INK = (0.478, 0.498, 0.580)   # --ink3 #7A7F94, the page's own muted grey


def main() -> int:
    parts = sorted(PARTS.glob("*.pdf"))
    if not parts:
        print(f"no parts in {PARTS}/ — run `node make_pdf.mjs` first", file=sys.stderr)
        return 1

    doc = pymupdf.open()
    for part in parts:
        with pymupdf.open(part) as src:
            doc.insert_pdf(src)

    total = doc.page_count
    for i, page in enumerate(doc, start=1):
        y = page.rect.height - 16
        page.insert_text((30, y), FOOT_LEFT, fontname="helv", fontsize=8, color=INK)
        label = f"{i} / {total}"
        w = pymupdf.get_text_length(label, fontname="helv", fontsize=8)
        page.insert_text((page.rect.width - 30 - w, y), label, fontname="helv", fontsize=8, color=INK)

    doc.set_metadata({
        "title": "Pass it on — respondent share mockups",
        "subject": "Playverto · letting a respondent send a Verto to friends and family",
        "keywords": "Playverto, Verto, share, mockups, open graph, WhatsApp",
    })
    doc.save(OUT, garbage=4, deflate=True)
    doc.close()
    print(f"{OUT.name} — {total} pages, {OUT.stat().st_size / 1024:.0f} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
