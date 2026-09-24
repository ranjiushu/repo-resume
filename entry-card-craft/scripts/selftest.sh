#!/usr/bin/env bash
# selftest.sh —— 打印层 + 查看模式的自检：改完脚本跑一遍，确认没把声称能做到的事弄坏
#
# 断言只打「结构性」的那些（图片张数 = 实排页数、引用可达、幂等、静音规则…），
# 不写死任何文档的页数或 token——那是被测对象的现状，不是不变量。
#
# 用法
#   bash selftest.sh                 # 默认拿本目录的 AGENTS.md / AGENT.md；没有再退 SKILL.md
#   bash selftest.sh A.md B.md       # 指定文档（相对当前目录）
#   bash selftest.sh --keep          # 保留中间产物（默认跑完删掉）
#
# 退出码：0 全过 / 1 有失败 / 2 环境不具备（没有 Typst）→ 显式跳过，不算失败
set -uo pipefail
SK="$(cd "$(dirname "$0")" && pwd)"
KEEP=0; DOCS=()
for a in "$@"; do case "$a" in --keep) KEEP=1 ;; *) DOCS+=("$a") ;; esac; done
if [ "${#DOCS[@]}" -eq 0 ]; then
  for n in AGENTS.md AGENT.md SKILL.md; do [ -f "$n" ] && DOCS+=("$n"); done
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/entry-doc-selftest.XXXXXX")"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1（$2）"; else bad "$1：期望 $3，实得 $2"; fi; }
pages_of() { python3 -c 'import re,sys;print(len(re.findall(rb"/Type\s*/Page(?![s])",open(sys.argv[1],"rb").read())))' "$1"; }
links()    { grep -oE '\]\([^)]+\)' "$1" | sed 's/^](//; s/)$//'; }

CACHED_TYPST="$(ls -1 "$HOME"/.cache/repo-resume/typst/*/*/typst 2>/dev/null | head -1)"
command -v typst >/dev/null 2>&1 || [ -n "${TYPST_PATH:-}" ] || [ -n "$CACHED_TYPST" ] || {
  echo "跳过：本机没有 Typst（自检要真排页面）"; exit 2; }
[ "${#DOCS[@]}" -gt 0 ] || { echo "跳过：当前目录没有可测的入口文档"; exit 2; }
echo "被测文档：${DOCS[*]}"

