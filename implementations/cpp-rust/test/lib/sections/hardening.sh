# test/lib/sections/hardening.sh —— 守门分段 runner（自 run_all.sh 抽出，F3-1）
#
# 抽取原则（零行为变化）：**只搬函数定义**。用例表、调用循环、记账与汇总
# 全部留在 run_all.sh——`count_calls` 数的是 run_all.sh 里的调用点，
# `$SELF` 孤儿检测也以它为准；这些函数只被 run_all.sh source，不单独执行。
# 它们依赖 run_all.sh 的全局量（$SELF/$bin/$tests_bin/$filter/record_*/用例表），
# 因此**只能在 source 之后调用**，且不要在本文件里读 $1 之类的入口参数。

run_one_hardening() {
        local name="$1" want_rc="$2" expect="$3"; shift 3
        echo "----- $name (hardening) -----"
        if [ ! -x "$bin" ]; then
                # 本段各用例同因（缺 mybot）：只折算一次失败、打印一遍指引
                if [ -z "$hardening_reported" ]; then
                        hardening_reported=1
                        # 条数从本文件的调用点数出来，避免「加用例忘改数字」的消息漂移
                        artifact_missing "输入边界加固" \
                                "$(count_calls run_one_hardening) 条用例" \
                                "$bin" "$bot_explicit"
                fi
                return 2
        fi
        local out rc h_ok
        out="$("$@" 2>&1)"
        rc=$?
        echo "$out" | tail -6
        h_ok=true
        [ "$rc" -ne "$want_rc" ] && h_ok=false
        echo "$out" | grep -qF -- "$expect" || h_ok=false
        if $h_ok; then
                record_pass
        else
                record_fail "$name(hardening)"
        fi
}

