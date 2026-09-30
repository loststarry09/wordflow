#!/usr/bin/env bash
#
# Deterministically regenerate the DOCX fixtures under tests/fixtures/.
#
# Requirements: officecli >= 1.0.152 on PATH, base64 (coreutils).
# Every fixture is created with an explicit --locale so the result does not
# depend on the host machine's locale, and each file is closed afterwards so a
# resident process from one fixture cannot leak into the next.
#
# Fixtures are snapshots: OfficeCLI stamps created/modified timestamps, so a
# regenerated .docx is not byte-identical to the committed one. Regenerate
# deliberately (e.g. after an OfficeCLI upgrade), not on every test run.
#
# Usage: tests/generate-fixtures.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
IMG_B64='iVBORw0KGgoAAAANSUhEUgAAAGAAAABACAIAAABqVuVZAAAAoUlEQVR4nO3QoQ2AQAAEwYdqvgT6V5RAOQgS7CryiBl18rJjAB/a3nXOufDH3xzX9Yx97Y//EygIFAQKAgWBgkBBoCBQECgIFAQKAgWBgkBBoCBQECgIFAQKAgWBgkBBoCBQECgIFAQKAgWBgkBBoCBQECgIFAQKAgWBgkBBoCBQECgIFAQKAgWBgkBBoCBQECgIFAQKAgWBgkBBoCAQsNINI6ADdOJittcAAAAASUVORK5CYII='

command -v officecli >/dev/null || { echo "officecli not found on PATH" >&2; exit 1; }
command -v base64   >/dev/null || { echo "base64 not found on PATH"   >&2; exit 1; }

# --- shared asset ----------------------------------------------------------
mkdir -p "$FIX/assets"
printf '%s' "$IMG_B64" | base64 -d > "$FIX/assets/test-image.png"

# --- helpers ---------------------------------------------------------------
new() { # new <path> <locale>
  local f="$1" loc="$2"
  officecli close "$f" >/dev/null 2>&1 || true
  rm -f "$f"
  mkdir -p "$(dirname "$f")"
  officecli create "$f" --locale "$loc" >/dev/null
}

finish() { officecli close "$1" >/dev/null 2>&1 || true; }

add() { # add <file> <args...>
  local f="$1"; shift
  officecli add "$f" "$@" >/dev/null
}

setp() { # setp <file> <path> <args...>
  local f="$1" p="$2"; shift 2
  officecli set "$f" "$p" "$@" >/dev/null
}

echo "Generating fixtures in $FIX"

# ===========================================================================
# styles/
# ===========================================================================

f="$FIX/styles/heading-hierarchy.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop style=Title     --prop text="WordFlow Fixture: Heading Hierarchy"
add "$f" /body --type paragraph --prop style=Heading1  --prop text="Heading Level 1"
add "$f" /body --type paragraph                        --prop text="Body text under heading one."
add "$f" /body --type paragraph --prop style=Heading2  --prop text="Heading Level 2"
add "$f" /body --type paragraph                        --prop text="Body text under heading two."
add "$f" /body --type paragraph --prop style=Heading3  --prop text="Heading Level 3"
add "$f" /body --type paragraph                        --prop text="Body text under heading three."
finish "$f"

f="$FIX/styles/caption-defined.docx"; new "$f" en-US
add "$f" /styles --type style --prop styleId=Caption --prop name="caption" --prop type=paragraph --prop basedOn=Normal --prop qFormat=true --prop align=center --prop spaceBefore=6pt --prop spaceAfter=12pt
add "$f" /body --type paragraph                        --prop text="A Caption style is defined explicitly before it is used."
add "$f" /body --type paragraph --prop style=Caption   --prop text="Figure 1: Caption using an explicitly defined Caption style."
finish "$f"

f="$FIX/styles/caption-dangling.docx"; new "$f" en-US
add "$f" /body --type paragraph                        --prop text="A Caption style is referenced but never defined (dangling reference)."
add "$f" /body --type paragraph --prop style=Caption   --prop text="Figure 1: Caption with no matching styles.xml entry."
finish "$f"

f="$FIX/styles/unstyled.docx"; new "$f" en-US
add "$f" /body --type paragraph                        --prop text="This document uses no named styles."
add "$f" /body --type paragraph                        --prop text="Every paragraph is the default Normal style."
add "$f" /body --type paragraph                        --prop text="There is no heading hierarchy to preserve."
finish "$f"

