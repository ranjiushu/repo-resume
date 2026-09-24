#!/usr/bin/env bash
# 把「AGENTS.md 信息密度守卫」装进某个 git 仓库（强制层）。
#
# 装三样东西：
#   <repo>/tools/guards/{measure.py,guard.py,SOURCE.md}   守卫本体（**入库**，随 clone 走）
#   <repo>/.githooks/pre-commit                          薄壳调用块（标记包裹，幂等）
#   git config core.hooksPath=.githooks                   让钩子生效
#
# 用法：
#   bash install-hook.sh                  # 装到当前仓库
#   bash install-hook.sh --repo <路径>     # 装到指定仓库
#   bash install-hook.sh --check          # 只校验（副本哈希 / 钩子块 / core.hooksPath）
#   bash install-hook.sh --dry-run        # 只打印将要做的改动
#   bash install-hook.sh --uninstall      # 拆掉（只动本守卫的块与文件）
#
# 幂等：可反复执行；只动 tools/guards/ 下的本守卫文件与钩子里的标记块，不碰其他防线。
# 退出码：0 成功 / 1 失败或校验不通过。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD=(measure.py guard.py)
NOTICE="SOURCE.md"
MARK_BEGIN="# >>> repo-resume: entry-doc-governance (start) >>>"
MARK_END="# <<< repo-resume: entry-doc-governance (end) <<<"
# 技能改名前装过的标记块；安装时自动迁移，避免叠成两块把守卫跑两遍
LEGACY_MARKS=(
  "# >>> doc-governance: agents-md-budget (start) >>>|# <<< doc-governance: agents-md-budget (end) <<<"
)

strip_block() {  # $1=钩子文件 $2=起始标记 $3=结束标记；块存在则整块删除
  [ -f "$1" ] || return 0
  grep -qF "$2" "$1" || return 0
  python3 - "$1" "$2" "$3" <<'PYEOF'
import io, sys
hook, mb, me = sys.argv[1:4]
src = io.open(hook, encoding="utf-8").read()
i, j = src.find(mb), src.find(me)
if i != -1 and j != -1:
    io.open(hook, "w", encoding="utf-8").write((src[:i] + src[j + len(me):]).strip("\n") + "\n")
PYEOF
}

MODE=install
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --check) MODE=check; shift ;;
    --dry-run) MODE=dryrun; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
    *) echo "[install] 未知参数：$1（--help 看用法）" >&2; exit 1 ;;
  esac
done

# ── 定位仓库 ──────────────────────────────────────────────────────────
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
# 用 rev-parse 判定而非 [ -d .git ]：git worktree / submodule 的 .git 是文件不是目录
if [ -z "$REPO" ] || ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "[install] ❌ 不是 git 仓库：${REPO:-（当前目录）}；用 --repo <路径> 指定" >&2
  exit 1
fi
REPO="$(cd "$REPO" && pwd)"
GUARD_DIR="$REPO/tools/guards"
HOOK="$REPO/.githooks/pre-commit"

# ── 校验模式 ──────────────────────────────────────────────────────────
if [ "$MODE" = check ]; then
  rc=0
  hooks_path="$(git -C "$REPO" config --get core.hooksPath || true)"
  if [ "$hooks_path" != ".githooks" ]; then
    echo "[install] ❌ core.hooksPath=$hooks_path（应为 .githooks）——钩子不会生效" >&2
    rc=1
  fi
  for f in "${PAYLOAD[@]}"; do
    if [ ! -f "$GUARD_DIR/$f" ]; then
      echo "[install] ❌ 缺 $GUARD_DIR/$f" >&2; rc=1
    elif ! cmp -s "$HERE/$f" "$GUARD_DIR/$f"; then
      echo "[install] ⚠️  $f 与上游不一致（仓库副本被手改过，或上游已更新）" >&2; rc=1
    fi
  done
  if [ ! -f "$HOOK" ] || ! grep -qF "$MARK_BEGIN" "$HOOK"; then
    echo "[install] ❌ $HOOK 里没有本守卫的调用块" >&2; rc=1
  else
    # 死守卫检查：块出现在顶层 exit 之后 → 钩子根本走不到它（静默哑门禁）
    _reach="$(awk -v mb="$MARK_BEGIN" '
      index($0, mb) { print (dead ? "dead" : "ok"); found=1; exit }
      /^exit([[:space:]]|$)/ { dead=1 }
      END { if (!found) print "missing" }
    ' "$HOOK")"
    if [ "$_reach" != "ok" ]; then
      echo "[install] ❌ 守卫块不可达（在顶层 exit 之后；实测：$_reach）—— 形同没装，拒绝放行" >&2
      rc=1
    fi
  fi
  for _m in "${LEGACY_MARKS[@]}"; do
    if [ -f "$HOOK" ] && grep -qF "${_m%%|*}" "$HOOK"; then
      echo "[install] ⚠️  发现旧名标记块：${_m%%|*}；重跑安装以迁移（否则守卫会被执行两次）" >&2
      rc=1
    fi
  done
  if [ "$rc" = 0 ]; then
    echo "[install] ✅ 已正确安装：$REPO"
  else
    echo "[install] 修复：重跑 bash $0 --repo $REPO（幂等）" >&2
  fi
  exit "$rc"
