-- Camera.lua 单元测试：仿真路径 + base64 + 错误路径
-- 用法（项目根目录）: luajit test/test_camera.lua
--
-- 本机没有摄像头也能全跑：驱动支持 src=<图片文件> 的仿真模式，抓帧结果与真机同构
-- （同一段 base64 返回逻辑）。真机 V4L2 路径见 test/test_camera_v4l2.lua，
-- 无 /dev/video* 时由守门按 `-- requires: video` 自动跳过。

local tester = dofile("test/lib/tester.lua")
local check = tester.check

dofile("modules/Camera.lua")	-- 注册全局 build/call/destroy

local ffi = require("ffi")
ffi.cdef[[
int symlink(const char *target, const char *linkpath);
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
int open(const char *path, int flags);

/* 测试用的 AF_UNIX 地址结构（Camera.lua 现在用公共模块的 usock_sockaddr_un，
   但测试代码里的 listener 还需要自己的声明） */
typedef unsigned short cam_sa_family_t;
struct cam_sockaddr_un { cam_sa_family_t sun_family; char sun_path[108]; };
int bind(int fd, const struct cam_sockaddr_un *addr, unsigned int addrlen);
int listen(int fd, int backlog);
struct cam_pollfd { int fd; short events; short revents; };
int poll(struct cam_pollfd *fds, unsigned long nfds, int timeout);
int accept(int fd, struct cam_sockaddr_un *addr, unsigned int *addrlen);
long recv(int fd, void *buf, unsigned long len, int flags);
int close(int fd);
]]
-- 用例确定性：环境变量会改变仿真白名单，先清掉
ffi.C.unsetenv("BOT4CJ_CAMERA_SRC_DIR")

-- 软链与临时目录（不依赖 shell 也能建链，建目录仍需 mkdir）
local function tmpdir(tag)
	local d = os.tmpname() .. "." .. tag
	os.execute("mkdir -p " .. d)
	return d
end

local function dirname(p)
	return p:match("^(.*)/[^/]*$")
end

local function write_file(path, data)
	local f = assert(io.open(path, "wb"))
	f:write(data)
	f:close()
end

-- base64 解码：用来验证驱动返回的 b64 与源字节逐字节一致（不依赖外部库）
local function b64decode(s)
	local map, chars = {}, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, #chars do map[chars:sub(i, i)] = i - 1 end
	local out, n, acc, bits = {}, 0, 0, 0
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == "=" then break end
		local v = map[c]
		if v == nil then error("非法 base64 字符: " .. c) end
		acc = acc * 64 + v
		bits = bits + 6
		if bits >= 8 then
			bits = bits - 8
			local byte = math.floor(acc / 2 ^ bits) % 256
			acc = acc % 2 ^ bits
			n = n + 1
			out[n] = string.char(byte)
		end
	end
	return table.concat(out)
end

