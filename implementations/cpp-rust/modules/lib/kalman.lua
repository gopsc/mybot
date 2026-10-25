-- kalman.lua - 一维卡尔曼滤波器
-- bot4cj 仓颉语言机器人框架
-- 自 src/math/kalman.cj（extKalman）移植为 Lua 模块（返回表风格，供驱动 dofile 使用）
--
-- 用法：
--   local Kalman = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/kalman.lua")
--   local kf = Kalman.new(20, 200)       -- Q=系统噪声协方差, R=测量噪声协方差
--   while true do
--       local raw = sensor()             -- 读到传感器数据
--       local filtered = kf:filter(raw)  -- 滤波
--   end
--
-- 参数说明（与原仓颉版一致）：
--   R 固定；Q 越大越信任测量值（Q 无穷 = 只用测量值），
--   Q 越小越信任模型预测（Q 为 0 = 只用模型预测）

local Kalman = {}
Kalman.__index = Kalman

-- 创建滤波器（A=1、B=0、H=1 的一维模型）
-- 卡尔曼五个核心公式（一阶 H' 即其本身，否则为转置矩阵）：
--   (1) X(k|k-1) = A*X(k-1|k-1) + B*U(k) + W(k)
--   (2) P(k|k-1) = A*P(k-1|k-1)*A' + Q
--   (3) X(k|k)   = X(k|k-1) + kg(k)*(Z(k) - H*X(k|k-1))
--   (4) kg(k)    = P(k|k-1)*H' / (H*P(k|k-1)*H' + R)
--   (5) P(k|k)   = (I - kg(k)*H) * P(k|k-1)
function Kalman.new(Q, R)
	Q = tonumber(Q)
	R = tonumber(R)
	if Q == nil or R == nil then
		error("Kalman.new: Q and R must be numbers")
	end
	-- NaN 防线（2026-09-20 评估）：`Q < 0` / `R <= 0` 对 NaN 均为假 → NaN 会
	-- 穿过检查进入滤波器，输出整条 NaN 序列且驱动返回 OK。±inf 是**允许**的
	-- 既有语义（Q 无穷 = 只用测量值，见上方参数说明），故只显式拒 NaN；
	-- inf 的 kg=inf/inf 由 filter 按极限处理（2026-09-20 修复）。
	if Q ~= Q then
		error("Kalman.new: Q must not be NaN (system noise covariance)")
	end
	if R ~= R then
		error("Kalman.new: R must not be NaN (measurement noise covariance)")
	end
	if Q < 0 then
		error("Kalman.new: Q must be >= 0 (system noise covariance)")
	end
	if R <= 0 then
		error("Kalman.new: R must be > 0 (measurement noise covariance)")
	end
	return setmetatable({
		X_last = 0.0,	-- 上一时刻的最优结果 X(k-1|k-1)
		P_last = 0.0,	-- 上一时刻最优结果的协方差 P(k-1|k-1)
		A = 1.0,	-- 系统参数
		B = 0.0,
		Q = Q,		-- 系统噪声协方差
		R = R,		-- 测量噪声协方差
		H = 1.0,
	}, Kalman)
end

-- 滤波：输入待滤波数据，返回滤波后的值 X(k|k)
-- Z(k) 是测量值；W(k)/V(k) 为叠加在测量值上的高斯白噪声，无需显式处理
function Kalman:filter(dat)
	dat = tonumber(dat)
	if not (dat ~= nil and dat > -math.huge and dat < math.huge) then
		error("Kalman:filter: data must be a finite number")
	end
	local X_mid = self.A * self.X_last			-- 公式(1)
	local P_mid = self.A * self.P_last + self.Q		-- 公式(2)
	-- Q=±inf 时 P_mid 发散，kg = P_mid/(P_mid+R) = inf/inf = NaN，会污染整条
	-- 后续输出（2026-09-20 审计遗留）。既有语义「Q 无穷 = 只用测量值」：
	-- kg→1 的极限即输出测量值本身；P 回落 (1-kg)*P_mid = P_mid*R/(P_mid+R)，
	-- 极限为 R。直接取极限，避免 inf/inf。R 恒有限（new 已拒 NaN 与 ≤0）。
	local kg, X_now
	if P_mid == math.huge or P_mid == -math.huge then
		kg = 1.0
		X_now = dat
		self.P_last = self.R
	else
		kg = P_mid / (P_mid + self.R)			-- 公式(4)
		X_now = X_mid + kg * (dat - X_mid)		-- 公式(3)
		self.P_last = (1.0 - kg) * P_mid		-- 公式(5)
	end
	self.X_last = X_now
	return X_now					-- 输出预测结果 X(k|k)
end

return Kalman