f="$FIX/styles/template.docx"; new "$f" en-US
add "$f" /styles --type style --prop styleId=WFBody --prop name="WF Body" --prop type=paragraph --prop basedOn=Normal --prop qFormat=true --prop align=left --prop spaceAfter=6pt
add "$f" /styles --type style --prop styleId=WFQuote --prop name="WF Quote" --prop type=paragraph --prop basedOn=Normal --prop qFormat=true --prop align=left --prop spaceBefore=6pt --prop spaceAfter=6pt
add "$f" /body --type paragraph --prop style=WFBody  --prop text="Template body sample."
add "$f" /body --type paragraph --prop style=WFQuote --prop text="Template quote sample."
finish "$f"

# The full WordFlow standard style set with Simplified-Chinese defaults (#17):
# scripts/wf-standard-styles.sh defines the styles (spec D7) on a fresh zh-CN
# base, then every style is exercised once. Do not expand the style list.
f="$FIX/styles/standard-style-set.docx"
base="$(mktemp -d)/base.docx"; new "$base" zh-CN
"$ROOT/scripts/wf-standard-styles.sh" "$base" --out "$f" >/dev/null
finish "$base"; rm -rf "$(dirname "$base")"
add "$f" /body --type paragraph --prop style=Title     --prop text="WordFlow 标准样式集 Standard Style Set"
add "$f" /    --type toc --prop levels="1-3" --prop hyperlinks=true --prop pageNumbers=false
add "$f" /body --type paragraph --prop style=Heading1  --prop text="一级标题 Heading 1"
add "$f" /body --type paragraph --prop style=Normal    --prop text="正文段落：宋体小四，首行缩进两字符，1.5 倍行距，两端对齐。Body text is justified."
add "$f" /body --type paragraph --prop style=Heading2  --prop text="二级标题 Heading 2"
add "$f" /body --type paragraph --prop style=Normal    --prop text="正文段落二：样式集中每一处引用都有定义。"
add "$f" /body --type paragraph --prop style=Heading3  --prop text="三级标题 Heading 3"
add "$f" /body --type paragraph --prop style=Normal    --prop text="正文段落三。"
add "$f" /body --type paragraph --prop style=Heading4  --prop text="四级标题 Heading 4"
add "$f" /body --type paragraph --prop style=Normal    --prop text="正文段落四。"
add "$f" /body --type paragraph --prop style=BodyNoIndent --prop text="正文无缩进样式 BodyNoIndent：此行不首行缩进。"
add "$f" /body --type paragraph --prop style=Quote     --prop text="引用样式 Quote：这是一段引用文字。"
add "$f" /body --type paragraph --prop style=ListParagraph --prop text="列表段落样式 ListParagraph。"
add "$f" /body --type paragraph --prop style=Caption   --prop text="图 1：图注表注样式 Caption"
add "$f" /body --type paragraph --prop text="链接："
add "$f" /body/p[15] --type hyperlink --prop url=https://example.com --prop text="示例链接" --prop rStyle=Hyperlink
add "$f" /body --type paragraph --prop text="脚注示例"
add "$f" /body/p[16] --type footnote --prop text="脚注文本 Footnote text."
add "$f" / --type header --prop text="页眉 Header" --prop align=center
add "$f" / --type footer --prop text="页脚 Footer" --prop align=center
setp "$f" /header[1]/p[1] --prop style=Header
setp "$f" /footer[1]/p[1] --prop style=Footer
officecli refresh "$f" >/dev/null 2>&1 || true
finish "$f"

# ===========================================================================
# sections/
# ===========================================================================

f="$FIX/sections/margins-orientation.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="Section 1: portrait A4, standard margins."
add "$f" /                        --type section --prop type=nextPage
add "$f" /body --type paragraph --prop text="Section 2: landscape A4, narrow margins."
setp "$f" /section[1] --prop orientation=portrait  --prop marginTop=2.54cm --prop marginBottom=2.54cm --prop marginLeft=3.18cm --prop marginRight=3.18cm
setp "$f" /section[2] --prop orientation=landscape --prop marginTop=1.5cm  --prop marginBottom=1.5cm  --prop marginLeft=1cm    --prop marginRight=1cm
finish "$f"

f="$FIX/sections/page-number-restart.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="Section 1: arabic page numbering."
add "$f" /                        --type section --prop type=nextPage
add "$f" /body --type paragraph --prop text="Section 2: lower-roman numbering restarted at 1."
setp "$f" /section[2] --prop pageNumFmt=lowerRoman --prop pageStart=1
finish "$f"

