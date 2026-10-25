/*
 * @Merge 展开夹具（旧名 @Include，2026-10-12 改名）：两路 Relay + Timer。
 * @Merge 归并要求设备集不相交：r1 只由 include_a.mt 驱动、r2 只由
 * include_b.mt 驱动，timer-0 只出现在主脚本（include_main.mt）的 @Action——
 * 谁越界谁触发 "appears in both scripts"（include_overlap.mt 的负值契约）。
 */
CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('timer-0');

CREATE TABLE Relay (
	name       String,
	controller String,
	note       String
);
INSERT INTO Relay (name, controller, note) VALUES ('r1', 'timer-0', 'inc-a');
INSERT INTO Relay (name, controller, note) VALUES ('r2', 'timer-0', 'inc-b');
INSERT INTO Relay (name, controller, note) VALUES ('r3', 'timer-0', 'inc-shared');
