#!/usr/bin/env bash
# 构建 mybot-agent（rig 驱动的 Rust agent，2026-09-24 批次 B；原 MCP sidecar 位置）。
# 刻意不碰 CMake：agent 是独立 cargo 产物。target/ 已在 .gitignore。
#
# 用法：bash scripts/build_agent.sh [--release|--tests|...]
#   缺省构建 release 二进制到 agent/target/release/mybot-agent
#   （守门与 CI 都按这个路径找产物；缺它时 agent 的 Rust 段按 SKIP 计）
set -euo pipefail

# cargo/rustc 装在 ~/.cargo/bin（rustup），非交互 shell 的 PATH 里没有它。
export PATH="$HOME/.cargo/bin:$PATH"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../agent"

if [ "$#" -eq 0 ]; then
  cargo build --release
else
  cargo build "$@"
fi

echo "产物: $(pwd)/target/release/mybot-agent"