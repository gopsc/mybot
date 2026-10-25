-- test_sim.lua - Sim 仿真桥接驱动守门（modules/Sim.lua）
-- 验证四件事：
--   ① ERR 契约：nil / 缺参 / 非法动作码 / 非法速度都返 ERR 表（不抛错、不静默成功）；
--   ② 仿真器缺席 = 静默成功：socket 没人听时 call 仍返 OK——可视化从端不该绑架
--      动作脚本；
--   ③ 线上协议：本用例自己起一个 AF_UNIX 监听端，逐字核对 Sim.lua 发出来的行
--      （动作名 + 速度 + \n），与 sim/src/bridge.cpp 的解析口径互证；
--   ④ 对端断开后自动重连，destroy 之后再 call 也能重连。
-- 全程无真实硬件；监听端用独立路径，与开发会话里可能开着的真仿真器互不干扰。
dofile("test/lib/tester.lua")
local tester = _G.tester
local ffi = require("ffi")

-- Sim.lua 的 socket 路径读 MYBOT_SIM_SOCK；LuaJIT 没有 os.setenv，经 ffi 设，
-- 指到一条确定没人用的路径。必须在 dofile Sim.lua 之前设好（路径首次 call 时缓存）。
ffi.cdef[[
typedef unsigned short t_sa_family_t;
struct t_sockaddr_un { t_sa_family_t sun_family; char sun_path[108]; };
int setenv(const char *name, const char *value, int overwrite);
int unlink(const char *path);
int bind(int fd, const struct t_sockaddr_un *addr, unsigned int addrlen);
int listen(int fd, int backlog);
int accept(int fd, struct t_sockaddr_un *addr, unsigned int *addrlen);
long recv(int fd, void *buf, unsigned long len, int flags);
long send(int fd, const void *buf, unsigned long len, int flags);
int fcntl(int fd, int cmd, ...);
int fork(void);
void _exit(int status);
int waitpid(int pid, int *status, int options);
int usleep(unsigned int usec);
]]

local TEST_SOCK = "/tmp/mybot-test-sim.sock"
ffi.C.setenv("MYBOT_SIM_SOCK", TEST_SOCK, 1)
ffi.C.unlink(TEST_SOCK)

dofile("modules/Sim.lua")

local function is_err(res)
	return type(res) == "table" and res.result == "ERR" and type(res.message) == "string"
end

local function call_of(data)
	local ok, res = pcall(call, data)
	return ok, res
end

-- ==================== 1. ERR 契约 ====================
do
	local ok, res = pcall(build, nil)
	tester.check("build(nil) 返 ERR 契约（不抛错）", ok and is_err(res), tostring(res))
	local okd, resd = pcall(destroy, nil)
	tester.check("destroy(nil) 返 ERR 契约（不抛错）", okd and is_err(resd), tostring(resd))

	local bad = {
		{ "call(nil)", nil },
		{ "缺 action", {} },
		{ "action 是动作名字符串（矩阵只收 Float64）", { action = "forward" } },
		{ "action 越界上", { action = 11 } },
		{ "action 越界下", { action = -1 } },
		{ "action 非整数", { action = 1.5 } },
		{ "action 是 NaN", { action = 0 / 0 } },
		{ "speed 非数值", { action = 1, speed = "abc" } },
		{ "speed 是 NaN", { action = 1, speed = 0 / 0 } },
		{ "fdist 缺 param", { action = 5 } },
		{ "jump 缺 param", { action = 10 } },
		{ "jump 缺 param2", { action = 10, param = 0.8 } },
		{ "jump param2 非数值", { action = 10, param = 0.8, param2 = "abc" } },
	}
	for _, c in ipairs(bad) do
		local cok, cres = call_of(c[2])
		tester.check(c[1] .. " 返 ERR 契约（不抛错）", cok and is_err(cres),
			cok and tostring(cres and cres.result) or ("raised: " .. tostring(cres)))
	end
end

-- ==================== 2. 仿真器缺席 = 静默成功 ====================
do
	-- TEST_SOCK 此刻没有监听端
	local ok, res = call_of({ action = 1 })
	tester.check("无监听端时 call 静默成功", ok and type(res) == "table" and res.result == "OK",
		tostring(res and res.result))
	local ok2, res2 = call_of({ action = 0, speed = 0.5 })
	tester.check("无监听端时带速度的 call 亦静默成功",
		ok2 and type(res2) == "table" and res2.result == "OK", tostring(res2 and res2.result))