f="$FIX/sections/page-setup-default.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="Section 1: WordFlow default page setup (A4 portrait, spec D6 margins)."
add "$f" /                        --type section --prop type=nextPage
add "$f" /body --type paragraph --prop text="Section 2: the same default page setup, across a nextPage section break."
setp "$f" /section[1] --prop orientation=portrait --prop pageWidth=21cm --prop pageHeight=29.7cm --prop marginTop=2.54cm --prop marginBottom=2.54cm --prop marginLeft=3.17cm --prop marginRight=3.17cm
setp "$f" /section[2] --prop orientation=portrait --prop pageWidth=21cm --prop pageHeight=29.7cm --prop marginTop=2.54cm --prop marginBottom=2.54cm --prop marginLeft=3.17cm --prop marginRight=3.17cm
finish "$f"

# ===========================================================================
# headers/
# ===========================================================================

f="$FIX/headers/page-number-footer.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="The footer carries a live PAGE field, centred."
add "$f" / --type footer --prop field=page --prop align=center
finish "$f"

# ===========================================================================
# images/
# ===========================================================================

f="$FIX/images/inline-image.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="Inline image (flows with the text):"
add "$f" /body/p[1] --type picture --prop src="$FIX/assets/test-image.png" --prop alt="Test image: red rectangle" --prop width=3cm
finish "$f"

f="$FIX/images/anchored-image.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="Anchored image (floats; wrap top-and-bottom, centred on the column):"
add "$f" /body/p[1] --type picture --prop src="$FIX/assets/test-image.png" --prop alt="Anchored test image: red rectangle" --prop width=3cm --prop anchor=true --prop wrap=topAndBottom --prop hRelative=column --prop vRelative=paragraph --prop hPosition=0cm
finish "$f"

# ===========================================================================
# tables/
# ===========================================================================

f="$FIX/tables/fixed-table.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="Fixed-layout 3x3 table, explicit column widths, direct borders, repeating header row."
add "$f" /body --type table --prop data="Column A,Column B,Column C;A1,B1,C1;A2,B2,C2;A3,B3,C3" --prop layout=fixed --prop colWidths=3000,3000,3000 --prop width=9cm --prop border.all="single;8;000000"
setp "$f" /body/tbl[1]/tr[1] --prop header=true
finish "$f"

f="$FIX/tables/nested-table.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="Outer fixed table; a nested fixed table sits inside its middle-left cell:"
add "$f" /body --type table --prop data="Outer A,Outer B;nested cell,outer right;outer bottom 1,outer bottom 2" --prop layout=fixed --prop colWidths=3402,3402 --prop width=12cm --prop border.all="single;8;000000"
add "$f" /body/tbl[1]/tr[2]/tc[1] --type table --prop data="Inner 1,Inner 2;Inner 3,Inner 4" --prop layout=fixed --prop colWidths=1418,1417 --prop width=5cm --prop border.all="single;8;C00000"
finish "$f"

# ===========================================================================
# captions/
# ===========================================================================

f="$FIX/captions/caption-seq.docx"; new "$f" en-US
add "$f" /styles --type style --prop styleId=Caption --prop name="caption" --prop type=paragraph --prop basedOn=Normal --prop qFormat=true --prop align=center
add "$f" /body --type paragraph --prop text="A figure caption built from a defined Caption style plus a SEQ field."
add "$f" /body --type paragraph --prop style=Caption --prop text="Figure "
add "$f" /body/p[2] --type field --prop fieldType=seq --prop id=Figure
add "$f" /body/p[2] --type run --prop text=": Example figure caption."
setp "$f" / --prop recalcFields=seq
finish "$f"

# ===========================================================================
# fields/
# ===========================================================================

f="$FIX/fields/bookmark-ref-pageref.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="See the target below, then come back here."
add "$f" / --type bookmark --prop name="target" --prop text="Target paragraph (bookmark)"
add "$f" /body --type paragraph --prop text="Reference: "
add "$f" /body/p[3] --type field --prop fieldType=ref --prop name=target --prop hyperlink=true
add "$f" /body/p[3] --type run --prop text=" on page "
add "$f" /body/p[3] --type field --prop fieldType=pageref --prop name=target --prop hyperlink=true
officecli refresh "$f" >/dev/null 2>&1 || true
finish "$f"

# ===========================================================================
# toc/
# ===========================================================================

