#!/usr/bin/env python3
"""md2typst.py —— 把 print-entry-doc.sh 里那套 markdown 解析规则,原样改写成 Typst 源码输出。
   块级覆盖：代码块 / 引用块(递归) / 表格 / 有序与无序列表 / 标题 / 段落 / 分隔线；
             HTML 注释(<!-- ... -->)整块丢弃——它是给工具看的标记(如同构节标注)，不是正文。
   行内覆盖：`code`、**bold**、[text](link)；bold 内允许嵌 `code`（如 **走 `save*` 出口**）。
   与原 md2html 的唯一差异：输出目标从 HTML 变成 Typst markup，样式改用 Typst 的
   #set / #show 规则统一声明（相当于原来那份 CSS 的等价物）。
   中文细节：中西文间隙交给 Typst 原生 cjk-latin-spacing（默认 auto，约 0.25em），
   中文软换行处不补空格——见 smart_join。
"""
import re, sys

# CJK 相关码位区间：汉字、扩展 A、中文标点、假名、全角/半角兼容形式。
# 仅用于判断「软换行拼接处要不要补空格」，不用于改写正文内容。
CJK_RANGES = (
    (0x2E80, 0x2EFF), (0x3000, 0x303F), (0x3040, 0x30FF), (0x3400, 0x4DBF),
    (0x4E00, 0x9FFF), (0xF900, 0xFAFF), (0xFF00, 0xFFEF), (0x20000, 0x2FA1F),
)

def is_cjk(ch):
    if not ch:
        return False
    o = ord(ch)
    return any(lo <= o <= hi for lo, hi in CJK_RANGES)

def smart_join(parts):
    """拼接 markdown 软换行。只要拼接处任一侧是 CJK 就不插空格。

    两个坑都由此避开，且都交给 Typst 原生处理：
      * 中文断行处多出一个空格——Typst 里源码换行即空格，中文行内不需要它；
      * 中西文之间——Typst 的 cjk-latin-spacing（默认 auto）已自动插入约 0.25em 间隙，
        这里再补一个字面空格就变成「间隙 + 全角空格」，过宽。
    纯西文之间照旧补一个空格（软换行语义）。
    """
    out = ""
    for p in parts:
        if out and not (is_cjk(out[-1]) or is_cjk(p[:1])):
            out += " "
        out += p
    return out

QUOTE = re.compile(r"^\s*>\s?")
UL = re.compile(r"^\s*[-*+]\s+")
OL = re.compile(r"^\s*\d+[.)]\s+")
HR = re.compile(r"^\s*(-{3,}|\*{3,}|_{3,})\s*$")
FENCE = re.compile(r"^\s*```")
HEAD = re.compile(r"^(#{1,6})\s+(.*)$")
# HTML 注释（`<!-- 同构节:begin x -->`）是给工具看的标记，不是正文：整块丢弃，不排进页面。
COMMENT_START = re.compile(r"^\s*<!--")
COMMENT_END = re.compile(r"-->\s*$")

def esc(s):
    # Typst 的特殊字符：# * _ $ [ ] < > @ ` \ 都要转义
    s = s.replace("\\", "\\\\")
    for ch in "#*_$[]<>@`":
        s = s.replace(ch, "\\" + ch)
    return s

def tstr(s):
    """Typst 字符串字面量。必须用双引号：Typst 里 ' 不是合法字符串定界符
    （Python 的 %r 会给出单引号，直接把排版打断）。"""
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')

# 行内三种记号。加粗内容允许含 `*`（如 **走 `save*` 出口**），故用非贪婪 .+? 而非 [^*]+；
# 匹配到加粗后递归解析其内容，行内代码才能嵌在粗体里而不被整行放弃。
INLINE_CODE = re.compile(r"`([^`]+)`")
INLINE_BOLD = re.compile(r"\*\*(.+?)\*\*", re.S)
INLINE_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
INLINE_ORDER = ((INLINE_CODE, "code"), (INLINE_BOLD, "bold"), (INLINE_LINK, "link"))

