-- P1 冒烟：从 SD 加载 mybot 的真实 Relay 驱动。
-- C 侧随后调用 build/call/destroy，参数固定为 test=200,note=hello。
print("P1: loading /modules/Relay.lua")
dofile("/modules/Relay.lua")
