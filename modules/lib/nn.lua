-- nn.lua - 神经网络前向推理引擎（全连接 MLP，纯 Lua 实现）
-- bot4cj 仓颉语言机器人框架
--
-- 背景：bot4cj 历史上用仓颉 + nn4cj 库做面向机器人的神经网络（NN/DRL），
-- 但 nn4cj 更换后开发机无法编译（main.cj 注释保留，README「待实现功能」）。
-- 本模块用纯 Lua 实现等价的**前向推理**，不依赖任何 C 扩展，可离线桩测试。
--
-- 目标网络架构（与 main.cj 历史 Nn 层一致）：
--   [41] -> FC(80, LeakyReLU α=0.2) -> FC(80, LeakyReLU) -> FC(40, LeakyReLU)
--        -> FC(17, Sigmoid)          -- 17 输出 = 16 舵机 + 1 时延
--
-- 支持：
--   .new(layers, opts)           构建网络（layers = 各层神经元数列表，如 {41,80,80,40,17}）
--   :forward(input)              前向传播，返回各层输出 table（out[#] 为最终输出）
--   :forwardOne(input)           便捷：只返回最终输出层（一维 table）
--   :zeroInit() / :randInit(...) 权重初始化
--   :loadMt(string) / :saveMt()  权重以 .mt 矩阵脚本文本存取（r.cj 的 TODO：用矩阵脚本存储 NN 权重）
--
-- 激活函数：
--   leaky_relu(x, slope)  默认 slope=0.2；sigmoid(x) 用于输出层（舵机位置 ∈[0,1]）
--
-- 【26.4 库能力面断言】截至 2026-10-06 全仓 grep 仅 test/test_nn.lua 加载本库，
-- 无生产消费者（docs/architecture_analysis.html 提及是阶段 5 路线图，属冻结快照，
-- 不是加载点）。由 test_nn.lua 单测守前向推理与梯度对齐面。
--
-- 用法：
--   local Nn = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/nn.lua")
--   local net = Nn.new({41,80,80,40,17})
--   net:randInit(0.1)
--   local out = net:forwardOne(inputVec)      -- 41 维输入 -> 17 维输出

local Nn = {}
Nn.__index = Nn

-- 有限值校验（2026-09-20 审计收口）：权重由外部 .mt 文本加载、输入由外部
-- 提供，二者都是不可信边界。NaN/inf 一旦进入，会沿 sigmoid/leaky_relu 静默
-- 传播成整段 NaN 输出却返回 OK（与 kalman/ema 的 finite_of 拒法口径一致）。
-- 返回 nil 表示「非有限」，由调用方决定给拒不参与运算。
local function is_finite(x)
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- 激活函数
local function leaky_relu(x, slope)
	slope = slope or 0.2
	if x >= 0 then return x else return slope * x end
end
local function sigmoid(x)
	if x >= 0 then
		local e = math.exp(-x)
		return 1.0 / (1.0 + e)
	else
		local e = math.exp(x)
		return e / (1.0 + e)
	end
end
Nn.leaky_relu = leaky_relu
Nn.sigmoid = sigmoid

-- 构建网络
--   layers: 各层神经元数，如 {41,80,80,40,17}（首=输入维度）
--   opts.act: 激活函数策略。缺省 {slope=0.2, outAct="sigmoid"}
--             即隐含层 LeakyReLU(slope=0.2) + 输出层 Sigmoid
function Nn.new(layers, opts)
	if type(layers) ~= "table" or #layers < 2 then
		error("nn.new: layers must be a table with >=2 dims")
	end
	opts = opts or {}
	local act = opts.act or {}
	local slope = act.slope or 0.2
	local outAct = act.outAct or "sigmoid"

	-- 为每一层 (i>0) 建立权重矩阵 W[in][out] 与偏置 b[out]
	-- 用 |out| 个 row，每个 row 存 [in] 个权重，便于 .mt 行式存储
	local W, b = {}, {}
	for i = 2, #layers do
		local nin, nout = layers[i-1], layers[i]
		W[i] = {}
		b[i] = {}
		for o = 1, nout do
			W[i][o] = {}
			for k = 1, nin do W[i][o][k] = 0.0 end
			b[i][o] = 0.0
		end
	end
	return setmetatable({ layers = layers, W = W, b = b, slope = slope, outAct = outAct }, Nn)
end

-- 前向传播。input 为一维 table（长度 = layers[1]）。
-- 返回各层激活后的输出 table：out[i] 为第 i 层输出（i=1 即原始输入）。
function Nn:forward(input)
	if type(input) ~= "table" then error("nn.forward: input must be a table") end
	local L = self.layers
	if #input ~= L[1] then
		error(string.format("nn.forward: input dim %d != expected %d", #input, L[1]))
	end
	-- 输入非有限即拒绝：一旦有 NaN 进入，sigmoid/leaky_relu 会把它静默传播
	-- 成整段 NaN 输出，驱动无从察觉（C2 防线口径）。
	for k = 1, #input do
		if not is_finite(input[k]) then
			error(string.format("nn.forward: input[%d] is not a finite number", k))
		end
	end
	local out = { input }          -- 0 层激活即输入
	for i = 2, #L do
		local nin, nout = L[i-1], L[i]
		local prev = out[i-1]
		local cur = {}
		local isLast = (i == #L)
		for o = 1, nout do
			local acc = self.b[i][o]
			local row = self.W[i][o]
			for k = 1, nin do acc = acc + row[k] * prev[k] end
			if isLast and self.outAct == "sigmoid" then
				cur[o] = sigmoid(acc)
			else
				cur[o] = leaky_relu(acc, self.slope)
			end
		end
		out[i] = cur
	end
	return out
end

-- 便捷：只返回最终输出（一维 table）
function Nn:forwardOne(input)
	local out = self:forward(input)
	return out[#out]
end

-- 权重清零
function Nn:zeroInit()
	for i = 2, #self.layers do
		local nout = self.layers[i]
		for o = 1, nout do
			for k = 1, #self.W[i][o] do self.W[i][o][k] = 0.0 end
			self.b[i][o] = 0.0
		end
	end
	return self
end

-- 随机初始化（Xavier-like）：取值 ~ U(-scale, scale)，每层 scale = sqrt(1/nin)
function Nn:randInit(scale)
	scale = scale or 0.3
	math.randomseed(os.time())
	for i = 2, #self.layers do
		local nout = self.layers[i]
		local nin = self.layers[i-1]
		local s = scale / math.sqrt(nin)
		for o = 1, nout do
			for k = 1, nin do self.W[i][o][k] = (math.random() * 2 - 1) * s end
			self.b[i][o] = (math.random() * 2 - 1) * s
		end
	end
	return self
end

-- 将权重序列化为 .mt 矩阵脚本文本。
-- 格式（每层一段 + 头部）：
--   // NN weights v1
--   NnLayer <id> <in> <out> <act>
--   <每行: 该 out 神经元的 in 个权重，空格分隔，最后跟偏置>
function Nn:saveMt()
	local parts = { "// NN weights v1" }
	for i = 2, #self.layers do
		local nin, nout = self.layers[i-1], self.layers[i]
		local act = (i == #self.layers and self.outAct == "sigmoid") and "sigmoid" or "leaky_relu"
		table.insert(parts, string.format("NnLayer %d %d %d %s", i, nin, nout, act))
		for o = 1, nout do
			local row = self.W[i][o]
			local line = { string.format("%.6g", self.b[i][o]) }
			for k = 1, nin do line[#line+1] = string.format("%.6g", row[k]) end
			table.insert(parts, table.concat(line, " "))
		end
	end
	return table.concat(parts, "\n") .. "\n"
end

-- 从 .mt 文本加载权重（与 saveMt 对称）
-- 协议：headers ≤ 3 行（以 // 开头的注释跳过），之后为
--   NnLayer <id> <in> <out> <act>   层头
--   <权重行 × out 行>                每行先偏置后 in 个权重，空格分隔
-- 严格按行序消费，维度逐层校验，负载全读后报错。
function Nn:loadMt(text)
	local lines = {}
	for raw in text:gmatch("[^\r\n]+") do
		local s = raw:gsub("//.*", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
		if s ~= "" then lines[#lines+1] = s end
	end
	local pos = 1
	local expectLayer = 2                 -- 下一层头应声明的 id
	while pos <= #lines do
		local head = lines[pos]:match("^NnLayer")
		if not head then
			error("nn.loadMt: expected NnLayer header, got: " .. lines[pos])
		end
		local m1, m2, m3, m4 = lines[pos]:match("NnLayer (%d+) (%d+) (%d+) (%S+)")
		local id, in_, out = tonumber(m1), tonumber(m2), tonumber(m3)
		local act = m4
		pos = pos + 1
		if id ~= expectLayer then
			error(string.format("nn.loadMt: non-contiguous layer id, expected %d got %d", expectLayer, id))
		end
		if in_ ~= self.layers[id-1] or out ~= self.layers[id] then
			error(string.format("nn.loadMt: layer %d dimension mismatch (%d,%d), expected (%d,%d)",
				id, in_, out, self.layers[id-1], self.layers[id]))
		end
		-- 期望的输出激活类型
		local want = (id == #self.layers and self.outAct == "sigmoid") and "sigmoid" or "leaky_relu"
		if act ~= want then
			error(string.format("nn.loadMt: layer %d activation %s != expected %s", id, act, want))
		end
		-- 读 out 行权重（每行 in+1 个数：bias + in 权重）
		for o = 1, out do
			if pos > #lines then error("nn.loadMt: weight row missing, layer " .. id .. " row " .. o) end
			local nums = {}
			for tok in lines[pos]:gmatch("%S+") do nums[#nums+1] = tonumber(tok) end
			if #nums ~= in_ + 1 then
				error(string.format("nn.loadMt: layer %d row %d element count %d != %d", id, o, #nums, in_+1))
			end
			-- 权重非有限即整层拒绝：loadMt 是从外部文本载入权重的边界，NaN/inf
			-- 权重会把整条推理链路静默污染（C2 防线口径，与 kalman/ema 一致）。
			for ei = 1, #nums do
				if not is_finite(nums[ei]) then
					error(string.format("nn.loadMt: layer %d row %d weight %d is not a finite number",
						id, o, ei))
				end
			end
			self.b[id][o] = nums[1]
			for k = 1, in_ do self.W[id][o][k] = nums[k+1] end
			pos = pos + 1
		end
		expectLayer = expectLayer + 1
	end
	if expectLayer ~= #(self.layers) + 1 then
		error(string.format("nn.loadMt: insufficient layers, expected top layer %d, got to %d", #(self.layers), expectLayer-1))
	end
	return self
end

return Nn