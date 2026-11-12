-- scscl_scan.lua —— FT-SCS / SCSCL 总线舵机站号扫描（独立工具，不依赖任何驱动）
--
-- 【为什么单独写】modules/SCSCL.lua 的 resolve_common 把结构脚本的 id 列限定在
-- 1~253，广播地址 0xFE(=254) 被明确拒绝——这是对的：驱动不该承担"扫总线"这种
-- 运维职责，而且放行广播会让 .sql 里一个 typo 就同时动到总线上所有舵机。
-- 本脚本绕开驱动，直接走 HAL 的 uart_* 裸帧，把在位舵机的站号读出来。
--
-- 【只读】全程只发 PING(0x01)，不写任何寄存器、不碰 EPROM，可安全反复跑。
--
-- 【不在守门范围内】本脚本不在 test/run_all.sh 的任何分段里——它需要真串口，
-- 离线环境跑不了。改动后请在接舵机的机器上手动验一遍（对应 FAQ 的那条问答）。
--
-- 【用法】（项目根目录；需要 LuaJIT，HAL 依赖 ffi）
--   luajit scripts/scscl_scan.lua                        # 默认 /dev/serial0 @1M，广播 PING
--   luajit scripts/scscl_scan.lua /dev/serial0 1000000   # 显式给串口与波特率
--   luajit scripts/scscl_scan.lua --scan                 # 逐号 1~253 定向 PING（多舵机）
--   luajit scripts/scscl_scan.lua --scan --from 1 --to 32 --timeout 20
--   luajit scripts/scscl_scan.lua --raw                  # 附带原始字节 dump（查线/查波特率）
--
-- 【两种模式的协议事实（决定了它们各自适合什么场合）】
--   * 广播 PING（--mode broadcast，缺省）：协议规定总线上**每块**舵机都应答，
--     且应答里带的是各自的站号。但真机是半双工单总线——多块同时应答会帧冲突
--     变乱码。所以它**只适合"总线上只挂一块舵机"时把那块捉出来**。
--   * 逐号 PING（--scan）：只有站号匹配的那块应答，多舵机也不会冲突；代价是
--     要发 253 帧，耗时 ≈ (to-from+1) × timeout。多舵机请用这个。
--
-- 【需要权限】打开 /dev/serial0 需要 root 或 dialout 组：
--   sudo usermod -aG dialout "$USER"   # 重新登录后生效
--   sudo luajit scripts/scscl_scan.lua # 或直接 sudo
--
-- 【帧格式】（独立实现，与 modules/SCSCL.lua 及其内嵌 SCSCL_VIRT 模型互不引用，
-- 三方各自成文便于交叉比对）
--   指令帧：FF FF ID LEN INST 参数… CS，LEN = 参数数 + 2
--   应答帧：FF FF ID LEN ERROR 参数… CS，总长 = LEN + 4
--   CS = 0xFF - ((ID + LEN + INST + 参数) mod 256)，覆盖 ID 起（两个 FF 字头不计）
--   经典帧实证：id=1 的 PING = FF FF 01 02 01 FB
--               id=0xFE 的 PING = FF FF FE 02 01 FE（校验和字节恰好等于 ID，非笔误）

-- ---- 定位 HAL：与各驱动同款的多路径解析（BOT4CJ_MODULE_PATH 支持 ':' 分隔）----
local mpath = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+")
	.. "/lib/mpath.lua")
dofile(mpath.resolve("lib/HAL.lua"))

-- ==================== 协议常量 ====================
local INST_PING        = 0x01
local ADDR_BROADCAST   = 0xFE
local REPLY_MAX_BYTES  = 64		-- 单轮最多收 64 字节（应答帧仅 6 字节，余量给噪声）
local REPLY_ROUNDS     = 3		-- 多轮累积聚合：前导噪声/跨轮分片均可达
local ID_MIN, ID_MAX   = 1, 253

-- ==================== 帧工具 ====================
local function checksum(t, from, to)
	local s = 0
	for k = from, to do s = s + t[k] end
	return 0xFF - (s % 0x100)
end