f="$FIX/toc/toc-basic.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop style=Title --prop text="WordFlow Fixture: Table of Contents"
add "$f" / --type toc --prop levels="1-3" --prop title="Contents" --prop hyperlinks=true --prop pageNumbers=true
add "$f" /body --type paragraph --prop style=Heading1 --prop text="Introduction"
add "$f" /body --type paragraph --prop text="Introductory body text."
add "$f" /body --type paragraph --prop style=Heading2 --prop text="Background"
add "$f" /body --type paragraph --prop text="Background body text."
add "$f" /body --type paragraph --prop style=Heading1 --prop text="Methods"
add "$f" /body --type paragraph --prop text="Methods body text."
officecli refresh "$f" >/dev/null 2>&1 || true
finish "$f"

# ===========================================================================
# notes/
# ===========================================================================

f="$FIX/notes/footnote-basic.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="A sentence with a footnote reference."
add "$f" /body/p[1] --type footnote --prop text="This is the footnote text."
finish "$f"

# ===========================================================================
# equations/
# ===========================================================================

f="$FIX/equations/inline-equation.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="Mass-energy equivalence inline:"
add "$f" /body --type equation --prop mode=inline --prop formula="E = mc^2"
finish "$f"

f="$FIX/equations/display-equation.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop text="A display equation in its own paragraph:"
add "$f" /body --type equation --prop mode=display --prop formula="\\frac{a}{b} = c"
finish "$f"

# ===========================================================================
# cjk/
# ===========================================================================

f="$FIX/cjk/cjk-fonts-indent.docx"; new "$f" zh-CN
add "$f" /body --type paragraph --prop text="第一段：验证东亚字体（宋体 / SimSun）与西文字体回退。" --prop font.ea="SimSun" --prop font.latin="Times New Roman"
add "$f" /body --type paragraph --prop text="第二段：验证以字符为单位的两字首行缩进（firstLineChars=200）。" --prop font.ea="Microsoft YaHei"
setp "$f" /body/p[2] --prop firstLineChars=200
finish "$f"

# ===========================================================================
# portability/
# ===========================================================================

f="$FIX/portability/transitional-baseline.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop style=Heading1 --prop text="Transitional OOXML baseline"
add "$f" /body --type paragraph --prop text="This document is emitted in Transitional OOXML, not Strict."
finish "$f"

# ===========================================================================
# multipage/ — multi-page page-number field behaviour (issue #3)
# ===========================================================================
# Forcing the page count with explicit page breaks keeps the true page number
# of every element deterministic in Word, WPS, and LibreOffice, so a stale or
# frozen cached field can be told apart from a per-page value. Page 1 holds the
# title; a break ends each of the first three pages; page 4 carries a body
# PAGEREF to a bookmark on page 3; a TOC field (page numbers on) lists the four
# headings. The footer is "Page <PAGE> of <NUMPAGES>". refresh fills the TOC
# and PAGEREF caches with officecli's HTML-pagination values.

f="$FIX/multipage/page-fields.docx"; new "$f" en-US
add "$f" /body --type paragraph --prop style=Title    --prop text="Multipage page-field fixture"
add "$f" /body --type paragraph --prop style=Heading1 --prop text="Section One"
add "$f" /body --type paragraph                       --prop text="Body text on page one."
add "$f" /body --type pagebreak
add "$f" /body --type paragraph --prop style=Heading1 --prop text="Section Two"
add "$f" /body --type paragraph                       --prop text="Body text on page two."
add "$f" /body --type pagebreak
add "$f" /body --type paragraph --prop style=Heading1 --prop text="Section Three"
add "$f" /body --type paragraph                       --prop text="Bookmark target paragraph: "
add "$f" /    --type bookmark --prop name=target --prop text="TARGET"
add "$f" /body --type paragraph                       --prop text="Body text still on page three."
add "$f" /body --type pagebreak
add "$f" /body --type paragraph --prop style=Heading1 --prop text="Section Four"
add "$f" /body --type paragraph                       --prop text="Reference to target is on page "
add "$f" /body/p[14] --type field --prop fieldType=pageref --prop name=target --prop hyperlink=true
add "$f" /    --type toc --prop levels="1-2" --prop title="Contents" --prop hyperlinks=true --prop pageNumbers=true
add "$f" /    --type footer --prop text="Page " --prop align=center
add "$f" "/footer[1]/p[1]" --type field --prop fieldType=page
add "$f" "/footer[1]/p[1]" --type run  --prop text=" of "
add "$f" "/footer[1]/p[1]" --type field --prop fieldType=numpages
officecli refresh "$f" >/dev/null 2>&1 || true
finish "$f"

echo "Done. Verify with: tests/validate-fixtures.sh"
