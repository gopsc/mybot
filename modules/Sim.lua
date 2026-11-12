-- Sim 仿真器桥接驱动模块
-- 把语义动作以行文本发给 mybot-sim（sim/ 下的 GLFW 蜘蛛仿真器）监听的
-- AF_UNIX socket。仿真器收到后让蜘蛛持续执行该动作，直到下一条指令。
--
-- 只传「动作 + 速度」，**不传关节角**：蜘蛛的腿部步态由仿真器自己按身体
-- 速度生成。上游（.mt 动作脚本 / agent）只表达「前进、后退、左转、右转、停」。
--
-- 协议（与 sim/src/bridge.cpp 逐字对应）：
--   forward | backward | left | right | stop   [速度 0.00~1.00]
--   fdist <meters>     -- 相对前进 N 米后停
--   turn <degrees>     -- 相对转向 N 度后停（正=左，负=右）
--   jump <meters> <height>  -- 向前弹道跳：水平前跳 N 米、apex 离地 height 米
-- 每条一行，以 \n 结尾；速度缺省 1.0。手测：
--   socat - UNIX-CONNECT:/tmp/mybot-sim.sock
--
-- .mt 侧用**数字动作码**而非动作名：矩阵单元格只解析 Float64
-- （matrix.cpp 对 'forward' 这类字符串直接报 cannot parse matrix cell），
-- 语义名字只存在于 socket 线上与下面的 CODES 表里：
--   0=stop  1=forward  2=backward  3=left  4=right  5=fdist  6=turn  7=pick  8=place
--   9=save（把当前场景写回仿真器启动时配置的场景文件，见 docs/sim.md）
--   10=jump（向前跳；param=前跳米数、param2=apex 高度米数，两个参数都必填）
--
-- 测距（range 函数）走独立的 sensor socket（MYBOT_SIM_SENSOR_SOCK），
-- 协议：发 "range\n"，收 "OK <mm>\n" 或 "ERR <reason>\n"。
--
-- IMU / 里程计（imu / odom 函数，2026-10-16）各走独立 socket
-- （MYBOT_SIM_IMU_SOCK / MYBOT_SIM_ODOM_SOCK），同为一问一答：
--   发 "imu\n"  收 "OK <yaw_deg> <gyro_z> <acc_fwd> <vy> <airborne>\n"
--   发 "odom\n" 收 "OK <x> <z> <theta_deg> <v> <odo>\n"
-- 口径见 docs/sim.md：仿真器是运动学模型，IMU 域集合如实反映它测得到什么
-- （无磁力计/横摆加速度）；里程计是地面真值（无轮子打滑模型）。
--
-- socket 路径取环境变量 MYBOT_SIM_SOCK，缺省 /tmp/mybot-sim.sock——与
-- sim/src/main.cpp 的取值同源，两侧不用各自配置。
--
-- 成败口径（刻意不对称）：
--   * 仿真器没开 / 中途断开 = **静默成功**。可视化从端缺席不该打断动作脚本，
--     真机路径也不该被一个调试窗口绑架。每次 call 都会重试连接，仿真器中途
--     起来即接上；BOT4CJ_DEBUG=1 时把丢弃动作打印出来。
--   * 动作名非法 = 响亮报错（ERR 契约）。那是脚本作者的笔误，不是环境问题，
--     静默丢弃会让 .mt 里的错字永远查不出来。
--   * range() 仿真器缺席 = 响亮 ERR。测距是模型的显式感知动作，静默返回
--     假数据比报错危险。
--
-- 标准前导：print_table 经 mpath 加载（modules/lib/）
local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/print_table.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

-- AF_UNIX socket 公共模块：FFI 声明 + 连接工具（与 Camera.lua 共用，避免重复 cdef）
local usock = dofile(mpath.resolve("lib/unix_socket_ffi.lua"))
local ffi = require("ffi")

-- poll 结构单独声明：公共模块不包含 poll（各驱动的 pollfd 结构名不同）
-- errno 同理不在此声明：见 lib/unix_socket_ffi.lua 头注（数据符号当函数调会 SIGSEGV），
-- 统一用 LuaJIT 内建 ffi.errno()。
-- poll 结构体 cdef 一次性（与 lib/unix_socket_ffi.lua、HAL 的守卫同口径）：
-- 同一个 lua_State 里重复加载（测试热重载、守护 chunk 与主线程驱动共状态等）
-- 时 struct 重复声明是硬错误。_G 旗标跨 dofile 存活，第二次起静默跳过。
if not rawget(_G, "__BOT4CJ_SIM_POLL_CDEF") then
	_G.__BOT4CJ_SIM_POLL_CDEF = true
	local cok, cerr = pcall(function()
		ffi.cdef[[
struct cj_pollfd { int fd; short events; short revents; };
int poll(struct cj_pollfd *fds, unsigned long nfds, int timeout);
]]
	end)
	if not cok then
		print("Sim.lua: poll cdef 失败（可能已声明过）: " .. tostring(cerr))
	end
