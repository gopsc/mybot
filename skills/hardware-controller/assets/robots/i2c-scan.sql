/*
 * I2C 总线扫描示例
 *
 * 声明一个 I2C_scan 变量，激活后通过 MT 动作触发扫描，
 * 返回总线上所有 ACK 的 7-bit 地址列表。
 *
 * 物理设备需要 --allow-hardware；virt-* 路径无需。
 */

CREATE TABLE I2C_scan (
    name String,
    path String
);

/* 扫描 /dev/i2c-1 上的所有设备（默认范围 0x08-0x77） */
INSERT INTO I2C_scan (name, path) VALUES ('scan0', '/dev/i2c-1');
