# 通用 Camera 动作：抓取一帧并返回图片。
# 默认目标变量是 cam；其他名称用 --var cameraVar=<name> 覆盖。
# 物理摄像头：pymybot run --robot robots/camwin.sql --input scripts/Camera.mt --allow-hardware
# 文件图片源：SQL 中声明 src，并给 --camera-src-dir；此时不需要 --allow-hardware。
@Alias
name alias;
cameraVar cam;
@
@Action
$(cameraVar).quality;
90;
@