end

local kDefaultSock = "/tmp/mybot-sim.sock"

-- .mt 动作码 → 线上动作名。下标即 .sql 注释里登记的动作码。
local CODES = {
	[0] = "stop",
	[1] = "forward",
	[2] = "backward",
	[3] = "left",
	[4] = "right",
	[5] = "fdist",
	[6] = "turn",
	[7] = "pick",
	[8] = "place",
	[9] = "save",
	[10] = "jump",
}
local CODE_MAX = 10

-- 带参数的动作码（fdist/turn 需 param；jump 需 param=距离）
local PARAM_CODES = { [5] = true, [6] = true, [10] = true }

-- 带**第二**参数的动作码（jump 除距离外还需 param2=apex 高度）。
-- 宿主侧经 spider_sim.sql 的 Q→param2 别名从 .mt 的第二参数列喂进来。
local PARAM2_CODES = { [10] = true }

-- 每个 Lua 状态（= 每个设备实例）一份连接，跨 call 复用
local fd = nil
local sock_path = nil

-- 前向声明：destroy 在文件前段就要关 sensor/imu/odom 连接，而它们的定义在
-- 文件后段——Lua 局部函数只对定义点之前已声明的名字可见
local dropSensor
local dropImuOdom

local function sockPath()
	if sock_path == nil then
		local p = os.getenv("MYBOT_SIM_SOCK")
		if p == nil or p == "" then
			p = kDefaultSock
		end
		sock_path = p
	end
	return sock_path
end

local function dropConnection()
	if fd ~= nil then
		ffi.C.close(fd)
		fd = nil
	end
end

-- 惰性连接：build 时不连——仿真器常常后起，连接失败也不该让结构脚本 build 红
local function ensureConnected()
	if fd ~= nil then
		return true
	end
	local s, _ = usock.connect(sockPath())
	if s == nil then
		return false
	end
	fd = s
	return true
end


