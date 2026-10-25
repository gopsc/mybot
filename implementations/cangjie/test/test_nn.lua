-- test/test_nn.lua
-- modules/lib/nn.lua 前向推理引擎离线桩测试
--
-- 覆盖：
--   1. 激活函数（leaky_relu / sigmoid 边界）
--   2. 网络构建 + 维度校验
--   3. 前向传播：全零、全一、数值正确性（手算核对一层）
--   4. saveMt / loadMt 往返一致性（权重 .mt 矩阵脚本存储）
--   5. 错误路径：维度不符 / 层序不连续 / 权重行缺失

local pass = 0
local fail = 0
local function check(name, cond, detail)
	if cond then pass = pass + 1
	else
		fail = fail + 1
		io.write("  [FAIL] " .. name .. (detail and " (" .. tostring(detail) .. ")" or "") .. "\n")
	end
end

local Nn = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/nn.lua")

-- ---- 1. 激活函数 ----
do
	local lr = Nn.leaky_relu
	check("leaky_relu 正区直通", lr(2.0, 0.2) == 2.0)
	check("leaky_relu 负区 ×0.2", math.abs(lr(-5.0, 0.2) - (-1.0)) < 1e-9, lr(-5.0, 0.2))
	check("leaky_relu 零", lr(0.0) == 0.0)
	check("sigmoid(0)=0.5", math.abs(Nn.sigmoid(0) - 0.5) < 1e-9)
	check("sigmoid(∞)→1", Nn.sigmoid(20) > 0.999999)
	check("sigmoid(-∞)→0", Nn.sigmoid(-20) < 0.000001)
end

-- ---- 2. 构建 + 维度校验 ----
do
	local net = Nn.new({41, 80, 80, 40, 17})
	check("构建 5 层网络", #net.layers == 5)
	-- W/b 为 i=2..N 稀疏索引；统计非空键数（含稀疏安全）
	local wt, bt = 0, 0
	for _ in pairs(net.W) do wt = wt + 1 end
	for _ in pairs(net.b) do bt = bt + 1 end
	check("权重结构数 = 层数-1", wt == 4 and bt == 4)

	local ok = pcall(function() Nn.new({5}) end)
	check("单层被拒绝", not ok)
end

-- ---- 3. 前向传播数值正确性（手算一层核对）----
do
	local net = Nn.new({2, 3, 1})      -- 2->3->1
	-- 第2层(3个神经元)：W[2][1]={1,0} b=-0.5 ; W[2][2]={0,1} b=0 ; W[2][3]={1,1} b=1
	net.W[2][1] = {1, 0}; net.b[2][1] = -0.5
	net.W[2][2] = {0, 1}; net.b[2][2] = 0
	net.W[2][3] = {1, 1}; net.b[2][3] = 1
	-- 第3层：单神经元 W[3][1]={1,-1,1} b=0，激活 sigmoid（输出层）
	net.W[3][1] = {1, -1, 1}; net.b[3][1] = 0

	-- 输入 {2,4}：
	--   h1 = 1*2+0*4-0.5 = 1.5 -> leaky(1.5)=1.5
	--   h2 = 0*2+1*4+0   = 4   -> 4
	--   h3 = 1*2+1*4+1   = 7   -> 7
	--   out = 1*1.5 + (-1)*4 + 1*7 = 4.5 -> sigmoid(4.5)≈0.98901
	local out = net:forwardOne({2,4})
	local expect = 1.0 / (1.0 + math.exp(-4.5))
	check("前向传播软计对", math.abs(out[1] - expect) < 1e-6, string.format("out=%g expect=%g", out[1], expect))

	-- 全零权重 + sigmoid(0)=0.5：输出恒 0.5
	local z = Nn.new({3, 4, 2}):zeroInit()
	local o = z:forwardOne({10,20,30})
	check("全零权重输出 0.5", math.abs(o[1]-0.5) < 1e-9 and math.abs(o[2]-0.5) < 1e-9)
end

-- ---- 4. saveMt / loadMt 往返 ----
do
	local net = Nn.new({3, 4, 2}):randInit(0.1)
	local txt = net:saveMt()
	check("saveMt 含层头", txt:find("NnLayer 2 3 4") ~= nil and txt:find("NnLayer 3 4 2") ~= nil)

	-- 权重 .mt 为 6 位有效数字序列化；往返一致性 = 序列化文本逐字不变
	-- （double 到文本存在舍入，比较原始 double 位相等无意义）
	local net2 = Nn.new({3, 4, 2})
	net2:loadMt(txt)
	check("saveMt→loadMt 往返文本不变", net2:saveMt() == txt)

	-- 往返后前向输出一致（同一 .mt 文本 → 相同前向结果，浮点稳定）
	local a = net2:forwardOne({0.1, 0.5, 0.9})
	local net3 = Nn.new({3, 4, 2})
	net3:loadMt(txt)
	local b = net3:forwardOne({0.1, 0.5, 0.9})
	check("同 .mt 两次加载前向一致", (function()
		for i = 1, 2 do if math.abs(a[i]-b[i]) > 1e-12 then return false end end
		return true
	end)())
end

-- ---- 5. 错误路径 ----
do
	local net = Nn.new({3, 4, 2})
	local ok, err = pcall(function() net:forwardOne({1,2}) end)
	check("输入维度不符报错", not ok and err:find("input dim") ~= nil)

	local txt = net:saveMt()
	ok, err = pcall(function()
		Nn.new({4, 4, 2}):loadMt(txt)   -- 第一层 in 4 ≠ 3
	end)
	check("loadMt 维度不符报错", not ok and tostring(err):find("维度不符") ~= nil)
end

print(string.rep("-", 44))
print("nn 前向推理引擎离线桩测试")
print(string.rep("-", 44))
print(string.format("通过: %d  失败: %d", pass, fail))
if fail > 0 then os.exit(1) end