run_one_daemon_nack() {
        echo "----- daemon_nack (守护 tick 故障注入) -----"
        if [ ! -x "$bin" ]; then
                artifact_missing "守护 tick 故障注入" "该用例" "$bin" "$bot_explicit"
                return 2
        fi
        mkdir -p .tmp/fixmod
        cat > .tmp/fixmod/NackDrv.lua <<'LUAEOF'
-- 守护 tick 故障注入夹具（run_all.sh 生成）：I2C 最小驱动 + 内嵌 virt 模型。
-- 模型按 virt_tick 拍号切换状态：拍号 < 8 正常应答，>= 8 写/读恒 NACK——
-- 用于 E2E 断言「tick 期总线持续 NACK → 驱动 ERR → 守护不 publish（count 停滞）」。
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua")
dofile(mpath.resolve("lib/drv_common.lua"))

local NACK_AFTER = 8

function build(data)
        local ok, ek = arg_table(data)
        if not ok then return ek end
        return { result = "OK" }
end

function call(data)
        local ok, ek = arg_table(data)
        if not ok then return ek end
        local fd, addr, e2 = i2c_pair(data)
        if fd == nil then return e2 end
        local v = i2c_read_multi(fd, 0x00, 2)
        if v < 0 then
                return { result = "ERR", message = "NACK on measurement read" }
        end
        return { result = "OK", v0 = v }
end

function destroy(data)
        local ok, ek = arg_table(data)
        if not ok then return ek end
        return { result = "OK" }
end

NackDrv_VIRT = {
        new = function()
                local n = -1
                return {
                        -- 守护经 vdev:virt_tick(k) 冒号调用（带 self）；virtbus 的
                        -- dev.write/read 以单参直调（无 self）——签名不可混用
                        virt_tick = function(_, k) n = k end,
                        write = function(_)
                                if n >= NACK_AFTER then return false end
                                return true
                        end,
                        read = function(len)
                                if n >= NACK_AFTER then return nil end
                                local t = {}
                                for i = 1, len do t[i] = (n + 1) % 256 end
                                return t
                        end,
                }
        end,
}
LUAEOF
        cat > .tmp/nack_robot.sql <<'SQLEOF'
CREATE TABLE Timer (
        name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
        name     String,
        chunk    String,
        driver   String,
        proto    String,
        path     String,
        addr     String,
        interval String,
        fields   String
);
INSERT INTO Daemon (name, chunk, driver, proto, path, addr, interval, fields)
  VALUES ('d0', 'lib/sensor_daemon.lua', 'NackDrv', 'virt',
          '/dev/i2c-1', '0x68', '5', 'v0');

/* Monitor 消费守护：mon0.go 每拍调用守护 play()（readSample）——
 * count 快照由此进入输出 JSON，停滞断言才有观测点 */
CREATE TABLE Monitor (
        name String,
        src  String
);
INSERT INTO Monitor (name, src) VALUES ('mon0', '$d0');
SQLEOF
        # ~1.9s 动作（1000ms 预热 + 5×200ms），interval=5ms → 足够多拍越过 NACK 门限。
        # 预热必须盖住守护「启动 + 装载 + build + 首拍」的总时延：慢/忙机器上
        # 该值可到数百 ms 以上（issue #38 实测 200ms 在低配容器必然踩空——
        # Monitor 首读拿空快照 fail-fast 弃管），故给宽裕量。
        printf '@Action\nt0.delay  mon0.go;\n  1000       -    ;\n' > .tmp/nack.mt
        for _ in 1 2 3 4 5; do printf '   200       -    ;\n' >> .tmp/nack.mt; done
        printf '@\n' >> .tmp/nack.mt
        local out rc n_ok count_max count_uniq
        out="$(env BOT4CJ_MODULE_PATH="./modules:.tmp/fixmod" timeout 30 "$bin" \
                --robot=.tmp/nack_robot.sql --input=.tmp/nack.mt 2>&1)"
        rc=$?
        echo "$out"
        n_ok=true
        [ "$rc" -ne 0 ] && n_ok=false
        echo "$out" | grep -qF "VIRTUAL HARDWARE" || n_ok=false
        echo "$out" | grep -qF "tick error" || n_ok=false
        echo "$out" | grep -qF "joined, total publishes=" || n_ok=false
        count_max="$(echo "$out" | grep -oE '"count":[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)"
        # count 停滞：前 8 拍正常发布 → 最大恰为 8（容差 6~10 抗时序抖动）。
        # 「发布过且随后停滞」的确定性证据是 join 行的 total publishes（恰等于
        # 正常拍数）——Monitor 1000ms 预热后才首次读快照，此时早已停滞，
        # 故输出里只有 count:8 一个值，不能用 uniq 断言「多值」。
        publishes="$(echo "$out" | grep -oE 'total publishes=[0-9]+' | grep -oE '[0-9]+' | tail -1)"
        { [ -z "$count_max" ] || [ "$count_max" -lt 6 ] || [ "$count_max" -gt 10 ]; } && n_ok=false
        { [ -z "$publishes" ] || [ "$publishes" -lt 6 ] || [ "$publishes" -gt 10 ]; } && n_ok=false
        if $n_ok; then
                record_pass
        else
                record_fail "daemon_nack(故障注入)"
        fi
}

run_one_fd_probe() {
        echo "----- fd-probe (进程级 fd 泄漏探针) -----"
        if [ ! -x "$bin" ]; then
                artifact_missing "fd 泄漏探针" "该用例" "$bin" "$bot_explicit"
                return 2
        fi
        mkdir -p .tmp
        # 复用 signal 段夹具形态：Timer 长动作 + 无硬件守护（daemon_probe 发布链路）
        cat > .tmp/fdprobe_robot.sql <<'SQLEOF'
CREATE TABLE Timer (
        name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
        name  String,
        chunk String
);
INSERT INTO Daemon (name, chunk) VALUES ('d0', 'lib/daemon_probe.lua');
SQLEOF
        { echo '@Action'; echo 't0.delay;'; for _ in $(seq 1 30); do echo '   200;'; done; echo '@'; } > .tmp/fdprobe.mt

        local fd pid samples n min max rc
        samples="$(
                # 在采样子进程内先清继承 FD，避免启动环境计入泄漏且不影响外层守门。
                for fd in /proc/"$BASHPID"/fd/*; do
                        fd="${fd##*/}"
                        if [ "$fd" -gt 2 ]; then exec {fd}>&-; fi
                done
                "$bin" --robot=.tmp/fdprobe_robot.sql --input=.tmp/fdprobe.mt >/dev/null 2>&1 &
                pid=$!
                for _ in $(seq 1 24); do
                        kill -0 "$pid" 2>/dev/null || break
                        if [ -d "/proc/$pid/fd" ]; then
                                printf ' %s' "$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)"
                        fi
                        sleep 0.25
                done
                wait "$pid"
        )"
        rc=$?
        echo "fd 采样序列:$samples (rc=$rc)"
        min="" ; max=""
        for n in $samples; do
                if [ -z "$min" ] || [ "$n" -lt "$min" ]; then min=$n; fi
                if [ -z "$max" ] || [ "$n" -gt "$max" ]; then max=$n; fi
        done
        if [ "$rc" -eq 0 ] && [ -n "$min" ] && [ -n "$max" ] && [ "$max" -le $((min + 2)) ] && [ "$max" -le 64 ]; then
                record_pass
        else
                record_fail "fd-probe(fd泄漏)"
                echo "[FAIL] fd 计数不平稳或有界性被破坏（min=$min max=$max rc=$rc）"
        fi
}