echo "── 查看模式：图片 + INDEX.md"
bash "$SK/view-entry-doc.sh" --out "$WORK/v" "${DOCS[@]}" > "$WORK/v.log" 2>&1
IMGS=$(ls -1 "$WORK/v"/*-p[0-9]*.png 2>/dev/null | wc -l)
chk "产出的图片数 > 0" "$([ "$IMGS" -gt 0 ] && echo yes || echo no)" "yes"
chk "INDEX.md 存在" "$([ -f "$WORK/v/INDEX.md" ] && echo yes || echo no)" "yes"

echo "── 引用可达、且都是相对路径"
miss=0; for l in $(links "$WORK/v/INDEX.md"); do [ -f "$WORK/v/$l" ] || miss=$((miss+1)); done
chk "不可达引用数" "$miss" "0"
chk "绝对路径引用数" "$(grep -oE '\]\([^)]+\)' "$WORK/v/INDEX.md" | grep -c '](/')" "0"

echo "── 图片张数 = 该文档 PDF 实排页数（同档同页），且不同文档不共用图片"
diff=0; seen=""; dup=0
for png in "$WORK/v"/*-p1.png; do
  key="$(basename "$png" -p1.png)"
  pdf="$(ls -1t "$WORK/v/$key"-*.pdf 2>/dev/null | head -1)"
  if [ -z "$pdf" ]; then diff=$((diff+1)); continue; fi
  n=$(ls -1 "$WORK/v/$key"-p[0-9]*.png | wc -l); m=$(pages_of "$pdf")
  [ "$n" = "$m" ] || diff=$((diff+1))
  printf '%s\n' "$seen" | grep -qxF "$png" && dup=$((dup+1)); seen="$seen$png
"
done
chk "图数≠页数的文档数" "$diff" "0"
chk "被两个文档共用的图片数" "$dup" "0"

echo "── 幂等：连跑两次图片集合一致；多出来的旧页会被清掉"
before="$(ls -1 "$WORK/v"/*-p[0-9]*.png | xargs -n1 basename | sort | md5sum)"
_stale="$(basename "$(ls -1 "$WORK/v"/*-p1.png | head -1)" -p1.png)"
cp "$WORK/v/$_stale-p1.png" "$WORK/v/$_stale-p9.png"      # 同键的假页号：应当被清掉
bash "$SK/view-entry-doc.sh" --out "$WORK/v" --quiet "${DOCS[@]}" > /dev/null 2>&1
after="$(ls -1 "$WORK/v"/*-p[0-9]*.png | xargs -n1 basename | sort | md5sum)"
chk "多出来的 $_stale-p9.png 已清" "$([ -f "$WORK/v/$_stale-p9.png" ] && echo 还在 || echo 清了)" "清了"
chk "图片集合不变" "$after" "$before"

echo "── 参数：--ppi 生效、非法值被拒"
bash "$SK/view-entry-doc.sh" --out "$WORK/p" --quiet --ppi 70 "${DOCS[0]}" > /dev/null 2>&1
w1=$(python3 -c "import struct,glob;p=glob.glob('$WORK/p/*-p1.png')[0];print(struct.unpack('>II',open(p,'rb').read(24)[16:24])[0])" 2>/dev/null)
w2=$(python3 -c "import struct,glob;p=glob.glob('$WORK/v/*-p1.png')[0];print(struct.unpack('>II',open(p,'rb').read(24)[16:24])[0])" 2>/dev/null)
chk "70ppi 比默认 140ppi 窄" "$([ -n "$w1" ] && [ -n "$w2" ] && [ "$w1" -lt "$w2" ] && echo yes)" "yes"
chk "--ppi abc 被拒（rc=1）" "$(bash "$SK/view-entry-doc.sh" --ppi abc "${DOCS[0]}" >/dev/null 2>&1; echo $?)" "1"

echo "── 缺排版引擎：--quiet 下也要说出来，rc=0，不产垃圾"
out=$(env TYPST_PATH=/nope AGENT_DOC_TYPST_FETCH=0 TYPST_CACHE="$WORK/nocache" PATH=/usr/bin:/bin \
      bash "$SK/view-entry-doc.sh" --out "$WORK/n" --quiet "${DOCS[0]}" 2>&1); rc=$?
chk "rc" "$rc" "0"
chk "缺引擎时仍出声" "$(printf '%s' "$out" | grep -c '没找到 Typst')" "1"
chk "不留下空的产出目录" "$([ -d "$WORK/n" ] && echo 建了 || echo 没建)" "没建"

echo "── 回归：普通打印模式不产图片、结果行仍带时间戳文件名"
bash "$SK/print-entry-doc-typst.sh" --out "$WORK/t" --quiet "${DOCS[@]}" > "$WORK/t.log" 2>&1
chk "结果行数 = 文档数" "$(grep -c '^📄' "$WORK/t.log")" "${#DOCS[@]}"
chk "结果行带时间戳 PDF 名" "$(grep -cE '^📄 .+-[0-9]{8}-[0-9]{6}\.pdf（' "$WORK/t.log")" "${#DOCS[@]}"
chk "普通模式不产 PNG" "$(ls -1 "$WORK/t"/*.png 2>/dev/null | wc -l)" "0"
chk "健康路径无告警噪音" "$(grep -c '^\[print-typst\]' "$WORK/t.log")" "0"

echo "── 边界：目录里没有入口文档 / 产出目录建不了"
mkdir -p "$WORK/empty"
out=$(cd "$WORK/empty" && bash "$SK/view-entry-doc.sh" --out "$WORK/e" 2>&1); rc=$?
chk "无入口文档：rc" "$rc" "0"
chk "无入口文档：有说明" "$(printf '%s' "$out" | grep -c '未找到入口文档')" "1"
chk "无入口文档：不写 INDEX" "$([ -f "$WORK/e/INDEX.md" ] && echo 写了 || echo 没写)" "没写"
out=$(bash "$SK/view-entry-doc.sh" --out /dev/null/nope "${DOCS[0]}" 2>&1); rc=$?
chk "产出目录建不了：rc" "$rc" "0"
chk "产出目录建不了：有说明" "$(printf '%s' "$out" | grep -cE '建不了|写不进')" "1"

echo "── 递给人：serve-entry-doc.sh 打印 http 引用（不起服务）"
out=$(bash "$SK/serve-entry-doc.sh" --dir "$WORK/v" --print --host 192.0.2.7 --port 8123 2>&1); rc=$?
chk "rc" "$rc" "0"
chk "每个文档都有一条 http 引用" "$(printf '%s' "$out" | grep -c '!\[\](http://192.0.2.7:8123/.*-p1\.png)')" "$(ls -1 "$WORK/v"/*-p1.png | wc -l)"
chk "引用数 = 图片数" "$(printf '%s' "$out" | grep -c '!\[\](http://')" "$(ls -1 "$WORK/v"/*-p[0-9]*.png | wc -l)"
chk "不存在的目录被拒（rc=1）" "$(bash "$SK/serve-entry-doc.sh" --dir /nonexistent-dir --print >/dev/null 2>&1; echo $?)" "1"

echo "── 转换器回归：HTML 注释不入页、粗体里的行内代码不失手"
cat > "$WORK/conv.md" <<'MDEOF'
# 回归

- **数据写入必须走 `save*` 出口**
<!-- 同构节:begin branch-governance -->
正文
<!-- 同构节:end -->
MDEOF
python3 "$SK/md2typst.py" "$WORK/conv.md" "$WORK/conv.typ" std
chk "HTML 注释不进正文" "$(grep -cF '同构节' "$WORK/conv.typ")" "0"
chk "粗体不残留裸 \\*\\*" "$(grep -cF '**' "$WORK/conv.typ")" "0"
chk "粗体里的行内代码仍成立" "$(grep -cF '#raw("save*")' "$WORK/conv.typ")" "1"

[ "$KEEP" = 1 ] || rm -rf "$WORK"
echo
echo "════════ PASS $PASS / FAIL $FAIL ════════"
[ "$FAIL" = 0 ]
