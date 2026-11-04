# 设备枚举动作
# 触发 enum0 枚举所有总线（i2c + spi + uart）。
# 若只需特定总线，可在 MT 中传 buses 参数，如：
#   enum0.go  enum0.buses;
#      1       $("i2c,uart")  ;
@Action
enum0.go;
   1  ;
@
