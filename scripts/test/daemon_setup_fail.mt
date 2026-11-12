# 守护 setup 失败响亮契约：首行 t0 预热 200ms 让守护完成（失败的）setup，
# 随后 mon0.go 经 $imu0 读守护快照 → 宿主读路径见槽 status=-8 即 ERR 上抛。
# 期望退出码 1 且信息含 "slot status -8"（配合 daemon_setup_fail.sql）
@Action
t0.delay  mon0.go;
   200        -;
    50        -;
@
