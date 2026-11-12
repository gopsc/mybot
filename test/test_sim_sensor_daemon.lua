-- test_sim_sensor_daemon.lua —— sim_sensor_daemon.lua 离线单测（独立 lua_State）
--
-- 覆盖面（与 test_sensor_daemon_multi.lua 同法：桩掉宿主注入，本机无真仿真器）：
--   1. kind=imu：一拍发布 5 字段（yaw/gyro/acc/vy/airborne），连接跨拍复用
--   2. 仿真器断开：逐拍错误不发布、count 停滞（错误限频路径不崩）
--   3. 仿真器缺席：同样按逐拍错误处理（不写 status——它是可恢复的环境问题）
--   4. kind=odom：5 字段（x/z/theta/v/odo）
--   5. 帧 ERR 行：不发布假样本
--   6. kind 非法/缺失 → status=-2，tick 空转
--   7. daemon_cleanup 不抛错（Sim.lua destroy 关闭连接 fd）
-- 应答端复用 test_sim.lua 的 fork 子进程法：imu()/odom() 是同步一问一答，
-- 单进程假监听端无法「边等边答」。

local ffi = require("ffi")
local log = print	-- 防御：chunk 不静默 print，但保留还原纪律（multi 测试的教训）

ffi.cdef[[
typedef unsigned short t_sa_family_t;
struct t_sockaddr_un { t_sa_family_t sun_family; char sun_path[108]; };
int setenv(const char *name, const char *value, int overwrite);
int unlink(const char *path);
int socket(int domain, int type, int protocol);
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

local tmp = os.getenv("TMPDIR") or "/tmp"
local d = tmp .. "/bot4cj_simsd_" .. math.floor(os.time() * 1000) % 1000000
os.execute("mkdir -p " .. d .. "/lib")

-- 复制 modules 到临时根（Sim.lua 链：print_table/drv_common/unix_socket_ffi + lib 全量）
os.execute("cp modules/Sim.lua " .. d .. "/Sim.lua")
os.execute("cp modules/lib/*.lua " .. d .. "/lib/")

ffi.C.setenv("BOT4CJ_MODULE_PATH", d, 1)
ffi.C.setenv("MYBOT_SIM_IMU_SOCK", "/tmp/mybot-test-simsd-imu.sock", 1)
ffi.C.setenv("MYBOT_SIM_ODOM_SOCK", "/tmp/mybot-test-simsd-odom.sock", 1)

local realP = dofile("modules/lib/pthread.lua")

local tester = dofile("test/lib/tester.lua")
local check = tester.check

local AF_UNIX, SOCK_STREAM = 1, 1
local F_GETFL, F_SETFL, O_NONBLOCK = 3, 4, 2048
local bit = require("bit")

-- fork 应答子进程：accept 一次 → 循环（recv 请求 → send 应答）→ 退出。
-- responses 是字符串数组（逐拍一帧）；父进程先 bind+listen 消除时序竞态。
local function spawn_responder(sock, responses)
	local l = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
	local a = ffi.new("struct t_sockaddr_un")
	a.sun_family = AF_UNIX
	ffi.copy(a.sun_path, sock)
	ffi.C.unlink(sock)	-- 上一用例残留会让 bind EADDRINUSE
	if ffi.C.bind(l, a, 2 + #sock + 1) ~= 0 or ffi.C.listen(l, 2) ~= 0 then
		ffi.C.close(l)
		return -1
	end
	local pid = ffi.C.fork()
	if pid == 0 then
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
		for _, resp in ipairs(responses) do
			local n = ffi.C.recv(c, buf, 63, 0)
			if n <= 0 then break end
			ffi.C.send(c, resp, #resp, 0)
		end
		ffi.C.close(c)
		ffi.C._exit(0)
	end
	ffi.C.close(l)
	return pid
end

-- 用例运行器：fresh 槽 + fresh chunk 状态（每用例新 dofile；Sim.lua 的 fd 闭包
-- 随之重建，连接不跨用例串扰）。
local function run_case(config)
	local slot = realP.slot_new()
	_G.DAEMON_SLOT_ADDR = tonumber(ffi.cast("uint64_t", slot))
	_G.DAEMON_CONFIG = config
	dofile(d .. "/lib/sim_sensor_daemon.lua")
	print = log
	return realP, slot
end

-- ---- 1. kind=imu：一拍 5 字段 + 连接跨拍复用 ----
local P, slot = run_case("kind=imu")
local pid1 = spawn_responder("/tmp/mybot-test-simsd-imu.sock", {
	"OK -12.5000 0.7500 1.2500 -0.5000 0\n",
	"OK 30.0000 -1.5000 0.0000 0.0000 1\n",
})
check("imu 应答子进程 fork", pid1 >= 0, tostring(pid1))
daemon_tick()
local l1 = P.latest(slot)
check("一拍发布 5 字段", l1 and #l1 == 5, l1 and #l1 or "no publish")
check("imu 帧值逐位（yaw/gyro/acc/vy/airborne）",
	l1 and l1[1] == -12.5 and l1[2] == 0.75 and l1[3] == 1.25 and l1[4] == -0.5 and l1[5] == 0,
	l1 and table.concat(l1, ",") or "nil")
daemon_tick()
local l2 = P.latest(slot)
check("第二拍复用连接取新帧（airborne=1）",
	l2 and l2[1] == 30.0 and l2[5] == 1,
	l2 and table.concat(l2, ",") or "nil")
if pid1 >= 0 then ffi.C.waitpid(pid1, nil, 0) end

-- ---- 2. 仿真器断开：逐拍错误不发布、count 停滞 ----
-- 应答子进程已退出（2 帧答完即关）；第三拍打在死连接上 → EPIPE → 错误路径
local c_before = select(2, P.latest(slot))
daemon_tick()
local _, c_after = P.latest(slot)
check("断开后整拍不发布（count 停滞）", c_after == c_before,
	tostring(c_after) .. " vs " .. tostring(c_before))

-- ---- 3. 仿真器缺席（无监听端）→ 逐拍错误，不写 status ----
ffi.C.unlink("/tmp/mybot-test-simsd-imu.sock")
local P3, slot3 = run_case("kind=imu")
daemon_tick()
check("缺席时 count 停滞（不发布假样本）",
	select(2, P3.latest(slot3)) == 0, tostring(select(2, P3.latest(slot3))))
check("缺席不写 status 失败码（可恢复的环境问题，非永久失败）",
	P3.get_status(slot3) == 0, tostring(P3.get_status(slot3)))

-- ---- 4. kind=odom：5 字段 ----
local P4, slot4 = run_case("kind=odom")
local pid4 = spawn_responder("/tmp/mybot-test-simsd-odom.sock", {
	"OK 1.5000 -2.2500 90.0000 -0.8000 12.7500\n",
})
check("odom 应答子进程 fork", pid4 >= 0, tostring(pid4))
daemon_tick()
local l4 = P4.latest(slot4)
check("odom 一拍 5 字段（x/z/theta/v/odo）",
	l4 and #l4 == 5 and l4[1] == 1.5 and l4[2] == -2.25 and l4[3] == 90.0
		and l4[4] == -0.8 and l4[5] == 12.75,
	l4 and table.concat(l4, ",") or "no publish")
if pid4 >= 0 then ffi.C.waitpid(pid4, nil, 0) end

-- ---- 5. 帧 ERR 行：不发布假样本 ----
local P5, slot5 = run_case("kind=imu")
local pid5 = spawn_responder("/tmp/mybot-test-simsd-imu.sock", { "ERR imu busy\n" })
check("ERR 应答子进程 fork", pid5 >= 0, tostring(pid5))
daemon_tick()
check("ERR 帧整拍不发布（count 停滞）",
	select(2, P5.latest(slot5)) == 0, tostring(select(2, P5.latest(slot5))))
if pid5 >= 0 then ffi.C.waitpid(pid5, nil, 0) end

-- ---- 6. kind 非法/缺失 → status=-2，tick 空转 ----
local P6, slot6 = run_case("kind=immu")
check("kind 非法 → status=-2", P6.get_status(slot6) == -2, tostring(P6.get_status(slot6)))
daemon_tick()	-- fail 后空转：不抛错、不发布
-- fail() 自身 publish({}) 推进一次 count（nvals=0，与 sensor_daemon 同款语义）；
-- 空转的 tick 不得再推进
local l6, c6 = P6.latest(slot6)
check("fail 后 tick 空转（count 停在 fail 推进的 1，无采样值）",
	c6 == 1 and (l6 == nil or #l6 == 0), tostring(c6))

local P6b, slot6b = run_case("")
check("kind 缺失 → status=-2", P6b.get_status(slot6b) == -2, tostring(P6b.get_status(slot6b)))

-- ---- 7. daemon_cleanup 不抛错 ----
local P7, slot7 = run_case("kind=imu")
local okc, errc = pcall(daemon_cleanup)
check("cleanup 不向外抛异常", okc, tostring(errc))

os.execute("rm -rf " .. d)
ffi.C.unlink("/tmp/mybot-test-simsd-imu.sock")
ffi.C.unlink("/tmp/mybot-test-simsd-odom.sock")
tester.summary("test_sim_sensor_daemon.lua")
