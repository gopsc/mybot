-- fft.lua - 基 2 快速傅里叶变换库
-- bot4cj 仓颉语言机器人框架
--
-- 自 src/cpp/fft1.c（Jiang Yong, 2003）移植，保持原算法结构：
--   fft1    复数变换（逐级蝶形 + 末级位反转置换，旋转因子按位反转选取）
--   fft1r2  双实序列打包为一次复数变换（共轭对称性拆分）
--   fft1r1  单实序列 2N 点变换（奇偶分解 + 半谱合并）
--
-- 【修正原版 bug】C 版 fft1r1 的逆变换分支只计算了 d0、未计算 d1
-- （未初始化的局部数组直接传入 fft1r2 的实数性检查，该路径必然失败）。
-- 本移植按逆变换数学推导补全：
--   D[j] = W^-j · (X[j] - X[j+N]) / 2
--   d1[j] = 0.5 · (cosj·Δim + sinj·Δre)，其中 sinj = +sin(πj/N)
--
-- 【与 C 版差异】
--   - N 不再固定为 32768：支持任意 2 的幂，旋转因子表按 N 缓存（对应原 initial() 只跑一次）
--   - 对外数组为 Lua 惯例 1 基；内部转录保持 0 基，与 C 索引逐行对应
--   - float → double；printf+exit → error
--   - 纯算术实现，lua5.4 与 luajit 双兼容
--
-- 用法：
--   local FFT = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/fft.lua")
--   local re, im = FFT.fft(xre)            -- 复数 FFT（im 可省略，视为全 0）
--   local xre, xim = FFT.ifft(re, im)      -- 复数 IFFT
--   local sre, sim = FFT.fft_real(x)       -- 实序列（长度为 2 的幂）→ 全谱（含共轭镜像）
--   local x2 = FFT.ifft_real(sre, sim)     -- 实序列逆变换
--   local are, aim, bre, bim = FFT.fft_real2(xa, xb)   -- 双实序列一次变换
--   local xa2, xb2 = FFT.ifft_real2(are, aim, bre, bim)

local FFT = {}

local eps = 1e-9		-- 实数性检查容差（同 C 版 eps）
local cache = {}		-- N -> plan（旋转因子与索引表）

------------------------------------------------------------------
-- 基础工具
------------------------------------------------------------------

-- 位反转（直译 C 版 inverseq）：i1 在 imax 位宽内反转
local function inverseq(i1, imax)
	local i0, inv = i1, 0
	for _ = 1, imax do
		local ii = i0 % 2
		inv = 2 * inv + ii
		i0 = (i0 - ii) / 2
	end
	return inv
end

-- 校验 n 为 2 的幂且 >= 1，返回 M = log2(n)
local function check_pow2(n, what)
	if type(n) ~= "number" or math.floor(n) ~= n or n < 1 then
		error((what or "length") .. " must be a positive integer, got " .. tostring(n))
	end
	local M, ni = 0, n
	while ni > 1 do
		ni = math.floor(ni / 2)
		M = M + 1
	end
	if 2 ^ M ~= n then
		error((what or "length") .. " must be a power of 2, got " .. n)
	end
	return M
end

-- 生成/取用 N 点变换计划（对应 C 版 initial()，按 N 缓存）
local function plan(n)
	local p = cache[n]
	if p ~= nil then return p end

	local M = check_pow2(n, "N")
	local kup, jup = {}, {}
	kup[0] = math.floor(n / 2)	-- kup[l] = 2^(M-l-1)
	jup[0] = 1			-- jup[l] = 2^l
	for j = 1, M - 1 do
		kup[j] = math.floor(kup[j - 1] / 2)
		jup[j] = jup[j - 1] * 2
	end

	local pi = 4.0 * math.atan(1)
	local unit = 2.0 * pi / n
	local wr, wi = {}, {}
	for i = 0, n - 1 do
		local tt = i * unit
		wr[i] = math.cos(tt)
		wi[i] = -math.sin(tt)	-- C 版 sign = -1（正变换 e^{-iθ} 约定）
	end

	p = { M = M, kup = kup, jup = jup, wr = wr, wi = wi }
	cache[n] = p
	return p
end