local function ping_frame(id)
	local f = { 0xFF, 0xFF, id, 0x02, INST_PING }
	f[#f + 1] = checksum(f, 3, #f)
	return f
end

local function hex(bytes, from, to)
	local out = {}
	for k = from or 1, to or #bytes do out[#out + 1] = string.format("%02X", bytes[k]) end
	return table.concat(out, " ")
end

-- 从累积字节里抽出**所有**合法应答帧（不是只取第一帧——广播模式下要看到
-- 每一块应答的舵机）。返回 { {id=, error=, from=, to=}, ... }。
-- 帧长与校验和推导独立成文；错位字节不会构出合法帧，故只会漏检不会误判出
-- 「校验和碰巧对」的野生帧（PING 应答的 LEN 恒为 2）。
-- 注意步进用 step 而非在循环末尾无条件 i=i+1：命中后要一次跳过整帧（LEN+4 字节），
-- 否则第二帧起全部漏检（多舵机广播场景实测踩过）。
local function scan_frames(acc)
	local frames = {}
	local i = 1
	while i <= #acc - 3 do
		local step = 1
		if acc[i] == 0xFF and acc[i + 1] == 0xFF then
			local len = acc[i + 3]
			local csIdx = i + len + 3
			if csIdx <= #acc and acc[csIdx] == checksum(acc, i + 2, i + len + 2) then
				frames[#frames + 1] = {
					id = acc[i + 2], error = acc[i + 4], from = i, to = csIdx,
				}
				step = len + 4		-- 跳过整帧（帧总长 = LEN + 4）
			end
		end
		i = i + step
	end
	return frames
end

-- 读若干轮并把应答帧凑齐。返回 frames, acc, err：
--   err == nil          正常（frames 可能为空表 = 对端没应答）
--   err ~= nil          硬读错误（fd 已坏等），frames/acc 为已收部分
local function read_frames(fd, timeout_ms)
	local acc = {}
	for _ = 1, REPLY_ROUNDS do
		local chunk = uart_read(fd, REPLY_MAX_BYTES, timeout_ms)
		if chunk == nil then
			return {}, acc, "uart_read 返回 nil（读错误：fd 失效或 errno 非 EAGAIN/EINTR）"
		end
		for _, b in ipairs(chunk) do acc[#acc + 1] = b end
		local frames = scan_frames(acc)
		if #frames > 0 then return frames, acc, nil end
	end
	return {}, acc, nil
end

-- ==================== 参数解析 ====================
local opts = {
	path = "/dev/serial0", baud = 1000000,
	mode = "broadcast", from = ID_MIN, to = ID_MAX,
	timeout = 30, raw = false,
}

local function usage()
	print("scscl_scan —— FT-SCS / SCSCL 总线舵机站号扫描（只发 PING，无副作用）")
	print("")
	print("用法: luajit scripts/scscl_scan.lua [串口路径] [波特率] [选项]")
	print("")
	print("  串口路径        缺省 /dev/serial0（HAL 白名单只认 /dev/ttyXXX 与 /dev/serialN）")
	print("  波特率          缺省 1000000（SCSCL 出厂档；另一档 500000）")
	print("")
	print("  --scan          逐号 1~253 定向 PING（多舵机用这个）")
	print("  --from N        扫描起始站号（缺省 1，仅 --scan 有效）")
	print("  --to N          扫描结束站号（缺省 253，仅 --scan 有效）")
	print("  --timeout MS    每个站号的等待毫秒（缺省 30；广播模式自动 ×4）")
	print("  --raw           附带原始字节 dump，用于查接线/波特率/回显")
	print("  -h, --help      本帮助")
	print("")
	print("缺省模式是广播 PING：只适合总线上只挂一块舵机时把它捉出来（多块会帧冲突）。")
end

local positional = {}
do
	local i = 1
	while i <= #arg do
		local a = arg[i]
		if a == "--scan" then opts.mode = "scan"
		elseif a == "--raw" then opts.raw = true
		elseif a == "--from" or a == "--to" or a == "--timeout" then
			i = i + 1
			local v = tonumber(arg[i])
			if v == nil then
				print(string.format("%s 的值不是数字：%s", a, tostring(arg[i])))
				os.exit(2)
			end
			opts[a:sub(3)] = v
		elseif a == "-h" or a == "--help" then usage(); os.exit(0)
		elseif a:sub(1, 2) == "--" then
			print("未知参数：" .. a .. "（用 --help 查看支持的参数）")
			os.exit(2)
		else positional[#positional + 1] = a end
		i = i + 1
	end
end

if positional[1] ~= nil then opts.path = positional[1] end
if positional[2] ~= nil then opts.baud = tonumber(positional[2]) end

opts.from = math.floor(opts.from or ID_MIN)
opts.to = math.floor(opts.to or ID_MAX)
opts.timeout = math.floor(opts.timeout or 30)
if opts.path == nil or opts.path:sub(1, 1) ~= "/" then
	print("串口路径必须是绝对路径，例如 /dev/serial0")
	os.exit(2)
end
if opts.baud == nil then
	print("波特率不是数字")
	os.exit(2)
end
if opts.from < ID_MIN or opts.to > ID_MAX or opts.from > opts.to then
	print(string.format("扫描范围非法：%d~%d（合法 1~253 且 from<=to）", opts.from, opts.to))
	os.exit(2)
end
if opts.timeout < 1 or opts.timeout > 60000 then
	print(string.format("--timeout 非法：%d（合法 1~60000 ms）", opts.timeout))
	os.exit(2)
end

-- ==================== 开串口 ====================
print(string.format("SCSCL 站号扫描：%s @%d baud，模式=%s",
	opts.path, opts.baud, opts.mode == "broadcast" and "广播 PING" or "逐号 PING"))
if opts.mode == "scan" then
	print(string.format("范围 %d~%d，每题超时 %d ms（预计最长 %.1f s）",
		opts.from, opts.to, opts.timeout,
		(opts.to - opts.from + 1) * opts.timeout / 1000))
end

local fd = uart_open(opts.path, opts.baud)
if fd < 0 then
	print("")
	print("打开串口失败。逐项排查：")
	print("  1) 设备存在吗：ls -l " .. opts.path .. "（树莓派缺省是 /dev/serial0 软链）")
	print("  2) 有权限吗：需要在 dialout 组或 root（sudo usermod -aG dialout $USER 后重新登录）")
	print("  3) 波特率在 HAL 白名单内吗：1200/2400/4800/9600/19200/38400/57600/115200/")
	print("     230400/460800/500000/921600/1000000（SCSCL 常用 1000000 或 500000）")
	os.exit(2)
end

-- ==================== 扫描 ====================
local found = {}		-- id -> error
local hits = {}			-- 顺序记录，便于打印
local scan_errors = 0	-- 写失败计数（不立即退出，继续扫）

-- 发一帧 PING 并收应答；返回 frames(表), acc(原始字节表), err
local function probe(id, timeout_ms)
	local f = ping_frame(id)
	uart_flush(fd)					-- 丢掉上一条指令的应答残留
	local wn = uart_write(fd, f)
	if wn ~= #f then
		return {}, {}, string.format("uart_write 只写了 %s/%d 字节", tostring(wn), #f)
	end
	return read_frames(fd, timeout_ms)
end

if opts.mode == "broadcast" then
	local f = ping_frame(ADDR_BROADCAST)
	print(string.format("发送广播 PING：%s", hex(f)))
	local frames, acc, err = probe(ADDR_BROADCAST, opts.timeout * 4)
	if err ~= nil then
		print("读错误：" .. err)
	end
	for _, fr in ipairs(frames) do
		if found[fr.id] == nil then
			found[fr.id] = fr.error
			hits[#hits + 1] = fr.id
		end
	end
	if opts.raw then
		print(string.format("原始字节（%d）：%s", #acc, #acc > 0 and hex(acc) or "（无数据）"))
	end
	if #hits == 0 then
		print("")
		print("没有任何舵机应答。可能原因：")
		print("  * 总线上没有舵机，或舵机没上电（FT-SCS 舵机需独立 6~8.4V 供电，"
			.. "USB-TTL 的 5V 带不动）")
		print("  * 波特率不对：SCSCL 出厂 1000000 档，老固件可能是 500000，"
			.. "换档再试一次")
		print("  * 接线反了：信号线要接对端 TX/RX，地必须共地；半双工单总线"
			.. "需方向控制转接板")
		print("  * 总线上挂了好几块舵机 → 广播 PING 会帧冲突，改用 --scan 逐号试")
		print("  * 加 --raw 看有没有字节回来，能区分「线路不通」与「协议对不上」")
		uart_close(fd)
		os.exit(1)
	end
else
	local n = 0
	for id = opts.from, opts.to do
		local frames, acc, err = probe(id, opts.timeout)
		if err ~= nil then
			scan_errors = scan_errors + 1
			print(string.format("  id=%d 写失败：%s", id, err))
		else
			for _, fr in ipairs(frames) do
				-- 只认站号确实等于本次询问值的应答，压掉野帧
				if fr.id == id and found[id] == nil then
					found[id] = fr.error
					hits[#hits + 1] = id
					print(string.format("  命中 id=%d（状态字节 0x%02X%s）",
						id, fr.error, fr.error == 0 and "，正常" or "，有故障标志"))
					if opts.raw then
						print(string.format("    原始字节：%s", hex(acc)))
					end
				end
			end
		end
		n = n + 1
		if n % 50 == 0 then
			print(string.format("  …已试 %d/%d", n, opts.to - opts.from + 1))
		end
	end
end

uart_close(fd)

-- ==================== 汇总 ====================
print("")
if #hits == 0 then
	print("汇总：0 块舵机应答")
	os.exit(1)
end

print(string.format("汇总：发现 %d 块舵机", #hits))
for _, id in ipairs(hits) do
	local e = found[id]
	print(string.format("  id=%-3d 状态字节 0x%02X%s", id, e,
		e == 0 and "" or "（非 0，舵机上报了故障标志）"))
end

print("")
print("把站号填进结构脚本（.sql 的 id 列是「舵机此刻的真实站号」，不是你想设的值）：")
for k, id in ipairs(hits) do
	print("  INSERT INTO SCSCL (name, UART, id, max, min, offset)")
	print(string.format("    VALUES ('s%d', '$uart-0', '%d', '1023', '0', '0');", k, id))
end
print("")
print("想把某块改成别的号：在 .mt 里单开一行写 set_id=N（真机烧号只接目标舵机），")
print("断电重启后再把上面这行的 id 改成 N。详见 modules/SCSCL.lua 头部注释。")

if scan_errors > 0 then
	print("")
	print(string.format("注意：本次有 %d 个站号写失败，结果可能不完整。", scan_errors))
	os.exit(1)
end