-- 【配置脚本】不申请资源，连接惰性到首次 call
function build(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	return {  result = "OK"  }

end


-- 【销毁Sim】关掉可能还开着的 socket
function destroy(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	dropConnection()
	dropSensor()
	dropImuOdom()

	return {  result = "OK"  }

end


-- 【调用Sim】发一条语义动作
-- 元数据列：无（socket 路径走 MYBOT_SIM_SOCK，见文件头）
-- 输入参数：
--   action: 0=stop 1=forward 2=backward 3=left 4=right 5=fdist 6=turn 7=pick 8=place
--           9=save 10=jump
--   speed:  可选 0~1（持续型动作用）
--   param:  fdist 的距离（米）/ turn 的角度（正=左，负=右）/ jump 的前跳距离（米）
--   param2: jump 的起跳 apex 高度（米）——仅 jump（码 10）需要
function call(data)

	local ok, ek = arg_table(data)
	if not ok then
		return ek
	end

	local code = finite_of(tonumber(data.action))
	if code == nil then
		return err("Invalid Argument: action (missing or not a number)")
	end
	-- 动作码必须是 0..CODE_MAX 的整数：矩阵是 Float64，1.5 这种值只会是脚本笔误
	if code ~= math.floor(code) or code < 0 or code > CODE_MAX then
		return err("Invalid Argument: action " .. tostring(code)
			.. " (expected 0=stop 1=forward 2=backward 3=left 4=right 5=fdist 6=turn"
			.. " 7=pick 8=place 9=save 10=jump)")
	end
	local action = CODES[code]

	local line = action
	if PARAM_CODES[code] then
		-- fdist/turn/jump 需要 param 参数
		local param = finite_of(tonumber(data.param))
		if param == nil then
			return err("Invalid Argument: param (missing or not a number for " .. action .. ")")
		end
		line = action .. " " .. string.format("%.4f", param)
		if PARAM2_CODES[code] then
			-- jump 还需第二参数（apex 高度）
			local param2 = finite_of(tonumber(data.param2))
			if param2 == nil then
				return err("Invalid Argument: param2 (missing or not a number for " .. action .. ")")
			end
			line = line .. " " .. string.format("%.4f", param2)
		end
		line = line .. "\n"
	else
		local speed = 1.0
		if data.speed ~= nil then
			local s = finite_of(tonumber(data.speed))
			if s == nil then
				return err("Invalid Argument: speed (not a finite number)")
			end
			if s < 0 then s = 0 elseif s > 1 then s = 1 end
			speed = s
		end
		if speed ~= 1.0 then
			line = action .. " " .. string.format("%.2f", speed)
		end
		line = line .. "\n"
	end

	if not ensureConnected() then
		if os.getenv("BOT4CJ_DEBUG") == "1" then
			print("Sim: simulator not listening on " .. sockPath()
				.. " (action '" .. action .. "' dropped)")
		end
		return {  result = "OK"  }
	end

	local n = ffi.C.send(fd, line, #line, usock.MSG_NOSIGNAL)
	if n < 0 then
		-- 对端没了：断开并按「仿真器缺席」口径静默成功，下次 call 重连
		dropConnection()
		return {  result = "OK"  }
	end

	if os.getenv("BOT4CJ_DEBUG") == "1" then
		print("Sim: sent '" .. line:sub(1, -2) .. "' to " .. sockPath())
	end

	return {  result = "OK"  }

end


------------------------------------------------------------------
-- 测距（range）：走独立的 sensor socket
------------------------------------------------------------------
local kSensorDefaultSock = "/tmp/mybot-sim-sensor.sock"
local kSensorPollMs = 3000

local sensorFd = nil
local sensorSockPath = nil

local function sensorPath()
	if sensorSockPath == nil then
		local p = os.getenv("MYBOT_SIM_SENSOR_SOCK")
		if p == nil or p == "" then
			p = kSensorDefaultSock
		end
		sensorSockPath = p
	end
	return sensorSockPath
end

function dropSensor()
	if sensorFd ~= nil then
		ffi.C.close(sensorFd)
		sensorFd = nil
	end
end

local function ensureSensor()
	if sensorFd ~= nil then
		return true
	end
	local s, _ = usock.connect(sensorPath())
	if s == nil then
		return false
	end
	sensorFd = s
	return true
end

-- 带超时收一行（到 \n 为止）：用 cj_pollfd 做 poll 超时。
-- fd 显式传入：sensor/imu/odom 三条一问一答 socket 共用同一收行实现。
local function recvLineOn(fd)
	local buf = ffi.new("unsigned char[256]")
	local got = 0
	local fds = ffi.new("struct cj_pollfd[1]")
	for _ = 1, 256 do
		fds[0].fd = fd
		fds[0].events = 1  -- POLLIN
		local pr = ffi.C.poll(fds, 1, kSensorPollMs)
		if pr < 0 then
			local e = ffi.errno()
			if e ~= 4 then  -- EINTR
				return nil, "poll failed (errno=" .. tostring(e) .. ")"
			end
		elseif pr == 0 then
			return nil, "response timeout"
		else
			local n = ffi.C.recv(fd, buf + got, 1, 0)
			if n <= 0 then
				return nil, "recv failed"
			end
			if buf[got] == 10 then  -- '\n'
				return ffi.string(buf, got)
			end
			got = got + 1
			if got >= 255 then
				return nil, "response too long"
			end
		end
	end
	return nil, "recv loop error"
end

-- 【测距】查询前方障碍距离
-- 返回 { result="OK", distance=<meters> } 或 ERR
function range(data)
	if data ~= nil then
		local ok, ek = arg_table(data)
		if not ok then
			return ek
		end
	end

	if not ensureSensor() then
		return err("sensor socket not available (仿真器没开？路径 " .. sensorPath() .. ")")
	end

	local req = "range\n"
	local n = ffi.C.send(sensorFd, req, #req, usock.MSG_NOSIGNAL)
	if n < 0 then
		dropSensor()
		return err("sensor send failed (对端断开？)")
	end

	local line, rerr = recvLineOn(sensorFd)
	if line == nil then
		dropSensor()
		return err(rerr or "sensor recv failed")
	end

	if line:sub(1, 3) == "ERR" then
		return err("sensor: " .. (line:sub(5):gsub("^%s+", "")))
	end

	local okStr, mmStr = line:match("^(OK)%s+(%d+)$")
	if okStr == nil then
		return err("sensor response malformed: " .. line)
	end

	local mm = tonumber(mmStr)
	return {
		result = "OK",
		distance = mm / 1000.0,  -- 毫米 → 米
		distance_mm = mm,
	}
end

------------------------------------------------------------------
-- IMU / 里程计（2026-10-16）：各走独立的一问一答 socket
------------------------------------------------------------------
-- 与 sensor 同型的三件套：路径（env > 缺省）、惰性连接、收行（recvLineOn）。
-- 成败口径与 range() 一致：仿真器缺席/断开 = 响亮 ERR（感知动作不该静默造假）。
local kImuDefaultSock = "/tmp/mybot-sim-imu.sock"
local kOdomDefaultSock = "/tmp/mybot-sim-odom.sock"

local imuFd, odomFd = nil, nil
local imuSockPath, odomSockPath = nil, nil

local function imuPath()
	if imuSockPath == nil then
		local p = os.getenv("MYBOT_SIM_IMU_SOCK")
		if p == nil or p == "" then
			p = kImuDefaultSock
		end
		imuSockPath = p
	end
	return imuSockPath
end

local function odomPath()
	if odomSockPath == nil then
		local p = os.getenv("MYBOT_SIM_ODOM_SOCK")
		if p == nil or p == "" then
			p = kOdomDefaultSock
		end
		odomSockPath = p
	end
	return odomSockPath
end

function dropImuOdom()
	if imuFd ~= nil then
		ffi.C.close(imuFd)
		imuFd = nil
	end
	if odomFd ~= nil then
		ffi.C.close(odomFd)
		odomFd = nil
	end
end

-- 一问一答公共骨架：发请求行 → 收 OK 行 → 交给 parse 拆数值域。
-- 任一步失败都关连接（下次重连）并按 ERR 契约报错。
local function queryBridge(fdtbl, path, request, parse)
	local fd = fdtbl[1]
	if fd == nil then
		local s, _ = usock.connect(path)
		if s == nil then
			return err("socket not available (仿真器没开？路径 " .. path .. ")")
		end
		fdtbl[1] = s
		fd = s
	end
	local n = ffi.C.send(fd, request, #request, usock.MSG_NOSIGNAL)
	if n < 0 then
		ffi.C.close(fd)
		fdtbl[1] = nil
		return err("send failed (对端断开？)")
	end
	local line, rerr = recvLineOn(fd)
	if line == nil then
		ffi.C.close(fd)
		fdtbl[1] = nil
		return err(rerr or "recv failed")
	end
	if line:sub(1, 3) == "ERR" then
		return err(line:sub(5):gsub("^%s+", ""))
	end
	local okFrame = line:match("^OK%s")
	if okFrame == nil then
		return err("response malformed: " .. line)
	end
	return parse(line:sub(3))
end

-- 【IMU】一帧机体姿态/角速度/前向加速度/竖直速度/离地标志。
-- 返回 { result="OK", yaw_deg, gyro_z, acc_fwd, vy, airborne } 或 ERR。
function imu(data)
	if data ~= nil then
		local ok, ek = arg_table(data)
		if not ok then
			return ek
		end
	end
	local req = "imu\n"
	local holder = { imuFd }
	local r = queryBridge(holder, imuPath(), req, function(body)
		local a, b, c, d, e = body:match("^%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+(%d+)$")
		if a == nil then
			return err("imu frame malformed:" .. body)
		end
		return {
			result = "OK",
			yaw_deg = tonumber(a),
			gyro_z = tonumber(b),
			acc_fwd = tonumber(c),
			vy = tonumber(d),
			airborne = tonumber(e),
		}
	end)
	imuFd = holder[1]
	return r
end

-- 【里程计】一帧地面真值位姿/速度/累计里程。
-- 返回 { result="OK", x, z, theta_deg, v, odo } 或 ERR。
function odom(data)
	if data ~= nil then
		local ok, ek = arg_table(data)
		if not ok then
			return ek
		end
	end
	local req = "odom\n"
	local holder = { odomFd }
	local r = queryBridge(holder, odomPath(), req, function(body)
		local a, b, c, d, e = body:match("^%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)$")
		if a == nil then
			return err("odom frame malformed:" .. body)
		end
		return {
			result = "OK",
			x = tonumber(a),
			z = tonumber(b),
			theta_deg = tonumber(c),
			v = tonumber(d),
			odo = tonumber(e),
		}
	end)
	odomFd = holder[1]
	return r
end