fi

# ── 组块内容 ──────────────────────────────────────────────────────────
read -r -d '' BLOCK <<BLOCKEOF || true
$MARK_BEGIN
# 由 repo-resume 技能（子技能 entry-doc-governance）的 install-hook.sh 写入，**勿手改**；
# 更新走上游重跑安装脚本（幂等）。守卫本体：tools/guards/guard.py
{
  _gd_root="\$(git rev-parse --show-toplevel 2>/dev/null)"
  _gd_guard="\$_gd_root/tools/guards/guard.py"
  if [ -z "\$_gd_root" ] || [ ! -f "\$_gd_guard" ]; then
    echo "[pre-commit] ❌ 文档守卫缺失（tools/guards/guard.py）—— fail-closed，拒绝提交" >&2
    echo "[pre-commit]    修复：重跑上游 install-hook.sh（幂等；上游位置见 tools/guards/SOURCE.md）" >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[pre-commit] ❌ 缺 python3，无法校验 AGENTS.md 信息密度 —— fail-closed，拒绝提交" >&2
    exit 1
  fi
  ( cd "\$_gd_root" && PYTHONDONTWRITEBYTECODE=1 python3 "\$_gd_guard" --staged )
  _gd_rc=\$?
  if [ "\$_gd_rc" -eq 1 ]; then exit 1; fi
  if [ "\$_gd_rc" -ne 0 ] && [ "\$_gd_rc" -ne 2 ]; then
    echo "[pre-commit] ❌ 文档守卫异常退出（rc=\$_gd_rc）—— fail-closed，拒绝提交" >&2
    exit 1
  fi
}
$MARK_END
BLOCKEOF

if [ "$MODE" = uninstall ]; then
  if [ -f "$HOOK" ] && grep -qF "$MARK_BEGIN" "$HOOK"; then
    strip_block "$HOOK" "$MARK_BEGIN" "$MARK_END"
    echo "[install] ✅ 已移除钩子块：$HOOK"
  else
    echo "[install] 钩子里没有本守卫的块，无需移除"
  fi
  for _m in "${LEGACY_MARKS[@]}"; do
    if [ -f "$HOOK" ] && grep -qF "${_m%%|*}" "$HOOK"; then
      strip_block "$HOOK" "${_m%%|*}" "${_m##*|}"
      echo "[install] ✅ 已移除旧名标记块"
    fi
  done
  rm -rf "$GUARD_DIR/__pycache__"
  for f in "${PAYLOAD[@]}" "$NOTICE"; do rm -f "$GUARD_DIR/$f"; done
  rmdir "$GUARD_DIR" 2>/dev/null || true
  echo "[install]    提示：若 $HOOK 已无其他内容，可自行删除该空壳钩子"
  exit 0
fi

if [ "$MODE" = dryrun ]; then
  echo "[install] [dry-run] 仓库：$REPO"
  echo "[install] [dry-run] 将写入：$GUARD_DIR/{$(IFS=,; echo "${PAYLOAD[*]}"),$NOTICE}"
  echo "[install] [dry-run] 将在 $HOOK 写入/替换标记块"
  echo "[install] [dry-run] 将设置 core.hooksPath=.githooks"
  exit 0
