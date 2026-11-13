#!/bin/sh
# 无硬件快速验证：Relay 虚拟驱动 + 自检动作脚本。
# 有真实硬件时请直接传 --robot/--input（见 README 快速开始）。
exec ./build/mybot --robot=robots/relay-test.sql --input=scripts/relay-test.mt
