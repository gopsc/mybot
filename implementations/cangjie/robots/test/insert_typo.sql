-- 负路径回归用例：INSERT 目标表名拼错（Timerr ≠ Timer）
-- 期望：解析期显式报错并以退出码 1 终止，错误信息含
-- 「INSERT INTO 'Timerr': table is not defined」——
-- 原实现静默跳过整条 INSERT，timer-0 无声消失，错误延迟到动作期
-- 以误导性信息（'timer-0' not defined）暴露。
-- 验证：cat scripts/relay-test.mt | bash _run.sh --robot=robots/test/insert_typo.sql
--       退出码应为 1（非 0）
CREATE TABLE Timer (
	name String
);
INSERT INTO Timerr (name) VALUES ('timer-0');