def inline(s):
    # 先处理行内代码/加粗/链接，再对剩余纯文本转义，避免语法字符被二次转义
    parts, pos, n = [], 0, len(s)
    while pos < n:
        hit = None
        for pattern, kind in INLINE_ORDER:
            m = pattern.search(s, pos)
            if m is not None and (hit is None or m.start() < hit[0].start()):
                hit = (m, kind)
        if hit is None:
            parts.append(esc(s[pos:]))
            break
        m, kind = hit
        if m.start() > pos:
            parts.append(esc(s[pos:m.start()]))
        if kind == "code":
            parts.append("#raw(%s)" % tstr(m.group(1)))
        elif kind == "bold":
            parts.append("*%s*" % inline(m.group(1)))  # Typst 里 *x* 就是加粗
        else:
            parts.append("#link(%s)[%s]" % (tstr(m.group(2)), inline(m.group(1))))
        pos = m.end()
    return "".join(parts)

def strip_q(line):
    return QUOTE.sub("", line, count=1)

def is_sep(line):
    t = line.strip()
    return bool(t) and set(t) <= set("|-: \t") and t.count("-") >= 2

def cells(line):
    r = line.strip()
    r = r[1:] if r.startswith("|") else r
    r = r[:-1] if r.endswith("|") else r
    return [c.strip() for c in r.split("|")]

def take_table(lines, i):
    head, rows = cells(lines[i]), []
    i += 2
    while i < len(lines) and lines[i].strip() and "|" in lines[i]:
        rows.append(cells(lines[i]))
        i += 1
    ncol = len(head)
    out = ["#table(", "  columns: %d," % ncol, "  stroke: 0.5pt + rgb(\"#cfcfcf\"),"]
    out.append("  fill: (x, y) => if y == 0 { rgb(\"#f2f2f2\") } else if calc.even(y) { rgb(\"#fafafa\") } else { white },")
    hdr = ", ".join("[*%s*]" % inline(c) for c in head)
    # 用 table.header() 而不是普通数据行：表头带「与首行同页」语义，
    # 否则表格在页底断开时会把表头单独留在上一页（页面终审可见的孤悬）。
    out.append("  table.header(%s)," % hdr)
    for r in rows:
        out.append("  " + ", ".join("[%s]" % inline(c) for c in r) + ",")
    out.append(")")
    return "\n".join(out), i

def render(lines, depth=0):
    out, i, n = [], 0, len(lines)
    while i < n:
        raw = lines[i]
        if COMMENT_START.match(raw):
            if not COMMENT_END.search(raw):
                i += 1
                while i < n and not COMMENT_END.search(lines[i]):
                    i += 1
            i += 1
            continue
        if FENCE.match(raw):
            i += 1
            buf = []
            while i < n and not FENCE.match(lines[i]):
                buf.append(lines[i])
                i += 1
            i += 1
            code = "\n".join(buf)
            out.append("#block(fill: rgb(\"#f6f6f6\"), inset: 8pt, width: 100%, radius: 2pt)[")
            out.append("```\n%s\n```" % code)
            out.append("]")
            continue
        if QUOTE.match(raw):
            buf = []
            while i < n and (QUOTE.match(lines[i]) or (buf and not lines[i].strip())):
                buf.append(strip_q(lines[i]) if QUOTE.match(lines[i]) else "")
                i += 1
            inner = render(buf, depth + 1)
            out.append("#block(inset: (left: 10pt), stroke: (left: 2pt + rgb(\"#d0d0d0\")))[")
            out.append(inner)
            out.append("]")
            continue
        if "|" in raw and i + 1 < n and is_sep(lines[i + 1]):
            t, i = take_table(lines, i)
            out.append(t)
            continue
        if UL.match(raw) or OL.match(raw):
            pat = UL if UL.match(raw) else OL
            marker = "-" if pat is UL else "+"
            while i < n and pat.match(lines[i]):
                item = pat.sub("", lines[i], count=1)
                i += 1
                while (i < n and lines[i].strip() and not pat.match(lines[i])
                       and not FENCE.match(lines[i]) and not QUOTE.match(lines[i])
                       and not HEAD.match(lines[i]) and not COMMENT_START.match(lines[i])
                       and "|" not in lines[i]):
                    item = smart_join([item, lines[i].strip()])
                    i += 1
                out.append("%s %s" % (marker, inline(item)))
            continue
        if HR.match(raw):
            out.append("#line(length: 100%, stroke: 0.5pt + rgb(\"#dddddd\"))")
            i += 1
            continue
        m = HEAD.match(raw)
        if m:
            lv = len(m.group(1))
            out.append("%s %s" % ("=" * lv, inline(m.group(2))))
            i += 1
            continue
        if not raw.strip():
            i += 1
            continue
        buf = [raw.strip()]
        i += 1
        while (i < n and lines[i].strip() and not FENCE.match(lines[i])
               and not QUOTE.match(lines[i]) and not HEAD.match(lines[i])
               and not UL.match(lines[i]) and not OL.match(lines[i])
               and not HR.match(lines[i]) and not COMMENT_START.match(lines[i])
               and "|" not in lines[i]):
            buf.append(lines[i].strip())
            i += 1
        out.append(inline(smart_join(buf)))
        out.append("")
        continue
    return "\n".join(out)