-- 1 基数组 → 0 基内部表（校验数值与长度）
local function to0(arr, n, name)
	if type(arr) ~= "table" then
		error(name .. " must be a table")
	end
	if #arr ~= n then
		error(name .. " length must be " .. n .. ", got " .. #arr)
	end
	local t = {}
	for i = 0, n - 1 do
		local v = tonumber(arr[i + 1])
		if v == nil then
			error(name .. "[" .. (i + 1) .. "] is not a number")
		end
		t[i] = v
	end
	return t
end

-- 0 基内部表 → 1 基数组
local function to1(t, n)
	local out = {}
	for i = 0, n - 1 do out[i + 1] = t[i] end
	return out
end

------------------------------------------------------------------
-- fft1：复数变换核心（直译 C 版，0 基就地）
-- inverse=false 正变换；true 逆变换（共轭法：前后取反虚部，末尾除 N）
------------------------------------------------------------------
local function fft1(a0, a1, n, p, inverse)
	if inverse then
		for i = 0, n - 1 do a1[i] = -a1[i] end
	end

	for l = 0, p.M - 1 do
		for j = 0, p.jup[l] - 1 do
			local reseq = inverseq(j, l)
			local ij = p.kup[l] * reseq
			local jl0 = 2 * p.kup[l] * j
			local wrc, wis = p.wr[ij], p.wi[ij]
			for k = 0, p.kup[l] - 1 do
				local jl0k = jl0 + k
				local jl1k = jl0 + p.kup[l] + k
				local ar = a0[jl1k] * wrc - a1[jl1k] * wis
				local ai = a0[jl1k] * wis + a1[jl1k] * wrc
				a0[jl1k] = a0[jl0k] - ar
				a1[jl1k] = a1[jl0k] - ai
				a0[jl0k] = a0[jl0k] + ar
				a1[jl0k] = a1[jl0k] + ai
			end
		end
	end

	-- 末级位反转置换
	local x0, x1 = {}, {}
	for i = 0, n - 1 do
		local j = inverseq(i, p.M)
		x0[i] = a0[j]
		x1[i] = a1[j]
	end
	for i = 0, n - 1 do
		a0[i] = x0[i]
		a1[i] = x1[i]
	end

	if inverse then
		for i = 0, n - 1 do
			a0[i] = a0[i] / n
			a1[i] = -a1[i] / n
		end
	end
end

------------------------------------------------------------------
-- fft1r2 核心：双实序列（a=xa 谱、b=xb 谱）打包/解包，0 基就地
------------------------------------------------------------------
local function fft1r2_fwd(a0, a1, b0, b1, n, p)
	-- c = xa + i·xb 做一次复数变换
	local c0, c1 = {}, {}
	for k = 0, n - 1 do
		c0[k] = a0[k]
		c1[k] = b0[k]
	end
	fft1(c0, c1, n, p, false)

	a0[0] = c0[0]; a1[0] = 0.0
	b0[0] = c1[0]; b1[0] = 0.0
	for j = 1, n - 1 do
		a0[j] =  0.5 * (c0[j] + c0[n - j])
		a1[j] =  0.5 * (c1[j] - c1[n - j])
		b0[j] =  0.5 * (c1[j] + c1[n - j])
		b1[j] = -0.5 * (c0[j] - c0[n - j])
	end
end

local function fft1r2_inv(a0, a1, b0, b1, n, p)
	-- 实数性检查：两谱均须满足共轭对称
	for j = 0, math.floor(n / 2) - 1 do
		local norm
		if j == 0 then
			norm = 2.0 * math.abs(a1[0]) + 2.0 * math.abs(b1[0])
		else
			norm = math.abs(a1[j] + a1[n - j])
			     + math.abs(a0[j] - a0[n - j])
			     + math.abs(b1[j] + b1[n - j])
			     + math.abs(b0[j] - b0[n - j])
		end
		if norm > eps then
			error("The IDFT of the series isn't real!")
		end
	end

	local c0, c1 = {}, {}
	for j = 0, n - 1 do
		c0[j] = a0[j] - b1[j]
		c1[j] = a1[j] + b0[j]
	end
	fft1(c0, c1, n, p, true)
	for k = 0, n - 1 do
		a0[k] = c0[k]
		b0[k] = c1[k]
		a1[k] = 0.0
		b1[k] = 0.0
	end
end

------------------------------------------------------------------
-- 公开 API（1 基数组进出，返回新数组，不修改入参）
------------------------------------------------------------------

-- 复数 FFT：re 必选，im 可省（视为全 0）；长度须为 2 的幂
function FFT.fft(re, im)
	local n = #re
	local M = check_pow2(n, "input length")
	local p = plan(n)
	local a0 = to0(re, n, "re")
	local a1 = im and to0(im, n, "im") or {}
	if not im then for i = 0, n - 1 do a1[i] = 0.0 end end
	fft1(a0, a1, n, p, false)
	return to1(a0, n), to1(a1, n)
end

-- 复数 IFFT
function FFT.ifft(re, im)
	local n = #re
	local M = check_pow2(n, "input length")
	local p = plan(n)
	local a0 = to0(re, n, "re")
	local a1 = im and to0(im, n, "im") or {}
	if not im then for i = 0, n - 1 do a1[i] = 0.0 end end
	fft1(a0, a1, n, p, true)
	return to1(a0, n), to1(a1, n)
end

-- 双实序列打包变换：xa/xb 各长 N → 返回各自的谱（are/aim、bre/bim，各长 N）
function FFT.fft_real2(xa, xb)
	if #xa ~= #xb then
		error("xa and xb must have the same length")
	end
	local n = #xa
	check_pow2(n, "input length")
	local p = plan(n)
	local a0 = to0(xa, n, "xa")
	local b0 = to0(xb, n, "xb")
	local a1, b1 = {}, {}
	for i = 0, n - 1 do a1[i] = 0.0; b1[i] = 0.0 end
	fft1r2_fwd(a0, a1, b0, b1, n, p)
	return to1(a0, n), to1(a1, n), to1(b0, n), to1(b1, n)
end

-- 双实序列逆变换
function FFT.ifft_real2(are, aim, bre, bim)
	local n = #are
	check_pow2(n, "input length")
	local p = plan(n)
	local a0 = to0(are, n, "are")
	local a1 = to0(aim, n, "aim")
	local b0 = to0(bre, n, "bre")
	local b1 = to0(bim, n, "bim")
	fft1r2_inv(a0, a1, b0, b1, n, p)
	return to1(a0, n), to1(b0, n)
end

-- 单实序列变换：x 长 2N → 全谱 re/im 各长 2N（含共轭镜像）
function FFT.fft_real(x)
	local dn = #x
	check_pow2(dn, "input length")
	local n = math.floor(dn / 2)
	local p = plan(n)

	-- 奇偶分解：c = 偶数项，d = 奇数项
	local c0, c1, d0, d1 = {}, {}, {}, {}
	for k = 0, n - 1 do
		c0[k] = tonumber(x[2 * k + 1]) or error("x[" .. (2 * k + 1) .. "] is not a number")
		d0[k] = tonumber(x[2 * k + 2]) or error("x[" .. (2 * k + 2) .. "] is not a number")
		c1[k] = 0.0
		d1[k] = 0.0
	end
	fft1r2_fwd(c0, c1, d0, d1, n, p)

	-- 半谱合并：X[j] = C[j] + W^j·D[j]，W^j = e^{-iπj/N}
	local hunit = math.pi / n
	local re, im = {}, {}
	for j = 0, n - 1 do
		local tt = j * hunit
		local cosj = math.cos(tt)
		local sinj = -math.sin(tt)	-- C 版 sign·sin，sign=-1
		re[j] = c0[j] + cosj * d0[j] - sinj * d1[j]
		im[j] = c1[j] + cosj * d1[j] + sinj * d0[j]
	end
	re[n] = c0[0] - d0[0]
	im[n] = c1[0] - d1[0]
	for j = 1, n - 1 do
		re[dn - j] = re[j]		-- 共轭镜像
		im[dn - j] = -im[j]
	end

	return to1(re, dn), to1(im, dn)
end

-- 单实序列逆变换（已补全 C 版缺失的 d1 计算）
function FFT.ifft_real(re, im)
	local dn = #re
	check_pow2(dn, "input length")
	if #im ~= dn then
		error("re and im must have the same length")
	end
	local n = math.floor(dn / 2)
	local p = plan(n)
	local A0 = to0(re, dn, "re")
	local A1 = to0(im, dn, "im")

	-- 实数性检查：X 须满足共轭对称 X[dn-j] = conj(X[j])
	for j = 0, n - 1 do
		local norm
		if j == 0 then
			norm = 2.0 * math.abs(A1[0])
		else
			norm = math.abs(A1[j] + A1[dn - j])
			     + math.abs(A0[j] - A0[dn - j])
		end
		if norm > eps then
			error("The IDFT of the series {xj} isn't real!")
		end
	end

	-- 拆半谱：C[j] = (X[j]+X[j+N])/2；D[j] = W^-j·(X[j]-X[j+N])/2
	local hunit = math.pi / n
	local c0, c1, d0, d1 = {}, {}, {}, {}
	for j = 0, n - 1 do
		c0[j] = 0.5 * (A0[j] + A0[n + j])
		c1[j] = 0.5 * (A1[j] + A1[n + j])
		local tt = j * hunit
		local cosj = math.cos(tt)
		local sinj = math.sin(tt)	-- C 版 -sign·sin，sign=-1
		local dre = A0[j] - A0[n + j]
		local dim = A1[j] - A1[n + j]
		d0[j] = 0.5 * (cosj * dre - sinj * dim)
		d1[j] = 0.5 * (cosj * dim + sinj * dre)	-- 原版缺失，按推导补全
	end
	fft1r2_inv(c0, c1, d0, d1, n, p)

	-- 奇偶交织回实序列
	local x = {}
	for k = 0, n - 1 do
		x[2 * k + 1] = c0[k]
		x[2 * k + 2] = d0[k]
	end
	return x
end

return FFT