end

-- ==================== 3. 线上协议逐字核对 ====================
local AF_UNIX, SOCK_STREAM = 1, 1
local F_GETFL, F_SETFL, O_NONBLOCK = 3, 4, 2048

local function recv_line(cfd)
	local buf = ffi.new("char[256]")
	local n = ffi.C.recv(cfd, buf, 255, 0)
	if n <= 0 then return nil end
	return ffi.string(buf, n)
end

local lfd = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
tester.check("测试监听端 socket()", lfd >= 0, tostring(lfd))

local addr = ffi.new("struct t_sockaddr_un")
addr.sun_family = AF_UNIX
ffi.copy(addr.sun_path, TEST_SOCK)
-- addrlen = family(2) + 路径字节 + NUL，与 Sim.lua 侧口径一致
tester.check("测试监听端 bind", ffi.C.bind(lfd, addr, 2 + #TEST_SOCK + 1) == 0, "bind 失败")
tester.check("测试监听端 listen", ffi.C.listen(lfd, 4) == 0, "listen 失败")

-- 监听端非阻塞：Sim 没连上来时 accept 返 EAGAIN，用例干净地红而不是挂到超时
local bit = require("bit")
local fl = ffi.C.fcntl(lfd, F_GETFL)
ffi.C.fcntl(lfd, F_SETFL, bit.bor(fl, O_NONBLOCK))

local cfd = -1
do
	local ok, res = call_of({ action = 1, speed = 0.5 })
	tester.check("有监听端时 call 成功", ok and type(res) == "table" and res.result == "OK",
		tostring(res and res.result))
	cfd = ffi.C.accept(lfd, nil, nil)
	tester.check("Sim 连上测试监听端", cfd >= 0, "accept 无连接：Sim 没连上来")
end

if cfd >= 0 then
	local line1 = recv_line(cfd)
	tester.check("首行逐字 = 'forward 0.50\\n'", line1 == "forward 0.50\n", tostring(line1))

	call({ action = 3 })
	local line2 = recv_line(cfd)
	tester.check("速度缺省时不写速度字段 = 'left\\n'", line2 == "left\n", tostring(line2))

	call({ action = 0 })
	local line3 = recv_line(cfd)
	tester.check("stop 行 = 'stop\\n'", line3 == "stop\n", tostring(line3))

	call({ action = 4, speed = 1 })
	local line4 = recv_line(cfd)
	tester.check("满速也走缺省口径 = 'right\\n'", line4 == "right\n", tostring(line4))

	-- fdist/turn/pick/place/save 的线上形态
	call({ action = 5, param = 2.5 })
	local lineP1 = recv_line(cfd)
	tester.check("fdist 行 = 'fdist 2.5000\\n'", lineP1 == "fdist 2.5000\n", tostring(lineP1))

	call({ action = 6, param = -90 })
	local lineP2 = recv_line(cfd)
	tester.check("turn 行 = 'turn -90.0000\\n'", lineP2 == "turn -90.0000\n", tostring(lineP2))

	call({ action = 7 })
	local lineP3 = recv_line(cfd)
	tester.check("pick 行 = 'pick\\n'", lineP3 == "pick\n", tostring(lineP3))

	call({ action = 8 })
	local lineP4 = recv_line(cfd)
	tester.check("place 行 = 'place\\n'", lineP4 == "place\n", tostring(lineP4))

	call({ action = 9 })
	local lineP5 = recv_line(cfd)
	tester.check("save 行 = 'save\\n'", lineP5 == "save\n", tostring(lineP5))

	call({ action = 10, param = 0.8, param2 = 0.35 })
	local lineP6 = recv_line(cfd)
	tester.check("jump 行 = 'jump 0.8000 0.3500\\n'",
		lineP6 == "jump 0.8000 0.3500\n", tostring(lineP6))

	-- ==================== 4. 对端断开后重连 ====================
	ffi.C.close(cfd)
	-- 第一条打在死 fd 上：EPIPE，按「仿真器缺席」口径静默丢弃
	call({ action = 2 })
	-- 第二条重连后才真的发出去
	call({ action = 2 })
	local cfd2 = ffi.C.accept(lfd, nil, nil)
	tester.check("对端断开后自动重连", cfd2 >= 0, "accept 无连接：没重连")
	if cfd2 >= 0 then
		local line5 = recv_line(cfd2)
		tester.check("重连后首行 = 'backward\\n'", line5 == "backward\n", tostring(line5))
		ffi.C.close(cfd2)
	end

	-- destroy 关掉连接后再 call 仍能重连
	local okd, resd = pcall(destroy, {})
	tester.check("destroy() 返 OK", okd and type(resd) == "table" and resd.result == "OK",
		tostring(resd and resd.result))
	call({ action = 4 })
	local cfd3 = ffi.C.accept(lfd, nil, nil)
	tester.check("destroy 后 call 重连", cfd3 >= 0, "accept 无连接：destroy 后没重连")
	if cfd3 >= 0 then
		local line6 = recv_line(cfd3)
		tester.check("destroy 后首行 = 'right\\n'", line6 == "right\n", tostring(line6))
		ffi.C.close(cfd3)
	end
end

ffi.C.close(lfd)
ffi.C.unlink(TEST_SOCK)

-- ==================== 5. IMU / 里程计桥（2026-10-16） ====================
-- imu()/odom() 是同步一问一答（阻塞等应答），单进程假监听端没法「边等边答」
-- （应答必须先于 imu() 返回，而 accept 又只能发生在 imu() 连上来之后）。用
-- fork 起一个应答子进程：父进程先 bind+listen（消除子进程 bind 的时序竞态），
-- 子进程 accept → 读请求行（留档供断言）→ 回一帧 → 退出；子进程 poll 兜底
-- 3s 超时（imu() 连不上来时不会永远挂住父进程的 waitpid）。每个用例
-- dropImuOdom() 强制重连，用例之间无连接状态串扰。
local TEST_IMU_SOCK = "/tmp/mybot-test-sim-imu.sock"
local TEST_ODOM_SOCK = "/tmp/mybot-test-sim-odom.sock"
local IMU_REQLOG = "/tmp/mybot-test-sim-imu-req.log"
local ODOM_REQLOG = "/tmp/mybot-test-sim-odom-req.log"
ffi.C.setenv("MYBOT_SIM_IMU_SOCK", TEST_IMU_SOCK, 1)
ffi.C.setenv("MYBOT_SIM_ODOM_SOCK", TEST_ODOM_SOCK, 1)
ffi.C.unlink(TEST_IMU_SOCK)
ffi.C.unlink(TEST_ODOM_SOCK)

local function spawn_responder(sock, resp, reqlog)
	local l = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
	local a = ffi.new("struct t_sockaddr_un")
	a.sun_family = AF_UNIX
	ffi.copy(a.sun_path, sock)
	ffi.C.unlink(sock)  -- 上一用例残留的 socket 文件会让 bind EADDRINUSE
	if ffi.C.bind(l, a, 2 + #sock + 1) ~= 0 or ffi.C.listen(l, 2) ~= 0 then
		ffi.C.close(l)
		return -1
	end
	local pid = ffi.C.fork()
	if pid == 0 then
		-- 子进程：等连接（非阻塞 accept 轮询，3s 兜底）→ 收请求 → 留档 →
		-- 应答 → 退出。不 cdef poll：cj_pollfd/poll 已被 Sim.lua 声明，
		-- 结构体重复声明在 LuaJIT 是硬错误；usleep 无冲突。
		local fl = ffi.C.fcntl(l, F_GETFL)
		ffi.C.fcntl(l, F_SETFL, bit.bor(fl, O_NONBLOCK))
		local c = -1
		for _ = 1, 300 do
			c = ffi.C.accept(l, nil, nil)
			if c >= 0 then break end
			ffi.C.usleep(10000)
		end
		if c < 0 then ffi.C._exit(1) end
		local buf = ffi.new("char[64]")
		local n = ffi.C.recv(c, buf, 63, 0)
		if reqlog then
			local f = io.open(reqlog, "w")
			if f then f:write(ffi.string(buf, n)); f:close() end
		end
		if n > 0 then ffi.C.send(c, resp, #resp, 0) end
		ffi.C.close(c)
		ffi.C._exit(0)
	end
	ffi.C.close(l)  -- 父进程不再持有监听端
	return pid
end

local function reap(pid)
	if pid >= 0 then ffi.C.waitpid(pid, nil, 0) end
end

-- dropImuOdom/dropSensor 在 Sim.lua 里是模块局部（文件头的前向声明），测试侧
-- 不可见；关连接走既有生命周期 destroy()（关全部 fd，下一拍自动重连）。
local function reset_conns()
	pcall(destroy, {})
end

local function read_reqlog(path)
	local f = io.open(path, "r")
	local body = f and f:read("*a") or nil
	if f then f:close() end
	return body
end

-- 缺席 = ERR（与 call 的静默成功刻意不同）
reset_conns()
local okI0, rI0 = pcall(imu)
tester.check("无监听端时 imu 返 ERR（感知动作不静默造假）", okI0 and is_err(rI0),
	tostring(rI0 and rI0.result))

-- 正常帧解析 + 请求行核对
reset_conns()
ffi.C.unlink(IMU_REQLOG)
local pidI1 = spawn_responder(TEST_IMU_SOCK, "OK -12.5000 0.7500 1.2500 -0.5000 0\n", IMU_REQLOG)
tester.check("imu 应答子进程 fork", pidI1 >= 0, tostring(pidI1))
local okI1, rI1 = pcall(imu)
tester.check("有监听端时 imu 成功", okI1 and type(rI1) == "table" and rI1.result == "OK",
	tostring(rI1 and rI1.result))
tester.check("imu 帧解析（yaw/gyro/acc/vy/airborne）",
	type(rI1) == "table" and rI1.result == "OK" and rI1.yaw_deg == -12.5
		and rI1.gyro_z == 0.75 and rI1.acc_fwd == 1.25 and rI1.vy == -0.5
		and rI1.airborne == 0,
	tostring(rI1 and rI1.result))
reap(pidI1)
tester.check("imu 请求行 = 'imu\n'", read_reqlog(IMU_REQLOG) == "imu\n",
	tostring(read_reqlog(IMU_REQLOG)))

-- ERR 行透传
reset_conns()
local pidI2 = spawn_responder(TEST_IMU_SOCK, "ERR imu busy\n", nil)
reap_placeholder = nil
local _, fr2 = pcall(imu)
tester.check("imu 的 ERR 行透传为 ERR 契约",
	type(fr2) == "table" and fr2.result == "ERR" and fr2.message == "imu busy",
	tostring(fr2 and fr2.message))
reap(pidI2)

-- 畸形 OK 行
reset_conns()
local pidI3 = spawn_responder(TEST_IMU_SOCK, "OK justwords\n", nil)
local _, fr3 = pcall(imu)
tester.check("imu 畸形 OK 行 → ERR", type(fr3) == "table" and fr3.result == "ERR",
	tostring(fr3 and fr3.result))
reap(pidI3)
ffi.C.unlink(TEST_IMU_SOCK)

-- 里程计：正常帧 + 请求行 + ERR 透传
reset_conns()
ffi.C.unlink(ODOM_REQLOG)
local pidO1 = spawn_responder(TEST_ODOM_SOCK, "OK 1.5000 -2.2500 90.0000 -0.8000 12.7500\n", ODOM_REQLOG)
tester.check("odom 应答子进程 fork", pidO1 >= 0, tostring(pidO1))
local okO1, rO1 = pcall(odom)
tester.check("有监听端时 odom 成功", okO1 and type(rO1) == "table" and rO1.result == "OK",
	tostring(rO1 and rO1.result))
tester.check("odom 帧解析（x/z/theta/v/odo）",
	type(rO1) == "table" and rO1.result == "OK" and rO1.x == 1.5 and rO1.z == -2.25
		and rO1.theta_deg == 90.0 and rO1.v == -0.8 and rO1.odo == 12.75,
	tostring(rO1 and rO1.result))
reap(pidO1)
tester.check("odom 请求行 = 'odom\n'", read_reqlog(ODOM_REQLOG) == "odom\n",
	tostring(read_reqlog(ODOM_REQLOG)))

reset_conns()
local pidO2 = spawn_responder(TEST_ODOM_SOCK, "ERR odom offline\n", nil)
local _, frO2 = pcall(odom)
tester.check("odom 的 ERR 行透传为 ERR 契约",
	type(frO2) == "table" and frO2.result == "ERR" and frO2.message == "odom offline",
	tostring(frO2 and frO2.message))
reap(pidO2)
ffi.C.unlink(TEST_ODOM_SOCK)

tester.summary("Sim 仿真桥接驱动")