PREAMBLE = """\
// ── 页面与字体：对应原 print-entry-doc.sh 里 CSS 的 @page / body / h1-h4 规则 ──
// 标准档（std）：22mm/20mm 边距、10.5pt、行距 1.7；与原脚本 std 档一一对应。
#set page(paper: "a4", margin: (x: 20mm, y: 22mm))
#set text(font: ("Noto Serif CJK SC", "Georgia"), size: 10.5pt, lang: "zh", cjk-latin-spacing: auto)
#set par(leading: 0.7em, spacing: 0.6em, justify: false)
#show heading.where(level: 1): it => [
  #set text(font: ("Noto Sans CJK SC", "Helvetica"), size: 19pt, weight: "bold", tracking: 0.02em)
  #block(below: 18pt, above: 36pt)[#it.body]
  #line(length: 100%, stroke: 0.5pt + rgb("#c9c9c9"))
]
#show heading.where(level: 2): it => block(above: 27pt, below: 14pt, sticky: true)[
  #set text(font: ("Noto Sans CJK SC", "Helvetica"), size: 15pt, weight: "bold", tracking: 0.02em)
  #it.body
]
#show heading.where(level: 3): it => block(above: 22pt, below: 11pt)[
  #set text(font: ("Noto Sans CJK SC", "Helvetica"), size: 12.5pt, weight: "bold", tracking: 0.02em)
  #it.body
]
// 列表项间距 ≈ 正文行距的 1.2 倍（行内 15.0pt → 项间 18.2pt）。
// 必须明显大于折行项的「行内」间距，否则看不出项在哪儿结束。
#set list(spacing: 1em)
#set enum(spacing: 1em)
#show raw: it => text(font: "DejaVu Sans Mono", size: 9pt, fill: rgb("#333333"))[#it]

"""

PREAMBLE_FIT = """\
// 末页合并档（fit）：收紧边距/字号/行距，多容纳约三成
#set page(paper: "a4", margin: (x: 17mm, y: 16mm))
#set text(font: ("Noto Serif CJK SC", "Georgia"), size: 9.8pt, lang: "zh", cjk-latin-spacing: auto)
#set par(leading: 0.6em, spacing: 0.5em, justify: false)
#show heading.where(level: 1): it => [
  #set text(font: ("Noto Sans CJK SC", "Helvetica"), size: 18pt, weight: "bold", tracking: 0.02em)
  #block(below: 16pt, above: 32pt)[#it.body]
  #line(length: 100%, stroke: 0.5pt + rgb("#c9c9c9"))
]
#show heading.where(level: 2): it => block(above: 24pt, below: 13pt, sticky: true)[
  #set text(font: ("Noto Sans CJK SC", "Helvetica"), size: 14pt, weight: "bold", tracking: 0.02em)
  #it.body
]
#show heading.where(level: 3): it => block(above: 19pt, below: 10pt)[
  #set text(font: ("Noto Sans CJK SC", "Helvetica"), size: 12pt, weight: "bold", tracking: 0.02em)
  #it.body
]
// 同上比例，按 fit 的字号压缩（行内 13.0pt → 项间 15.5pt）。
#set list(spacing: 0.85em)
#set enum(spacing: 0.85em)
#show raw: it => text(font: "DejaVu Sans Mono", size: 8.5pt, fill: rgb("#333333"))[#it]

"""

def convert(md_path, out_path, tier='std'):
    text = open(md_path, encoding="utf-8").read()
    # 跳过 YAML frontmatter（原脚本没有这个逻辑，但 SKILL.md 有 --- 头，补一个最小处理）
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            text = text[end + 4:]
    lines = text.split("\n")
    body = render(lines)
    if tier == 'fit':
        preamble = PREAMBLE_FIT
    else:
        preamble = PREAMBLE
    open(out_path, "w", encoding="utf-8").write(preamble + body)

if __name__ == "__main__":
    convert(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 'std')
