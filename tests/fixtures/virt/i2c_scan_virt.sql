/*
 * I2C 总线扫描示例（虚拟总线版）
 *
 * 使用 virt-bus0 虚拟总线，无需物理设备，适合测试。
 */

CREATE TABLE I2C_scan (
    name String,
    path String
);

INSERT INTO I2C_scan (name, path) VALUES ('scan0', 'virt-bus0');
