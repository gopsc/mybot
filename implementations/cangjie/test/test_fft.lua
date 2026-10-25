-- fft.lua 单元测试（lua5.4 与 luajit 均可运行）
-- 核心验证：与 O(N²) 暴力 DFT 交叉对照 + 三层 API 往返 + 已知解析值 + 错误路径
-- 用法（项目根目录）: lua5.4 test/test_fft.lua

local passed, failed = 0, 0
local function check(label, cond, detail)
	if cond then
		passed = passed + 1
		print("[PASS] " .. label)
	else
		failed = failed + 1
		print("[FAIL] " .. label .. (detail ~= nil and ("  | " .. tostring(detail)) or ""))
	end
end

local FFT = dofile("modules/lib/fft.lua")

------------------------------------------------------------------
-- 参考实现：暴力 DFT（1 基，inverse 时除 N）
------------------------------------------------------------------
local function dft_ref(re, im, inverse)
	local n = #re
	local ore, oim = {}, {}
	local sgn = inverse and 1 or -1
	for k = 1, n do
		local sr, si = 0.0, 0.0
		for j = 1, n do
			local ang = sgn * 2 * math.pi * (k - 1) * (j - 1) / n
			local c, sn = math.cos(ang), math.sin(ang)
			sr = sr + re[j] * c - im[j] * sn
			si = si + re[j] * sn + im[j] * c
		end
		if inverse then sr, si = sr / n, si / n end
		ore[k], oim[k] = sr, si
	end
	return ore, oim
end

local function maxdiff(a, b)
	local m = 0
	for i = 1, #a do
		local d = math.abs(a[i] - b[i])
		if d > m then m = d end
	end
	return m
end

-- 确定性伪随机（线性同余，跨解释器一致）
local seed = 987654321
local function rnd()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end
local function rand_vec(n, scale)
	local t = {}
	for i = 1, n do t[i] = (rnd() - 0.5) * 2 * (scale or 1) end
	return t
end

local TOL = 1e-8

------------------------------------------------------------------
-- 已知解析值
------------------------------------------------------------------
do	-- 冲激 δ → 全 1 谱
	local re = { 1, 0, 0, 0, 0, 0, 0, 0 }
	local fr, fi = FFT.fft(re)
	local ok = true
	for k = 1, 8 do
		if math.abs(fr[k] - 1) > TOL or math.abs(fi[k]) > TOL then ok = false end
	end
	check("冲激信号 → 平坦谱(全1)", ok)
end

do	-- 直流 → 仅 bin0 = N
	local re = {}
	for i = 1, 8 do re[i] = 1 end
	local fr, fi = FFT.fft(re)
	check("直流信号 → bin0=N 其余为0",
		math.abs(fr[1] - 8) < TOL and math.abs(fr[2]) < TOL and math.abs(fi[1]) < TOL)
end

do	-- 纯余弦（bin 2，N=16）→ 两根谱线各 N/2
	local re = {}
	for j = 1, 16 do re[j] = math.cos(2 * math.pi * 2 * (j - 1) / 16) end
	local fr, fi = FFT.fft(re)
	check("余弦 bin2 → |X[3]|=|X[15]|=N/2",
		math.abs(fr[3] - 8) < TOL and math.abs(fr[15] - 8) < TOL
		and math.abs(fi[3]) < TOL and math.abs(fr[4]) < TOL)
end

------------------------------------------------------------------
-- 与暴力 DFT 交叉验证（复数路径）
------------------------------------------------------------------
for _, n in ipairs({ 8, 16, 32, 64 }) do
	local re, im = rand_vec(n), rand_vec(n)
	local er, ei = dft_ref(re, im, false)
	local fr, fi = FFT.fft(re, im)
	check(string.format("fft N=%d 对照暴力DFT", n),
		maxdiff(fr, er) < TOL and maxdiff(fi, ei) < TOL,
		string.format("re=%.2e im=%.2e", maxdiff(fr, er), maxdiff(fi, ei)))

	local ir, ii = dft_ref(fr, fi, true)	-- 参考 IDFT 作用于同一份频谱
	local gr, gi = FFT.ifft(fr, fi)
	check(string.format("ifft N=%d 对照暴力IDFT", n),
		maxdiff(gr, ir) < TOL and maxdiff(gi, ii) < TOL)