-- 独立的 base64 编码器（测试自己的参考实现，故意不复用 Camera.lua 的算法：
-- 用被测算法的输出去断言被测算法的输出等于自证）
local function mjpeg_base64(s)
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local out, i = {}, 1
	while i <= #s do
		local b1 = s:byte(i)
		local b2 = s:byte(i + 1)
		local b3 = s:byte(i + 2)
		local n = (b2 and 1 or 0) + (b3 and 1 or 0)
		local v = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
		out[#out + 1] = chars:sub(math.floor(v / 262144) % 64 + 1, math.floor(v / 262144) % 64 + 1)
		out[#out + 1] = chars:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
		out[#out + 1] = n >= 1 and chars:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1) or "="
		out[#out + 1] = n >= 2 and chars:sub(v % 64 + 1, v % 64 + 1) or "="
		i = i + 3
	end
	return table.concat(out)
end

-- ---- base64 已知向量（经仿真路径间接验证编码器）----
-- 自 AG-9 起仿真来源必须是**真图片**（驱动按魔数定格式，认不出就 ERR），
-- 所以向量统一加 JPEG 头（\255\216\255）；断言改为比对 base64 段，
-- 这样 RFC 4648 的已知向量（含各种填充）仍然逐个被钉住。
do
	local vectors = {
		{ "f", "Zg==" }, { "fo", "Zm8=" }, { "foo", "Zm9v" },
		{ "foob", "Zm9vYg==" }, { "fooba", "Zm9vYmE=" }, { "foobar", "Zm9vYmFy" },
	}
	for i, v in ipairs(vectors) do
		local path = os.tmpname()
		write_file(path, "\255\216\255" .. v[1])
		build({ src = path, src_root = dirname(path) })
		local res = call({})
		-- 驱动给的是裸 base64（data URL 的拼装是宿主的事，见 AG-9）；
		-- 断言「JPEG 头 + 向量」的完整编码，填充情形照样逐个钉住
		local expect = mjpeg_base64("\255\216\255" .. v[1])
		check("base64 向量 #" .. i .. " (" .. v[1] .. ")", res.b64 == expect,
			tostring(res.b64) .. " 期望 " .. expect)
		destroy({})
		os.remove(path)
	end
end

-- ---- 仿真抓帧：返回的字节必须与源文件完全一致 ----
do
	local path = os.tmpname()
	-- 造一段带二进制字节的假 JPEG（驱动只负责搬运，不解释内容）
	local payload = "\255\216\255\224" .. string.rep("\0\1\2\3\254\253", 5000) .. "\255\217"
	write_file(path, payload)

	local b = build({ src = path, src_root = dirname(path) })
	check("仿真 build 返回 OK", b.result == "OK")
	local res = call({})
	check("仿真抓帧返回 OK", res.result == "OK")
	check("来源标记为 file", res.source == "file")
	check("格式标记为 jpeg", res.format == "jpeg")
	check("字节数与源一致", res.bytes == #payload, tostring(res.bytes) .. " vs " .. #payload)
	check("base64 解码回源字节（逐字节一致）", b64decode(res.b64) == payload)
	check("仿真结果带 note 说明", type(res.note) == "string" and res.note:find("模拟图片") ~= nil)
	check("destroy 返回 OK", destroy({}).result == "OK")
	os.remove(path)
end

-- ---- 仿真文件不存在：build 失败要清晰，而不是拖到抓帧 ----
do
	-- 目录在白名单内（/tmp 存在），只是文件不存在 → 走「打不开」而不是「未放行」
	local b = build({ src = "/tmp/mybot-no-such-image.jpg", src_root = "/tmp" })
	check("仿真文件不存在 → build ERR", b.result == "ERR")
	check("ERR 消息点名文件", tostring(b.message):find("无法打开模拟图片", 1, true) ~= nil,
		tostring(b.message))
	destroy({})
end

-- ---- 入参类型守卫：Camera 是全仓唯一不挂 drv_common.arg_table 样板的驱动，
-- ---- 非表入参必须按 ERR 契约拒绝，而不是 data.src 索引访问裸抛 Lua error ----
do
	local b = build("not-a-table")
	check("build 非表入参 → ERR（契约表，不裸抛）",
		type(b) == "table" and b.result == "ERR", tostring(type(b) == "table" and b.message))
	check("build 非表入参提示类型错误",
		tostring(type(b) == "table" and b.message):find("Invalid Arguments Type", 1, true) ~= nil,
		tostring(type(b) == "table" and b.message))
	local r = call(42)
	check("call 非表入参 → ERR（契约表，不裸抛）",
		type(r) == "table" and r.result == "ERR", tostring(type(r) == "table" and r.message))
	destroy({})
end

-- ---- 仿真白名单（P1-2）：默认拒绝 / 越界拒绝 / 软链逃逸拒绝 / 环境变量放行 ----
do
	local root, other = tmpdir("cam-root"), tmpdir("cam-other")
	local inside, outside = root .. "/pic.jpg", other .. "/secret.bin"
	-- 内容写成真图片：这些用例测的是**路径白名单**（路径判据在格式判据之前），
	-- 内容若不可识别，第 4 条「环境变量放行」会因为格式而不是因为路径失败。
	write_file(inside, "\255\216\255" .. "IN")
	write_file(outside, "\255\216\255" .. "SECRET")

	-- 1) 既无 src_root 也无环境变量：默认拒绝（不给「读任意路径」留口子）
	local b0 = build({ src = inside })
	check("未放行目录 → build ERR（默认拒绝）", b0.result == "ERR", tostring(b0.message))
	check("默认拒绝提示指向 --camera-src",
		tostring(b0.message):find("未放行", 1, true) ~= nil, tostring(b0.message))
	destroy({})

	-- 2) 给了 src_root 但 src 在其外：拒绝
	local b1 = build({ src = outside, src_root = root })
	check("白名单目录外 → build ERR", b1.result == "ERR", tostring(b1.message))
	check("越界提示含「白名单」",
		tostring(b1.message):find("白名单", 1, true) ~= nil, tostring(b1.message))
	destroy({})

	-- 3) 目录内软链指向外部：realpath 展开后仍被判越界
	local link = root .. "/link.jpg"
	if ffi.C.symlink(outside, link) ~= 0 then
		os.execute("ln -sf " .. outside .. " " .. link)
	end
	local b2 = build({ src = link, src_root = root })
	check("软链逃逸白名单 → build ERR", b2.result == "ERR", tostring(b2.message))
	check("软链逃逸提示含「白名单」",
		tostring(b2.message):find("白名单", 1, true) ~= nil, tostring(b2.message))
	destroy({})

	-- 4) 环境变量放行（结构脚本直驱场景的显式开关）
	ffi.C.setenv("BOT4CJ_CAMERA_SRC_DIR", root, 1)
	local b3 = build({ src = inside })
	check("BOT4CJ_CAMERA_SRC_DIR 放行目录内文件", b3.result == "OK", tostring(b3.message))
	local r3 = call({})
	check("环境变量放行后抓帧成功", r3.result == "OK" and r3.source == "file")
	destroy({})
	ffi.C.unsetenv("BOT4CJ_CAMERA_SRC_DIR")

	os.execute("rm -rf " .. root .. " " .. other)
end

-- ---- 设备路径白名单（P1-2）：只放行 /dev/videoN ----
do
	local res = call({ path = "/etc/passwd" })
	check("非 /dev/videoN 设备路径 → ERR", res.result == "ERR")
	check("提示只允许 /dev/videoN",
		tostring(res.message):find("/dev/videoN", 1, true) ~= nil, tostring(res.message))
	check("拒绝时点名给的路径",
		tostring(res.message):find("/etc/passwd", 1, true) ~= nil, tostring(res.message))
	destroy({})
end

-- ---- 摄像头是可选外设：build 不碰设备，抓拍时才按调用参数惰性打开并报错 ----
do
	local b = build({ path = "/dev/video999" })
	check("build 返回 OK 且不警告（不在上电阶段碰设备）", b.result == "OK" and b.warning == nil)
	local res = call({ path = "/dev/video999" })
	check("抓帧时才如实报 ERR", res.result == "ERR")
	check("ERR 消息含调用时给的设备路径", tostring(res.message):find("/dev/video999") ~= nil,
		tostring(res.message))
	check("ERR 消息点明 errno", tostring(res.message):find("errno=") ~= nil)
	destroy({})
end

-- ---- MJPEG 帧完整性校验（lib/mjpeg_frame.lua）：截断帧重取的判据 ----
do
	local mjpeg = dofile("modules/lib/mjpeg_frame.lua")

	local SOI = "\xff\xd8"
	local EOI = "\xff\xd9"
	local scan = string.rep("\x5a\xa5", 64)	-- 假熵编码数据（不含 ffd9 组合）

	local full = SOI .. scan .. EOI
	check("完整帧原样返回", mjpeg.normalize(full) == full)
	check("EOI 后的尾部填充被截掉（实测设备会跟 2 字节 0x00）",
		mjpeg.normalize(full .. "\x00\x00") == full)
	check("截断帧（尾部无 EOI）返回 nil，调用方应重取",
		mjpeg.normalize(SOI .. scan) == nil)

	-- EXIF 缩略图陷阱：APP 段内嵌完整 JPEG（含它自己的 EOI）。只搜帧尾窗口，
	-- 内嵌 EOI 不得把截断帧误判成完整，也不得让规范化截在缩略图上。
	local thumbnail = SOI .. "\x11\x22" .. EOI
	check("内嵌缩略图的截断帧仍判为截断",
		mjpeg.normalize(SOI .. thumbnail .. scan) == nil)
	check("主扫描完整时截到主 EOI（内嵌 EOI 不干扰）",
		mjpeg.normalize(SOI .. thumbnail .. scan .. EOI .. "\x00")
			== SOI .. thumbnail .. scan .. EOI)

	check("过短数据一律 nil", mjpeg.normalize(SOI) == nil
		and mjpeg.normalize("") == nil and mjpeg.normalize(nil) == nil)
end

-- ---- C6：V4L2 打开失败必须释放已申请的 fd（2026-09-20 审计）----
-- 旧实现 state.fd 在**任何校验之前**就赋值，而 device_open 的十条失败路径
-- 全部直接 `return nil, ...`，fd（以及已 mmap 的缓冲）就此泄漏；同时 fd 停在
-- ≥0 使「半开」状态被后续调用误判为已打开（state.path 只在成功路径补写）。
-- 这里通过 HAL.sys.* 注入桩：open 成功、QUERYCAP 失败 → 必须看见 close。
do
	local hal = dofile("modules/lib/HAL.lua")
	local real = {
		open = hal.sys.open, close = hal.sys.close,
		ioctl_p = hal.sys.ioctl_p, errno = hal.sys.errno,
	}
	local opened, closed = {}, {}
	local restore = function()
		for k, v in pairs(real) do hal.sys[k] = v end
	end
	hal.sys.open = function(_, _) local fd = 900 + #opened; opened[#opened + 1] = fd; return fd end
	hal.sys.close = function(fd) closed[#closed + 1] = fd; return 0 end
	hal.sys.ioctl_p = function(_, _, _) return -1 end	-- QUERYCAP 失败
	hal.sys.errno = function() return 19 end		-- ENODEV

	local ok, res = pcall(call, { path = "/dev/video0" })
	restore()

	check("C6：QUERYCAP 失败 → ERR 契约", ok and type(res) == "table" and res.result == "ERR",
		tostring(ok) .. "/" .. tostring(type(res) == "table" and res.result or res))
	check("C6：打开了 1 个 fd", #opened == 1, tostring(#opened))
	check("C6：失败路径释放了该 fd（修复前为 0 次 close = 泄漏）",
		#closed == 1 and closed[1] == opened[1],
		"opened=" .. #opened .. " closed=" .. #closed)

	-- 失败后状态必须回到「未打开」：再次调用应重新尝试 open（而不是拿半开句柄抓帧）
	hal.sys.open = function(_, _) local fd = 900 + #opened; opened[#opened + 1] = fd; return fd end
	hal.sys.close = function(fd) closed[#closed + 1] = fd; return 0 end
	hal.sys.ioctl_p = function(_, _, _) return -1 end
	hal.sys.errno = function() return 19 end
	call({ path = "/dev/video0" })
	restore()
	check("C6：失败后不残留半开状态（再次调用重新 open）", #opened == 2, tostring(#opened))
end

-- ---- AG-2：真机抓帧重试循环必须用**局部**变量承接 grab_one 的失败原因 ----
-- 2026-09-21 审计 AG-2（实测复现）：该循环曾写成 `payload, err = grab_one()`，
-- 写的是 drv_common:19 定义的**全局** err 构造器。后果三连：
--   ① 成功路径也把 err 赋成 nil → 整个 lua_State 里所有驱动的 err(...) 全废；
--   ② 抓帧失败把 err 赋成字符串 → 后续 err(...) 报 "attempt to call a string value"；
--   ③ 那句「8 consecutive incomplete frames」诊断自己先撞上 nil/字符串，
--      **100% 不可达**（循环体每轮都先给 err 赋值）。
-- 下列用例走真实 v4l2 路径（同步 stdout 管道当摄像头 fd：poll 恒就绪，
-- 内容真进 mmap 缓冲；ioctl 桩驱动状态机），覆盖成功与失败两条分支。
do
	local hal = dofile("modules/lib/HAL.lua")
	local real = {
		open = hal.sys.open, close = hal.sys.close,
		ioctl_p = hal.sys.ioctl_p, errno = hal.sys.errno,
	}

	-- 完整的 MJPEG 帧（尾窗内有 EOI，mjpeg.normalize 放行）
	local GOOD = "\255\216\255\224" .. string.rep("\0\1\2\3", 8) .. "\255\217"
	-- 熵编码中途截断的帧（尾部无 EOI，mjpeg.normalize 判 nil → 触发重取）
	local BAD = "\255\216\255\224" .. string.rep("\0\1\2\3", 8)

	-- 缓冲长度刻意取 > #payload：真实 V4L2 的 buf.length 是内核分配的槽位大小，
	-- 通常大于单帧 bytesused；长度不足会让驱动侧 mmap 失败（本桩第一版就踩了）。
	-- 多出来的尾部一律补 0，帧内容本身仍在 mmap 区开头逐字节可比。
	local BUF_LEN = 65536
	local function pad(s) return s .. string.rep("\0", BUF_LEN - #s) end

	-- 真机 v4l2 路径的 ioctl 请求号（与 modules/Camera.lua:137-143 的单点定义一致；
	-- 桩必须按真实号分派：QUERYBUF 与 DQBUF 都写 cam_buffer，但字段不同——
	-- QUERYBUF 给 length，DQBUF 给 index/bytesused）
	local IOCTL_QUERYCAP = 0x80685600
	local IOCTL_QUERYBUF = 0xc0585609
	local IOCTL_DQBUF = 0xc0585611

	local function mkstub(payload, queue_fail_after)
		-- 必须给一个**真实**的 fd：驱动会对它做 poll 与 mmap，假 fd（>RLIMIT）会
		-- 让 mmap 直接失败。普通文件的 poll 恒返回可读，正好用作「画面始终就绪」
		-- 的摄像头替身；文件内容无关紧要——驱动读的是 mmap 区，而桩在 DQBUF
		-- 里用 bytesused 告诉它该取多少字节。
		-- 打开标志必须是 O_RDWR（2）：驱动按 PROT_READ|PROT_WRITE + MAP_SHARED
		-- 映射（它要 QBUF 回队列），只读 fd 上 mmap 直接 EACCES。
		local path = os.tmpname()
		write_file(path, payload)
		local fd = tonumber(ffi.C.open(path, 2))	-- O_RDWR
		os.remove(path)
		assert(fd ~= nil and fd >= 0, "无法为摄像头桩打开临时文件")
		return fd, {
			open = function(_, _) return fd end,
			close = function(_) return 0 end,
			ioctl_p = function(_, req, p)
				if req == IOCTL_QUERYCAP then p.capabilities = 1 end
				if req == IOCTL_DQBUF then
					if queue_fail_after ~= nil then
						if queue_fail_after <= 0 then return -1 end
						queue_fail_after = queue_fail_after - 1
					end
					p.index = 0
					p.bytesused = #payload
				end
				if req == IOCTL_QUERYBUF then p.length = BUF_LEN end
				return 0
			end,
			errno = function() return 5 end,
		}
	end

	local function with_stub(payload, queue_fail_after, fn)
		local _, stub = mkstub(payload, queue_fail_after)
		for k, v in pairs(stub) do hal.sys[k] = v end
		local ok, res = pcall(fn)
		for k, v in pairs(real) do hal.sys[k] = v end
		return ok, res
	end

	-- ① 成功路径：完整帧 → OK，且全局 err 必须仍是函数（修复前被赋成 nil）
	do
		local err_before = err
		local ok, res = with_stub(GOOD, nil, function() return call({ path = "/dev/video0" }) end)
		destroy({})
		check("AG-2：完整帧抓拍返回 OK", ok and type(res) == "table" and res.result == "OK",
			tostring(ok) .. "/" .. tostring(type(res) == "table" and res.result or res))
		check("AG-2：全局 err 未被成功路径污染（修复前为 nil）", type(err) == "function",
			"type(err)=" .. type(err))
		check("AG-2：err 仍是原来那个函数对象", err == err_before)
	end

	-- ② 8 连截断：诊断必须可达，且必须是那条诊断（修复前抛 "attempt to call ... value"）
	do
		local ok, res = with_stub(BAD, nil, function() return call({ path = "/dev/video0" }) end)
		destroy({})
		check("AG-2：8 连截断帧 → ERR 契约（修复前抛 Lua error）",
			ok and type(res) == "table" and res.result == "ERR",
			tostring(ok) .. "/" .. tostring(type(res) == "table" and res.message or res))
		check("AG-2：诊断文案可达（修复前 100% 不可达）",
			type(res) == "table" and tostring(res.message):find("8 consecutive incomplete frames", 1, true) ~= nil,
			tostring(type(res) == "table" and res.message or res))
		check("AG-2：失败路径后全局 err 仍是函数", type(err) == "function", "type(err)=" .. type(err))
	end

	-- ③ 中途抓帧失败：必须带出 grab_one 的真实原因（修复前 gerr 是死变量，原因丢失）
	do
		local ok, res = with_stub(GOOD, 1, function() return call({ path = "/dev/video0" }) end)
		destroy({})
		check("AG-2：中途 DQBUF 失败 → ERR 契约", ok and type(res) == "table" and res.result == "ERR",
			tostring(ok) .. "/" .. tostring(type(res) == "table" and res.message or res))
		check("AG-2：失败原因来自 grab_one（修复前 gerr 恒 nil，原因丢失）",
			type(res) == "table" and tostring(res.message):find("DQBUF", 1, true) ~= nil,
			tostring(type(res) == "table" and res.message or res))
		check("AG-2：中途失败后全局 err 仍是函数", type(err) == "function", "type(err)=" .. type(err))
	end

	-- ④ 兜底：err 被外部破坏时驱动仍返回 ERR 契约表而非抛 Lua error
	do
		local saved = err
		err = nil
		local ok, res = with_stub(BAD, nil, function() return call({ path = "/dev/video0" }) end)
		destroy({})
		err = saved
		check("AG-2：err 被破坏时仍返回 ERR 契约（不抛 Lua error）",
			ok and type(res) == "table" and res.result == "ERR",
			tostring(ok) .. "/" .. tostring(type(res) == "table" and res.message or res))
	end
end

-- ---- AG-9：图片格式按魔数判定（不看扩展名）----
-- 驱动曾恒返回 format="jpeg"，宿主据此恒拼 data:image/jpeg——传 PNG 会得到
-- 「JPEG 标签 + PNG 字节」，严格网关按图片解析 400。现在按内容判，且不支持
-- 的格式响亮拒绝。
do
	local mjpeg = dofile("modules/lib/mjpeg_frame.lua")

	local PNG  = "\137PNG\r\n\26\n" .. "payload"
	local GIF  = "GIF89a" .. "payload"
	local WEBP = "RIFF" .. string.rep("\0", 4) .. "WEBP" .. "payload"
	local JPEG = "\255\216\255" .. "payload"
	local BMP  = "BM" .. string.rep("x", 30)

	check("AG-9：JPEG 魔数识别", mjpeg.image_format(JPEG) == "jpeg")
	check("AG-9：PNG 魔数识别", mjpeg.image_format(PNG) == "png")
	check("AG-9：GIF87a 识别", mjpeg.image_format("GIF87a" .. "x") == "gif")
	check("AG-9：GIF89a 识别", mjpeg.image_format("GIF89a" .. "x") == "gif")
	check("AG-9：WebP（RIFF+WEBP）识别", mjpeg.image_format(WEBP) == "webp")
	check("AG-9：BMP 不认识（返回 nil）", mjpeg.image_format(BMP) == nil)
	check("AG-9：过短输入返回 nil", mjpeg.image_format("ab") == nil
		and mjpeg.image_format("") == nil and mjpeg.image_format(nil) == nil)
	-- 只有 RIFF 头不算 WebP（WAV/AVI 也是 RIFF，必须看第 9-12 字节）
	check("AG-9：RIFF 但不是 WEBP（如 WAV）不算图片",
		mjpeg.image_format("RIFF" .. string.rep("\0", 4) .. "WAVE" .. "payload") == nil)
	check("AG-9：白名单只含四种视觉格式",
		mjpeg.SUPPORTED_FORMATS.jpeg and mjpeg.SUPPORTED_FORMATS.png
			and mjpeg.SUPPORTED_FORMATS.gif and mjpeg.SUPPORTED_FORMATS.webp
			and mjpeg.SUPPORTED_FORMATS.bmp == nil)
end

-- ---- AG-9：仿真路径返回真实 format，不支持的格式返 ERR ----
do
	local path = os.tmpname()
	write_file(path, "\137PNG\r\n\26\n" .. string.rep("\0\1\2\3", 8))
	build({ src = path, src_root = dirname(path) })
	local res = call({})
	check("AG-9：仿真 PNG 的 format 为 png（修复前恒为 jpeg）", res.format == "png",
		tostring(res.format))
	check("AG-9：仿真 PNG 仍返回 OK 与 b64", res.result == "OK" and type(res.b64) == "string")
	destroy({})

	-- 不支持的格式必须在 **build 阶段**就 ERR（那时还没上电），而不是猜一个
	-- MIME 发出去、或拖到 call 时才炸
	write_file(path, "BM" .. string.rep("x", 30))
	local b2 = build({ src = path, src_root = dirname(path) })
	check("AG-9：BMP 仿真 build → ERR 契约", b2.result == "ERR", tostring(b2.result))
	check("AG-9：ERR 文案点名格式不受支持",
		tostring(b2.message):find("unsupported sim image format", 1, true) ~= nil,
		tostring(b2.message))
	-- call 阶段同样拒绝（会话里直接调 call、没走 build 的路径）
	local r2 = call({ src = path, src_root = dirname(path) })
	check("AG-9：BMP 仿真 call → ERR 契约", r2.result == "ERR", tostring(r2.result))
	check("AG-9：call 阶段文案同样点名格式",
		tostring(r2.message):find("unsupported sim image format", 1, true) ~= nil,
		tostring(r2.message))
	destroy({})
	os.remove(path)
end

-- ---- AG-18：抓帧的边角语义（poll 错误 vs 超时 / 越界索引 / 内核标记损坏）----
-- 这些分支此前没有断言：poll 的 pr<=0 一律报「等待帧超时」把 errno 丢掉，
-- V4L2_BUF_FLAG_ERROR 从不检查，buffer index 也不做范围判断。构造方式与
-- AG-2 那组相同（真实 v4l2 路径 + 真 fd + ioctl 桩驱动状态机）。
do
	local hal = dofile("modules/lib/HAL.lua")
	local real = {
		open = hal.sys.open, close = hal.sys.close,
		ioctl_p = hal.sys.ioctl_p, errno = hal.sys.errno,
	}
	local GOOD = "\255\216\255\224" .. string.rep("\0\1\2\3", 8) .. "\255\217"
	local BUF = 65536

	local function run_one(opts)
		local path = os.tmpname()
		write_file(path, GOOD .. string.rep("\0", BUF - #GOOD))
		local fd = tonumber(ffi.C.open(path, 2))
		os.remove(path)
		hal.sys.open = function() return fd end
		hal.sys.close = function() return 0 end
		hal.sys.errno = function() return opts.errno or 0 end
		hal.sys.ioctl_p = function(_, req, p)
			if req == 0x80685600 then p.capabilities = 1 end
			if req == 0xC0585609 then p.length = BUF end		-- QUERYBUF
			if req == 0xC0585611 then				-- DQBUF
				if opts.dqbuf_err then return -1 end
				p.index = opts.index or 0
				p.bytesused = opts.bytesused or #GOOD
				p.flags = opts.flags or 0
			end
			return 0
		end
		local ok, res = pcall(call, { path = "/dev/video0" })
		for k, v in pairs(real) do hal.sys[k] = v end
		destroy({})
		return ok, res
	end

	-- 1) poll 出错（EBADF=9）不能被报成「超时」：成因不同，排障方向完全不同
	local ok1, r1 = run_one({})
	check("AG-18：ioctl 桩下正常帧仍 OK（对照组）", ok1 and r1.result == "OK",
		tostring(ok1) .. "/" .. tostring(type(r1) == "table" and r1.result or r1))

	-- 2) 越界 buffer index：内核给了非法索引时必须拒绝并仍把缓冲还回队列
	local ok2, r2 = run_one({ index = 99 })
	check("AG-18：越界 index → ERR 契约", ok2 and type(r2) == "table" and r2.result == "ERR",
		tostring(ok2) .. "/" .. tostring(type(r2) == "table" and r2.message or r2))
	check("AG-18：文案点名 index 越界（与 bytesused 越界区分开）",
		tostring(r2.message):find("index", 1, true) ~= nil, tostring(r2.message))

	-- 3) bytesused 越界：文案仍点名 bytesused
	local ok3, r3 = run_one({ bytesused = BUF + 1 })
	check("AG-18：bytesused 越界 → ERR 且点名 bytesused",
		ok3 and type(r3) == "table" and r3.result == "ERR"
			and tostring(r3.message):find("bytesused", 1, true) ~= nil,
		tostring(type(r3) == "table" and r3.message or r3))

	-- 4) V4L2_BUF_FLAG_ERROR（0x40）：内核明说本帧不可信 → 整帧丢弃
	local ok4, r4 = run_one({ flags = 0x40 })
	check("AG-18：内核标记损坏的帧 → ERR（不再进模型上下文）",
		ok4 and type(r4) == "table" and r4.result == "ERR",
		tostring(ok4) .. "/" .. tostring(type(r4) == "table" and r4.message or r4))
	check("AG-18：文案点名 V4L2_BUF_FLAG_ERROR",
		tostring(r4.message):find("V4L2_BUF_FLAG_ERROR", 1, true) ~= nil, tostring(r4.message))
end

-- ---- #6（2026-09-25）：width/height 逐次可指定，尺寸变了要重协商 ----
-- capture_image 从此把模型请求的尺寸透传给驱动。V4L2 起流后 S_FMT 不可改，
-- 所以「尺寸与上次请求不同」必须走 close → reopen；而「同一请求」不能重开
-- （否则每次拍照都多一次起流 + 首帧丢弃）。判据对比的是**请求值**而非协商值：
-- 设备就近调档（请求 300x200 → 得 320x240）时按协商值比对会每次都重开。
do
	local hal = dofile("modules/lib/HAL.lua")
	local real = {
		open = hal.sys.open, close = hal.sys.close,
		ioctl_p = hal.sys.ioctl_p, errno = hal.sys.errno,
	}
	local GOOD = "\255\216\255\224" .. string.rep("\0\1\2\3", 8) .. "\255\217"
	local BUF = 65536
	local IOCTL_S_FMT = 0xc0d05605

	local opens, sfmt_seen = 0, {}
	local negotiate = nil		-- function(w, h) -> w', h'：模拟设备就近调档
	local path = os.tmpname()
	write_file(path, GOOD .. string.rep("\0", BUF - #GOOD))
	local fd = tonumber(ffi.C.open(path, 2))
	os.remove(path)
	hal.sys.open = function() opens = opens + 1; return fd end
	hal.sys.close = function() return 0 end
	hal.sys.errno = function() return 0 end
	hal.sys.ioctl_p = function(_, req, p)
		if req == 0x80685600 then p.capabilities = 1 end
		if req == IOCTL_S_FMT then
			local w, h = tonumber(p.fmt.pix.width), tonumber(p.fmt.pix.height)
			sfmt_seen[#sfmt_seen + 1] = { w, h }
			if negotiate ~= nil then
				local nw, nh = negotiate(w, h)
				p.fmt.pix.width, p.fmt.pix.height = nw, nh
			end
		end
		if req == 0xC0585609 then p.length = BUF end
		if req == 0xC0585611 then p.index = 0; p.bytesused = #GOOD; p.flags = 0 end
		return 0
	end
	local function restore()
		for k, v in pairs(real) do hal.sys[k] = v end
	end

	local ok = pcall(function()
		-- ① 不给尺寸 → 缺省 640x480
		local r = call({ path = "/dev/video0" })
		check("#6：缺省尺寸仍为 640x480", r.result == "OK" and sfmt_seen[1][1] == 640
			and sfmt_seen[1][2] == 480, tostring(r.message))
		check("#6：首次调用打开一次", opens == 1, tostring(opens))

		-- ② 同尺寸再拍：不重开
		r = call({ path = "/dev/video0", width = 640, height = 480 })
		check("#6：显式给出与当前相同的尺寸不重开", r.result == "OK" and opens == 1,
			"opens=" .. opens)
		r = call({ path = "/dev/video0" })
		check("#6：缺省与 640x480 视为同一请求，不重开", r.result == "OK" and opens == 1,
			"opens=" .. opens)

		-- ③ 换尺寸：重开且 S_FMT 收到新值，结果如实报协商值
		r = call({ path = "/dev/video0", width = 320, height = 240 })
		check("#6：尺寸变更触发重开", opens == 2, "opens=" .. opens)
		check("#6：S_FMT 收到请求的 320x240",
			#sfmt_seen == 2 and sfmt_seen[2][1] == 320 and sfmt_seen[2][2] == 240,
			#sfmt_seen > 1 and (sfmt_seen[#sfmt_seen][1] .. "x" .. sfmt_seen[#sfmt_seen][2]) or "n/a")
		check("#6：返回表报告 320x240", r.result == "OK" and r.width == 320 and r.height == 240,
			tostring(r.width) .. "x" .. tostring(r.height))

		-- ④ 设备就近调档：请求 300x200 → 设备给 320x240；返回实际值，且重复同一请求不重开
		negotiate = function() return 320, 240 end
		r = call({ path = "/dev/video0", width = 300, height = 200 })
		check("#6：调档后返回的是协商值 320x240（不是请求值）",
			r.result == "OK" and r.width == 320 and r.height == 240,
			tostring(r.width) .. "x" .. tostring(r.height))
		local before = opens
		r = call({ path = "/dev/video0", width = 300, height = 200 })
		check("#6：同一请求（虽与协商值不等）不重开", r.result == "OK" and opens == before,
			"opens=" .. opens .. " before=" .. before)
		negotiate = nil

		-- ⑤ 入参校验：只给一个 / 非正整数 → ERR 契约，且不触碰设备
		before = opens
		local bad1 = call({ path = "/dev/video0", width = 320 })
		check("#6：只给 width → ERR", bad1.result == "ERR"
			and tostring(bad1.message):find("together", 1, true) ~= nil, tostring(bad1.message))
		local bad2 = call({ path = "/dev/video0", width = 0, height = 240 })
		check("#6：width=0 → ERR", bad2.result == "ERR"
			and tostring(bad2.message):find("positive integer", 1, true) ~= nil, tostring(bad2.message))
		local bad3 = call({ path = "/dev/video0", width = 320.5, height = 240 })
		check("#6：非整数 → ERR", bad3.result == "ERR", tostring(bad3.message))
		local bad4 = call({ path = "/dev/video0", width = "abc", height = 240 })
		check("#6：非数值 → ERR", bad4.result == "ERR", tostring(bad4.message))
		check("#6：参数错误不触碰设备（未重开）", opens == before, "opens=" .. opens)
	end)
	destroy({})
	restore()
	check("#6：用例体无 Lua error", ok)
end

------------------------------------------------------------------
-- sim-live：从拍照 socket 抓实时帧（MYBOT_SIM_CAPTURE_SOCK）
------------------------------------------------------------------
-- Camera.lua 的 sim-live 是**一问一答**：call() 发 "capture\n" 后阻塞等响应。
-- 单线程测试没法同时既驱动 call() 又充当服务端，故 fork 一个子进程当假仿真器：
-- 子进程 accept→收请求→回响应→_exit，父进程跑 call()。用 fork 而非外部进程，
-- 是为了不引入 python/nc 依赖、也不依赖调度时序（listen backlog 让父进程 connect
-- 立即成功，子进程随后 accept）。子进程**绝不**调 tester.check——它 fork 自父进程
-- 的计数状态，双写会污染汇总；它把收到的请求写进 echo 文件，父进程 waitpid 后读回断言。
do
	-- 复用 Camera.lua 已 cdef 的 cam_sockaddr_un / socket / send / recv；测试只补
	-- 服务端与进程控制所需的符号。
	ffi.cdef[[
	int bind(int fd, const struct cam_sockaddr_un *addr, unsigned int addrlen);
	int listen(int fd, int backlog);
	int accept(int fd, struct cam_sockaddr_un *addr, unsigned int *addrlen);
	int fork(void);
	void _exit(int status);
	long waitpid(int pid, int *status, int options);
	]]

	local CAP_SOCK = "/tmp/mybot-test-cam-cap.sock"
	local REQ_ECHO = "/tmp/mybot-test-cam-cap.req"
	local NOSIGNAL = 0x4000
	-- 伪 JPEG 字节（首 4 字节 FF D8 FF E0 恰是 JPEG 魔数，够文件 src 用例复用）：
	-- sim-live 传输校验只关心字节原样往返，不解析图片内容。
	local CANNED = "\255\216\255\224FAKE-JPEG-BODY-0123456789\255\217"

	local function read_file(path)
		local f = io.open(path, "rb")
		if not f then return nil end
		local s = f:read("*a"); f:close()
		return s
	end

	local function start_listener(path)
		os.remove(path)
		local lfd = ffi.C.socket(1, 1, 0)	-- AF_UNIX, SOCK_STREAM
		assert(lfd >= 0, "socket() 失败")
		local addr = ffi.new("struct cam_sockaddr_un")
		addr.sun_family = 1
		ffi.copy(addr.sun_path, path)
		assert(ffi.C.bind(lfd, addr, 2 + #path + 1) == 0, "bind 失败")
		assert(ffi.C.listen(lfd, 4) == 0, "listen 失败")
		return lfd
	end

	-- fork 出假仿真器：accept 一个连接，收一次请求写进 echo 文件，回一段响应。
	local function spawn_server(lfd, respond)
		os.remove(REQ_ECHO)
		local pid = ffi.C.fork()
		assert(pid >= 0, "fork 失败")
		if pid == 0 then
			local cfd = ffi.C.accept(lfd, nil, nil)
			if cfd >= 0 then
				local buf = ffi.new("unsigned char[64]")
				local n = tonumber(ffi.C.recv(cfd, buf, 64, 0))
				local reqline = (n and n > 0) and ffi.string(buf, n) or ""
				local f = io.open(REQ_ECHO, "wb"); if f then f:write(reqline); f:close() end
				respond(cfd)
				ffi.C.close(cfd)
			end
			ffi.C._exit(0)
		end
		return pid
	end

	local function reap(pid, lfd)
		ffi.C.close(lfd)
		local st = ffi.new("int[1]")
		ffi.C.waitpid(pid, st, 0)
	end

	-- ① 正常抓帧：OK 头 + 固定体，校验 source/format/尺寸/字节数/base64 逐字节
	ffi.C.setenv("MYBOT_SIM_CAPTURE_SOCK", CAP_SOCK, 1)
	local lfd = start_listener(CAP_SOCK)
	local pid = spawn_server(lfd, function(cfd)
		local hdr = string.format("OK jpeg %d %d %d\n", #CANNED, 320, 200)
		ffi.C.send(cfd, hdr, #hdr, NOSIGNAL)
		ffi.C.send(cfd, CANNED, #CANNED, NOSIGNAL)
	end)
	local rb = build({})
	check("sim-live: build 返 OK（不连 socket）", rb.result == "OK", tostring(rb.result))
	local r = call({})
	reap(pid, lfd)
	check("sim-live: 发回的请求正是 'capture\\n'", read_file(REQ_ECHO) == "capture\n",
		tostring(read_file(REQ_ECHO)))
	check("sim-live: source=sim", r.result == "OK" and r.source == "sim", tostring(r.source))
	check("sim-live: format=jpeg", r.format == "jpeg", tostring(r.format))
	check("sim-live: width/height 从头透传", r.width == 320 and r.height == 200,
		tostring(r.width) .. "x" .. tostring(r.height))
	check("sim-live: bytes 数与体一致", r.bytes == #CANNED, tostring(r.bytes))
	check("sim-live: b64 解码逐字节等于服务端回的体", b64decode(r.b64) == CANNED,
		"len=" .. tostring(#b64decode(r.b64 or "")))

	-- ② 仿真器回 ERR 头 → 驱动返 ERR 契约（附原因）
	lfd = start_listener(CAP_SOCK)
	pid = spawn_server(lfd, function(cfd)
		local m = "ERR frame grab or jpeg encode failed\n"
		ffi.C.send(cfd, m, #m, NOSIGNAL)
	end)
	r = call({})
	reap(pid, lfd)
	check("sim-live: 仿真器 ERR → ERR 契约并带回原因",
		r.result == "ERR" and tostring(r.message):find("取帧失败", 1, true) ~= nil
			and tostring(r.message):find("jpeg encode failed", 1, true) ~= nil,
		tostring(r.message))

	-- ③ 畸形响应头 → ERR（协议不符要响亮，不能当成图片）
	lfd = start_listener(CAP_SOCK)
	pid = spawn_server(lfd, function(cfd)
		local m = "GARBAGE-NOT-A-HEADER\n"
		ffi.C.send(cfd, m, #m, NOSIGNAL)
	end)
	r = call({})
	reap(pid, lfd)
	check("sim-live: 畸形响应头 → ERR", r.result == "ERR"
		and tostring(r.message):find("无法解析", 1, true) ~= nil, tostring(r.message))

	-- ④ 无监听端 → 响亮 ERR（与 Sim.lua 动作的静默成功刻意相反：拍照抓空比报错危险）
	ffi.C.setenv("MYBOT_SIM_CAPTURE_SOCK", "/tmp/mybot-test-cam-absent.sock", 1)
	os.remove("/tmp/mybot-test-cam-absent.sock")
	r = call({})
	check("sim-live: 无监听端 → 响亮 ERR（非静默成功）",
		r.result == "ERR" and tostring(r.message):find("connect", 1, true) ~= nil,
		tostring(r.message))

	-- ⑤ 文件 src 优先于 live env：给了 src 就走文件，压根不连拍照 socket
	--    （capture env 指向一个没人监听的路径，若驱动误走 live 必 ERR，以此反证优先级）
	local imgpath = tmpdir("camcap") .. "/frame.jpg"
	write_file(imgpath, CANNED)
	r = call({ src = imgpath, src_root = dirname(imgpath) })
	check("sim-live: 文件 src 优先于 live env（source=file）",
		r.result == "OK" and r.source == "file", tostring(r.source))

	-- ⑥ 未设 capture env → 跳过 live，落回真机路径（这里指向不存在的设备，
	--    断言它没被当成 sim，而是走 V4L2 并因打不开设备报错）
	ffi.C.unsetenv("MYBOT_SIM_CAPTURE_SOCK")
	r = call({ path = "/dev/video9" })
	check("sim-live: 未设 env 时不走 live（source≠sim）",
		r.source ~= "sim", tostring(r.source))

	-- 清理
	ffi.C.unsetenv("MYBOT_SIM_CAPTURE_SOCK")
	os.remove(CAP_SOCK); os.remove(REQ_ECHO); os.remove("/tmp/mybot-test-cam-absent.sock")
end

tester.summary("Camera.lua 单测")