fi

# ── 安装 ──────────────────────────────────────────────────────────────
mkdir -p "$GUARD_DIR" "$REPO/.githooks"
for f in "${PAYLOAD[@]}"; do
  cp "$HERE/$f" "$GUARD_DIR/$f"
done
cat > "$GUARD_DIR/$NOTICE" <<'NOTICEEOF'
# tools/guards —— 文档守卫（分发副本）

本目录由 repo-resume 技能（子技能 `entry-doc-governance`）的 `install-hook.sh` 写入，**请勿手改**：
手改会在下次安装时被覆盖，并让仓库与上游漂移。

- 上游：技能的 `entry-doc-governance/scripts/`（canonical）
- 更新：拿到新版技能目录后重跑 `install-hook.sh`（幂等，可反复执行）
- 校验：`install-hook.sh --check`（比对副本哈希 + 钩子块 + core.hooksPath）
- 阈值与算法唯一事实源：本目录 `measure.py`（`python3 measure.py --print-policy`）
NOTICEEOF

if [ ! -f "$HOOK" ]; then
  printf '#!/usr/bin/env bash\n# 由 repo-resume 技能 create 的钩子（原先无 pre-commit）\nset -uo pipefail\n\n' > "$HOOK"
fi

for _m in "${LEGACY_MARKS[@]}"; do
  if [ -f "$HOOK" ] && grep -qF "${_m%%|*}" "$HOOK"; then
    strip_block "$HOOK" "${_m%%|*}" "${_m##*|}"
    echo "[install] 🔁 已迁移旧名标记块 → $MARK_BEGIN"
  fi
done

python3 - "$HOOK" "$MARK_BEGIN" "$MARK_END" "$BLOCK" <<'PYEOF'
import io, os, re, sys
hook, mb, me, block = sys.argv[1:5]
block = block.rstrip("\n") + "\n"
src = io.open(hook, encoding="utf-8").read() if os.path.exists(hook) else ""
i, j = src.find(mb), src.find(me)
if i != -1 and j != -1:
    # 先摘掉旧块，再按同一套规则放回：老版本装错的块（追加在 exit 之后的死守卫）
    # 靠这一步自动归位，不需要人工 --uninstall 再装。
    src = src[:i] + src[j + len(me):]
lines = src.rstrip("\n").split("\n") if src.strip() else []
# 顶层 `exit`（含 `exit 0`）之后的代码永不执行：守卫若排在它后面就是死守卫——
# 看着装好了、实际一次都不跑（哑门禁比没门禁更危险）。故插到**最后一个**顶层 exit 之前。
cut = None
for n, line in enumerate(lines):
    if re.match(r"^exit(\s+\S+)?\s*$", line):
        cut = n
if cut is None:
    new = ("\n".join(lines) + "\n\n" + block) if lines else block
else:
    head = "\n".join(lines[:cut]).rstrip("\n")
    tail = "\n".join(lines[cut:]).strip("\n")
    new = (head + "\n\n" if head else "") + block + (tail + "\n" if tail else "")
io.open(hook, "w", encoding="utf-8").write(new)
PYEOF
chmod +x "$HOOK"

# 覆盖 core.hooksPath 前先告警：旧值（如 husky 的 .husky）会因此失效，需人工合并
_prev_hooks="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || true)"
if [ -n "$_prev_hooks" ] && [ "$_prev_hooks" != ".githooks" ]; then
  echo "[install] ⚠️  原 core.hooksPath=$_prev_hooks 将被覆盖为 .githooks" >&2
  echo "[install]    若该目录已有其他钩子（如 husky），请人工迁移合并到 .githooks/ 后重跑 --check" >&2
fi
git -C "$REPO" config core.hooksPath .githooks

echo "[install] ✅ 已安装：$REPO"
echo "[install]    守卫：$GUARD_DIR/{$(IFS=,; echo "${PAYLOAD[*]}")}"
echo "[install]    钩子块：$HOOK"
echo "[install]    自检：bash $0 --repo $REPO --check"
exit 0
