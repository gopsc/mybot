# SGP30 直连读取：先等 16 秒越过启动相，再每秒读一次 CO2eq/TVOC
#
# 运行：
#   ./build/mybot --robot=robots/sgp30.sql --input=scripts/sgp30.mt
#
# 输出字段：CO2EQ(ppm)、TVOC(ppb)、CRC_OK(1=双 CRC 校验通过)。
# 上电前 15 秒固定 400/0；之后在洁净空气中通常仍接近 400/0，
# 对着传感器呼气或靠近酒精/VOC 源时数值会明显变化。
@Action
t0.delay;
   16000;
@
@Action
sgp30-0.go t0.delay;
         1     1000;
         -     1000;
         -     1000;
         -     1000;
         -     1000;
@
