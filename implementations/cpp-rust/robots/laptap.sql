/*
 * LAPTAP：基于笔记本电脑的测试机器人，其实主要就是带扬声器就行
 */

CREATE TABLE Speaker (
    name     String,   -- 实例名
    device   String,   -- ALSA 设备名（'-' = "default"；真机直配可写 'hw:0,0'、'plughw:0,0'）
    rate     String,   -- 采样率 Hz（'-' = 16000；允许 8000~48000 整数）
    preset   String,   -- 常驻缺省波形（'-' = sine）：
                       --   sine/square/triangle/sawtooth/noise/silence
    volume   String,   -- 音量 0~100（'-' = 80；平方曲线近似听感）
    max_ms   String,   -- 单次播放时长上限 ms（'-' = 10000，硬上限 60000）
    simulate String    -- '1' = 仿真模式（不出声、不开声卡）；'0'/'-' = 真实播放
);
INSERT INTO Speaker (name, device, rate, preset, volume, max_ms, simulate)
  VALUES ('spk0', 'default', '16000', 'sine', '80', '10000', '0');
