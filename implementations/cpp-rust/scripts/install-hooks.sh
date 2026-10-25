#!/bin/bash
# 把 scripts/git-hooks/ 下的钩子装进本仓库的 hooks 目录（软链，不做拷贝）。
#
# 为什么用软链而不是 core.hooksPath：设了 hooksPath，.git/hooks/ 里原有的
# 其它钩子（编辑器/CLI 的追踪钩子等）会被整体忽略。软链只接管我们那几个文件名。
# 为什么软链而不是拷贝：拷贝会在源文件更新后留下过期副本，正身失去意义。
#
# 用法：bash scripts/install-hooks.sh [--force]
#   --force  覆盖已存在的、非本脚本建立的钩子文件（缺省只告警不动，避免踩掉
#            使用者自己放进去的同名钩子）
set -u

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	echo "install-hooks: 当前不在 git 仓库内" >&2
	exit 1
}
cd "$repo_root" || exit 1

src_dir="scripts/git-hooks"
if [ ! -d "$src_dir" ]; then
	echo "install-hooks: 缺少 $src_dir/" >&2
	exit 1
fi

hooks_rel="$(git rev-parse --git-path hooks)"
case "$hooks_rel" in
	/*) hooks_dir="$hooks_rel" ;;
	*)  hooks_dir="$repo_root/$hooks_rel" ;;
esac
mkdir -p "$hooks_dir" || { echo "install-hooks: 无法创建 $hooks_dir" >&2; exit 1; }

force=0
[ "${1:-}" = "--force" ] && force=1

linked=0 kept=0 skipped=0
for src_path in "$src_dir"/*; do
	[ -f "$src_path" ] || continue
	chmod +x "$src_path" 2>/dev/null

	name="$(basename "$src_path")"
	dest="$hooks_dir/$name"
	src_abs="$repo_root/$src_path"

	# 已是指向正身的软链 → 幂等，无需重建
	if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src_abs")" ]; then
		echo "[已装] $name"
		kept=$((kept + 1))
		continue
	fi

	if [ -e "$dest" ] || [ -L "$dest" ]; then
		if [ "$force" -eq 0 ]; then
			echo "[跳过] $name：$dest 已存在且非本脚本建立的软链" >&2
			echo "       确认可以让位于仓库版后：bash scripts/install-hooks.sh --force" >&2
			skipped=$((skipped + 1))
			continue
		fi
		rm -f "$dest"
	fi

	# 尽量写相对软链：仓库整体移动或换用户路径后仍然有效；coreutils 缺失则退回绝对路径
	rel="$(realpath --relative-to="$hooks_dir" "$src_abs" 2>/dev/null)"
	if [ -n "$rel" ] && ln -s "$rel" "$dest" 2>/dev/null; then
		echo "[安装] $name -> $rel"
	else
		ln -s "$src_abs" "$dest" || { echo "[失败] $name" >&2; skipped=$((skipped + 1)); continue; }
		echo "[安装] $name -> $src_abs"
	fi
	linked=$((linked + 1))
done

echo ""
echo "hooks 目录：$hooks_dir"
echo "新建 $linked 个，已存在 $kept 个，未覆盖 $skipped 个"
[ "$skipped" -eq 0 ] || echo "提示：有同名钩子未被接管，见上方 [跳过] 行"
exit 0
