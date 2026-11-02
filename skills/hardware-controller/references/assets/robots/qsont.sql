-- Qsont 云端网关：注册 iot 账号、建设备、推/拉数据共用这一份结构。
-- 账号密码放在 Alias，device 放在 Vars，激活前可用 --var/--var-env 覆盖：
--   --var-env user=QS_USER --var-env pass=QS_PASS --var device=<设备 id>
-- device=0 表示尚未建设备；op=create 成功后会采用服务端返回的新 id。
--
-- 激活时 Qsont 驱动会用 user/pass 先登录，因此本结构要求账号已经存在。
-- 首次注册可手工调用（device_type 必须是 iot）：
--   curl -X POST https://qsont.me:8004/api/v1/users/register \
--     -H 'Content-Type: application/json' \
--     -d '{"username":"iot_01","password":"pass123","device_type":"iot"}'
-- qsont.me 是非回环地址，run 需要 --allow-hardware；本地调试把 base 换成
-- http://127.0.0.1:8000/api/v1 即可免去该开关。
CREATE TABLE Alias (name String, alias String);
INSERT INTO Alias (name, alias) VALUES ('user', 'COVER_ME');
INSERT INTO Alias (name, alias) VALUES ('pass', 'COVER_ME');
CREATE TABLE Vars (name String, value String);
INSERT INTO Vars (name, value) VALUES ('device', 0);
CREATE TABLE HTTP (name String, base String, timeout Number);
INSERT INTO HTTP (name, base, timeout) VALUES ('cloud', 'https://qsont.me:8004/api/v1', 10000);
CREATE TABLE Qsont (name String, HTTP String, user String, pass String, device Number);
INSERT INTO Qsont (name, HTTP, user, pass, device) VALUES ('qs', '$cloud', '$user', '$pass', '$(device)');
