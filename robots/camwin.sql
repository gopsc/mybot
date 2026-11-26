-- Windows 摄像头（PyAV / DirectShow）。path 是设备序号，0 表示枚举到的第一个摄像头。
-- width/height 必须是摄像头实际支持的模式；不支持时打开会失败，不会自动改分辨率。
-- 只做声明读取，不激活设备：pymybot hardware --robot robots/camwin.sql
CREATE TABLE Camera (name String, path String, width Number, height Number);
INSERT INTO Camera (name, path, width, height) VALUES ('cam', '0', 640, 480);
