/*
 * SCSCL 总线舵机 · 无硬件端到端（proto=virt，@Action 直写路径，UART 1M）
 *
 * 链路：UART 总线行（proto=virt）注入虚拟 tty —— 1M 波特率为 SCSCL 出厂
 * 默认档（HAL 白名单含 500000/1000000）——自己的 uart_open 变成虚拟 open
 * 并下发 fd/path；器件行（SCSCL，BUS="uart" 模型 SCSCL_VIRT 内嵌于
 * modules/SCSCL.lua 尾部）经 drv_common 前置 attach_uart + adopt fd，
 * 跑的是【真实】SCSCL.lua：PING 探测、0x2A 六字节大端位置/时间/速度帧、
 * 限幅管线、0x28 扭矩与 destroy 扭矩关闭全部由模型逐帧校验。
 *
 * 用法：cat scripts/test/scscl_virt.mt | ./build/mybot --robot=robots/test/scscl_virt.sql
 */
CREATE TABLE UART (
	name  String,
	path  String,
	baud  String,
	proto String
);
/* 故意用不存在但格式合法的串口名：virt 态下按模式白名单校验照常仿真；
 * 一旦 virt 前置回归，真实 uart_open 会失败并响亮报错——绝不让「无硬件
 * 测试」在插着舵机的机器上真的打开串口写帧。 */
INSERT INTO UART (name, path, baud, proto)
  VALUES ('uart-0', '/dev/serial9', '1000000', 'virt');

/* id 是结构元数据（站号），位置/时间/速度才是动作参数。
 * allow_burn=1 是审计 H-3 防线的结构期授权列：set_id 烧号（不可逆广播写）
 * 只有在结构脚本显式声明后才可由动作参数触发——本表授权以覆盖正值链路。 */
CREATE TABLE SCSCL (
        name       String,
        UART       String,
        id         String,
        max        String,
        min        String,
        offset     String,
        allow_burn String,
        proto      String
);
INSERT INTO SCSCL (name, UART, id, max, min, offset, allow_burn, proto)
  VALUES ('s1', '$uart-0', '1', '1023', '0', '0', '1', 'virt');

CREATE TABLE Timer (
	name String
);
INSERT INTO Timer (name) VALUES ('t0');