end

------------------------------------------------------------------
-- 复数往返
------------------------------------------------------------------
do
	local n = 32
	local re, im = rand_vec(n), rand_vec(n)
	local fr, fi = FFT.fft(re, im)
	local br, bi = FFT.ifft(fr, fi)
	check("复数往返 ifft(fft(x))=x",
		maxdiff(br, re) < TOL and maxdiff(bi, im) < TOL)
end

------------------------------------------------------------------
-- 实序列路径（fft1r1）
------------------------------------------------------------------
do
	local dn = 32
	local x = rand_vec(dn)
	-- 交叉验证：fft_real 应等于把 x 当复数（虚部0）直接 fft
	local sr, si = FFT.fft_real(x)
	local zr = {}
	for i = 1, dn do zr[i] = 0 end
	local cr, ci = FFT.fft(x, zr)
	check("fft_real 对照复数 fft", maxdiff(sr, cr) < TOL and maxdiff(si, ci) < TOL,
		string.format("re=%.2e im=%.2e", maxdiff(sr, cr), maxdiff(si, ci)))

	-- 共轭对称性
	local herm = true
	for j = 2, dn / 2 do
		if math.abs(sr[dn - j + 2] - sr[j]) > TOL
		   or math.abs(si[dn - j + 2] + si[j]) > TOL then herm = false end
	end
	check("fft_real 输出共轭对称", herm)

	-- 往返（验证补全的 d1：C 原版此路径必失败）
	local xb = FFT.ifft_real(sr, si)
	check("实序列往返 ifft_real(fft_real(x))=x", maxdiff(xb, x) < TOL,
		string.format("maxdiff=%.2e", maxdiff(xb, x)))
end

------------------------------------------------------------------
-- 双实序列路径（fft1r2）
------------------------------------------------------------------
do
	local n = 16
	local xa, xb = rand_vec(n), rand_vec(n)
	local are, aim, bre, bim = FFT.fft_real2(xa, xb)

	-- 交叉验证：各自谱应等于单独复数 fft
	local z = {}
	for i = 1, n do z[i] = 0 end
	local ar, ai = FFT.fft(xa, z)
	local br, bi = FFT.fft(xb, z)
	check("fft_real2 之 A 谱对照复数 fft", maxdiff(are, ar) < TOL and maxdiff(aim, ai) < TOL)
	check("fft_real2 之 B 谱对照复数 fft", maxdiff(bre, br) < TOL and maxdiff(bim, bi) < TOL)

	local xa2, xb2 = FFT.ifft_real2(are, aim, bre, bim)
	check("双实序列往返 ifft_real2(fft_real2)=x",
		maxdiff(xa2, xa) < TOL and maxdiff(xb2, xb) < TOL)
end

------------------------------------------------------------------
-- 错误路径
------------------------------------------------------------------
check("非 2 的幂长度报错", pcall(FFT.fft, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }) == false)
check("re/im 长度不一致报错", pcall(FFT.ifft_real, { 1, 0, 1, 0 }, { 0, 0, 0 }) == false)
check("非数值元素报错", pcall(FFT.fft, { 1, "x", 3, 4 }) == false)
do	-- 非共轭对称谱做 ifft_real 应报实数性错误
	local re = { 1, 2, 3, 4, 5, 6, 7, 8 }
	local im = { 0, 1, 1, 1, 0, 1, 1, 1 }
	check("ifft_real 非实数谱报错", pcall(FFT.ifft_real, re, im) == false)
end

print(string.format("结果: %d 通过, %d 失败", passed, failed))
if failed > 0 then os.exit(1) end
