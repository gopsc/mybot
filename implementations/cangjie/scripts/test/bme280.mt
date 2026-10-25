# BME280 传感器测试动作：连续采样三次，每行输出 {result, T(°C), P(Pa), H(%RH)}
# 两次 call 建议间隔 > 1s（x1 过采样单次测量约 6~9ms，驱动自动轮询 measuring 位清零）
# 用法：cat scripts/test/bme280.mt | bash _run.sh --robot=robots/test/bme280.sql
@Action
bme280-0.call   timer-0.delay;	# 列头：<设备>.<参数>，列序即执行序
            -           1200;	# 采样 1 + 间隔 1.2s
            -           1200;	# 采样 2 + 间隔 1.2s
            -              0;	# 采样 3
@