run_one_signal() {
        local name="$1" want_rc="$2" p1="$3" p2="$4"; shift 4
        echo "----- $name (signal) -----"
        if [ ! -x "$bin" ]; then
                artifact_missing "信号停机" "$(count_calls run_one_signal) 条用例" "$bin" "$bot_explicit"
                return 2
        fi
        local out rc pid watchdog
        out="$("$@" 2>&1 &
                pid=$!
                sleep 1
                kill -TERM "$pid" 2>/dev/null
                # 防挂死看门狗：wait 本身无超时，10s 后 SIGKILL（rc 随之失配 → 判失败），
                # 避免「停机路径回归成死等」把整个守门挂死
                ( sleep 10; kill -KILL "$pid" 2>/dev/null ) &
                watchdog=$!
                wait "$pid" 2>/dev/null
                rc=$?
                kill "$watchdog" 2>/dev/null
                echo "__RC__=$rc")"
        rc="$(printf '%s\n' "$out" | sed -n 's/^__RC__=//p')"
        printf '%s\n' "$out" | sed '/^__RC__=/d' | tail -8
        local s_ok=true
        [ "$rc" != "$want_rc" ] && s_ok=false
        printf '%s\n' "$out" | grep -qF -- "$p1" || s_ok=false
        if [ -n "$p2" ]; then
                printf '%s\n' "$out" | grep -qF -- "$p2" || s_ok=false
        fi
        if $s_ok; then
                record_pass
        else
                record_fail "$name(signal)"
        fi
}

# 审计 C-9 回归夹具：call 返回一张引用自己的表（自引用表转换深度上限）
setup_hardening_cyclic_fixture() {
	mkdir -p .tmp/fixmod
	cat > .tmp/fixmod/CycRet.lua <<'LUAEOF'
-- 审计 C-9 回归夹具：call 返回一张引用自己的表
function build(data) return { result = "OK" } end
function destroy(data) return { result = "OK" } end
function call(data)
	local t = { result = "OK", v0 = 1.5 }
	t.self = t
	return t
end
LUAEOF
	cat > .tmp/fixmod_cyc.sql <<'SQLEOF'
CREATE TABLE CycRet (
	name String
);
INSERT INTO CycRet (name) VALUES ('c0');
SQLEOF
	printf '@Action\nc0.x;\n   1;\n@\n' > .tmp/fixmod_cyc.mt
}

# F5-2 回归夹具：_G 元表 __index 报错（C-API 无保护帧）
setup_hardening_getglobal_fixture() {
	mkdir -p .tmp/fixmod
	cat > .tmp/fixmod/GmtDrv.lua <<'LUAEOF'
-- F5-2 回归夹具：_G 元表 __index 报错。宿主对缺失全局的 getglobal 必须在
-- 受保护帧内（否则裸崩且跳过清理链）。故意只定义 build 不定义 call。
setmetatable(_G, { __index = function(_, k)
	error("boom from __index: " .. tostring(k))
end })

function build(data) return { result = "OK" } end
function destroy(data) return { result = "OK" } end
LUAEOF
	cat > .tmp/fixmod_gmt.sql <<'SQLEOF'
CREATE TABLE GmtDrv (
	name String
);
INSERT INTO GmtDrv (name) VALUES ('h0');
SQLEOF
	printf '@Action\nh0.x;\n   1;\n@\n' > .tmp/fixmod_gmt.mt
}

