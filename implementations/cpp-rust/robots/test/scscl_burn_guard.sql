/*
 * SCSCL 烧号授权防线（审计 H-3）负值：结构脚本未声明 allow_burn 列时，
 * 动作参数 set_id 烧号必须被驱动拒绝（不可逆广播写须结构期显式授权），
 * 而非直接解锁 EPROM 烧号。守门断言 rc=1 且输出含 "requires allow_burn"。
 * 用法：cat scripts/test/scscl_burn_guard.mt | ./build/mybot --robot=robots/test/scscl_burn_guard.sql
 */
CREATE TABLE UART (
        name  String,
        path  String,
        baud  String,
        proto String
);
INSERT INTO UART (name, path, baud, proto)
  VALUES ('uart-0', '/dev/serial9', '1000000', 'virt');

/* 故意不声明 allow_burn 列——与 scscl_virt.sql 的唯一差别 */
CREATE TABLE SCSCL (
        name   String,
        UART   String,
        id     String,
        max    String,
        min    String,
        offset String,
        proto  String
);
INSERT INTO SCSCL (name, UART, id, max, min, offset, proto)
  VALUES ('s1', '$uart-0', '1', '1023', '0', '0', 'virt');

CREATE TABLE Timer (
        name String
);
INSERT INTO Timer (name) VALUES ('t0');
