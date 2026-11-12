-- sim_responder.lua —— 仿真器 IMU/里程计桥的应答桩（e2e 守门用，独立进程）
-- bot4cj 仓颉语言机器人框架
--
-- 用法: luajit test/lib/sim_responder.lua <socket路径> <应答帧1> [<应答帧2> ...]
--   例: luajit test/lib/sim_responder.lua /tmp/x.sock "OK 1 2 3 4 0" "OK 5 6 7 8 1"
-- 行为：bind+listen → 循环 accept：每收到一行请求就按序回一帧（轮到数组尾后
-- 循环回第一帧）；对端断开回到 accept 等下一次连接。永不自行退出（由测试
-- 框架 kill）。应答帧里不能用空格分隔的多个参数写成一个 argv 参数（shell 引用）。
--
-- 存在的理由：mybot 真实二进制的 e2e 需要「另一个进程」来应答 imu/odom 桥，
-- 而 GL 壳（mybot-sim）在 CI/无显示环境不可构建——本桩只实现一问一答那几行
-- 协议，与 sim/src/{imu,odom}.cpp 的响应帧格式一致（check_sim_contract 的口径）。

local ffi = require("ffi")
ffi.cdef[[
typedef unsigned short usock_sa_family_t;
struct usock_sockaddr_un { usock_sa_family_t sun_family; char sun_path[108]; };
int socket(int domain, int type, int protocol);
int bind(int fd, const struct usock_sockaddr_un *addr, unsigned int addrlen);
int listen(int fd, int backlog);
int accept(int fd, struct usock_sockaddr_un *addr, unsigned int *addrlen);
long recv(int fd, void *buf, unsigned long len, int flags);
long send(int fd, const void *buf, unsigned long len, int flags);
int close(int fd);
int unlink(const char *path);
]]

local path, responses = arg[1], {}
for i = 2, #arg do
	responses[#responses + 1] = arg[i] .. "\n"
end
if path == nil or #responses == 0 then
	io.stderr:write("sim_responder: usage: <socket> <resp1> [<resp2> ...]\n")
	os.exit(2)
end

local AF_UNIX, SOCK_STREAM = 1, 1

local l = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
local a = ffi.new("struct usock_sockaddr_un")
a.sun_family = AF_UNIX
ffi.copy(a.sun_path, path)
ffi.C.unlink(path)
if ffi.C.bind(l, a, 2 + #path + 1) ~= 0 or ffi.C.listen(l, 8) ~= 0 then
	io.stderr:write("sim_responder: bind/listen failed on " .. path .. "\n")
	os.exit(1)
end

local buf = ffi.new("char[64]")
local idx = 1
while true do
	local c = ffi.C.accept(l, nil, nil)
	if c < 0 then break end
	while true do
		local n = ffi.C.recv(c, buf, 63, 0)
		if n <= 0 then break end	-- EOF / 对端断开：回到 accept
		ffi.C.send(c, responses[idx], #responses[idx], 0)
		idx = idx % #responses + 1
	end
	ffi.C.close(c)
end