# N2 回归夹具：上游驱动返回值里混进 mode 键（controller payload 会被带进该键）
setup_hardening_mode_override_fixture() {
	mkdir -p .tmp/fixmod
	cat > .tmp/fixmod/HijUp.lua <<'LUAEOF'
-- 审计 N2 回归夹具：故意在返回值里塞 mode，模拟被带进 controller payload 的键
function build(data) return { result = "OK" } end
function destroy(data) return { result = "OK" } end
function call(data) return { result = "OK", mode = "print", from_up = "yes" } end
LUAEOF
	cat > .tmp/fixmod/HijDown.lua <<'LUAEOF'
function build(data) return { result = "OK" } end
function destroy(data) return { result = "OK" } end
function call(data)
	if data.mode ~= "call" then
		return { result = "ERR", message = "controller dispatch target was overridden: " .. tostring(data.mode) }
	end
	return { result = "OK", down_served = "yes" }
end
LUAEOF
	cat > .tmp/fixmod_hij.sql <<'SQLEOF'
CREATE TABLE HijDown (
	name String
);
INSERT INTO HijDown (name) VALUES ('d0');

CREATE TABLE HijUp (
	name       String,
	controller String
);
INSERT INTO HijUp (name, controller) VALUES ('u0', 'd0');
SQLEOF
	printf '@Action\nu0.x;\n   1;\n@\n' > .tmp/fixmod_hij.mt
}

# N3 回归夹具：call() 漏写 return（返回 0 个值）
setup_hardening_no_return_fixture() {
	mkdir -p .tmp/fixmod
	cat > .tmp/fixmod/NoRet.lua <<'LUAEOF'
-- 审计 N3 回归夹具：call 少写一行 return，等价于返回「无值」
function build(data) return { result = "OK" } end
function destroy(data) return { result = "OK" } end
function call(data)
	local ignored = data.x
end
LUAEOF
	cat > .tmp/fixmod_noret.sql <<'SQLEOF'
CREATE TABLE NoRet (
	name String
);
INSERT INTO NoRet (name) VALUES ('n0');
SQLEOF
	printf '@Action\nn0.x;\n   1;\n@\n' > .tmp/fixmod_noret.mt
}

# F5-4/P1-3 回归夹具：同一物理串口被两个 UART 总线变量独立 open
setup_hardening_uart_shared_fixture() {
	cat > .tmp/uart_two_vars.sql <<'SQLEOF'
CREATE TABLE UART (
	name String,
	path String,
	baud String
);
INSERT INTO UART (name, path, baud) VALUES ('uart-0', '/dev/null', '9600');
INSERT INTO UART (name, path, baud) VALUES ('uart-1', '/dev/null', '115200');
SQLEOF
}

# 审计 #4 回归夹具：只提供 virt 器件模型，故意不定义全局 build/call/destroy
setup_hardening_daemon_build_fixture() {
	mkdir -p .tmp/fixmod
	cat > .tmp/fixmod/leakdrv.lua <<'LUAEOF'
-- 审计 #4 回归夹具：只提供 virt 器件模型，故意不定义全局 build/call/destroy，
-- 复现 @Daemon 的 driver 列误配成「加载成功但没有 build」的模块这一真实坑。
leakdrv_VIRT = { new = function() return {} end }
LUAEOF
	cat > .tmp/fixmod.sql <<'SQLEOF'
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name     String,
	chunk    String,
	driver   String,
	proto    String,
	addr     String,
	interval String,
	fields   String
);
INSERT INTO Daemon (name, chunk, driver, proto, addr, interval, fields)
  VALUES ('ld0', 'lib/sensor_daemon.lua', 'leakdrv', 'virt', '0x68', '10', 'v0');
SQLEOF
	printf '@Action\nt0.delay;\n   200;\n    50;\n    50;\n@\n' > .tmp/fixmod.mt
}

# signal 段夹具：Timer + Daemon 最小结构
setup_hardening_signal_fixture() {
	mkdir -p .tmp
	cat > .tmp/signal_robot.sql <<'SQLEOF'
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');

CREATE TABLE Daemon (
	name  String,
	chunk String
);
INSERT INTO Daemon (name, chunk) VALUES ('d0', 'lib/daemon_probe.lua');
SQLEOF
}

