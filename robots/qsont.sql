-- Qsont 云端网关示例：对本地 qsont iot-server（默认 http://127.0.0.1:8000）
-- 回环端点免 --allow-hardware。先在服务端完成一次性准备（脚本/网页均可）：
--   1. 注册 iot 账号：POST /api/v1/users/register {username, password, device_type:"iot"}
--   2. 创建设备记下 id：POST /api/v1/devices {"device_name": "..."} → 响应里的 id
-- 再把下面的 user/pass/device 换成实际值。
CREATE TABLE HTTP (name String, base String, timeout Number);
INSERT INTO HTTP (name, base, timeout) VALUES ('cloud', 'http://127.0.0.1:8000/api/v1', 5000);
CREATE TABLE Qsont (name String, HTTP String, user String, pass String, device Number);
INSERT INTO Qsont (name, HTTP, user, pass, device) VALUES ('qs', '$cloud', 'iot_01', 'pass123', 1);
