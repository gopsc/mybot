#!/bin/bash
set -e
cd "$(dirname "$0")"
#export cjHeapSize=16MB
# 可复现构建（0.3.2）：cjpm.lock 已入库，仅在锁文件缺失时才 update 拉新——
# 原实现每次构建都 update，依赖版本漂移、历史构建无法复现。
# 升级依赖：手动执行 cjpm update 后连同 cjpm.lock 一起提交。
if [ ! -f cjpm.lock ]; then
	cjpm update
fi
exec cjpm build
