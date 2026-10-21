# 摄像头依赖：OpenCV 换成 PyAV + Pillow

记录日期：2026-10-22
影响平台：Windows / Linux / macOS（实机只验证了 Windows）
状态：已实现（`pymybot/hal.py`、`pyproject.toml` 及相关测试与文档），未提交

## 背景

改动前，`pymybot/hal.py` 里的 Camera 依赖 `opencv-python-headless`，用到了三块功能：

1. **采集**：`cv2.VideoCapture(index)` 打开摄像头，然后 `read()` 取一帧。
2. **编码**：`cv2.imencode(".jpg", frame, [IMWRITE_JPEG_QUALITY, q])`。
3. **校验**：对 `src` 文件输入和采集结果做 `cv2.imdecode`，完整解码一次，确认图像有效、尺寸与文件头一致。

numpy 只是 cv2 的间接依赖，pymybot 自己没有用到。OpenCV 的 wheel 很大，又只用到它的一小部分，
因此调研能否换成更轻、同样跨平台的库。

## 调研

### 体积对比

| 包 | Windows wheel | Linux x86_64 wheel | Windows 安装后 |
| --- | --- | --- | --- |
| opencv-python-headless 5.0 | 43.8 MB | 56.6 MB | cv2 约 111 MB |
| numpy（cv2 依赖） | 12.6 MB | 16.7 MB | 约 55 MB |
| **合计（改动前）** | 56.4 MB | 73.3 MB | **约 166 MB** |
| pillow 13.0.0 | 7.3 MB | 6.0 MB | 约 16 MB |
| av 19.0.2（PyAV，自带 FFmpeg） | 28.2 MB | 35.0 MB | 约 69 MB |

PyAV 在 macOS arm64 上的 wheel 为 18.6 MB，最低要求 macOS 14。

结论：编码和校验只需要 Pillow，体积约为原来的十分之一。只有真机采集才需要 PyAV，因此把它
做成可选依赖 `.[camera]`。只用文件输入（`src`）的用户，安装体积从约 166 MB 降到约 16 MB；
装上 PyAV 的完整安装约 85 MB，仍然只有原来的一半左右。

### 各平台采集后端

PyAV 通过 FFmpeg 的设备输入采集，三个平台各用一个后端：

| 平台 | FFmpeg 格式 | 输入写法 | 备注 |
| --- | --- | --- | --- |
| Windows | `dshow` | `video=<设备名>` | 只接受设备名，不接受索引，需要先枚举设备 |
| Linux | `v4l2` | `/dev/videoN` | |
| macOS | `avfoundation` | `N:none` | 默认帧率 29.97，多数摄像头不支持，需要显式指定 `framerate=30` |

### 放弃的方案

| 方案 | 放弃原因 |
| --- | --- |
| pygame-ce `camera` 模块 | 官方标记为实验性；macOS 没有原生后端 |
| imageio-ffmpeg | 体积不比 PyAV 小；它通过子进程调用 ffmpeg，还要自己解析管道输出 |
| pygrabber（Win）+ linuxpy（Linux）+ pyobjc（macOS） | 三个平台三套代码；pygrabber 自 2023 年起没有更新 |

### 校验行为是否一致

确认过 Pillow 的 `Image.open(..., formats=[...])` 加 `load()` 和 `cv2.imdecode` 的判定一致：

- 截断的 PNG/JPEG、像素数据损坏，两者都会拒绝。
- 截断后补上 EOI 标记的 JPEG，两者都接受。

因此，把校验从 cv2 换成 Pillow，不会放宽也不会收紧原有的判定。

## 改动

### `pymybot/hal.py`

- [`_validate_image`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/pymybot/hal.py#L451)：
  先按文件头识别格式，再用 Pillow 只按该格式打开并 `load()` 完整解码，最后比对解码尺寸与文件头尺寸。
  解码失败时报 `invalid image data (decode failed: ...)`。
- [`_camera_open`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/pymybot/hal.py#L381)：
  只登记资源，不导入 av，也不探测设备。激活结构时不碰硬件，这一点与改动前一致。
- [`_dshow_video_devices`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/pymybot/hal.py#L504)：
  在 Windows 上枚举视频设备，过程如下：
  1. 用 `list_devices=true` 打开 dshow。FFmpeg 会把设备列表写进日志，随后打开必然失败。
  2. 用 `av.logging.Capture(local=False)` 截获这段日志。PyAV 默认日志级别为 None，所以要临时调到 INFO，用完再恢复。
  3. 用正则解析 `"名称" (video)` 下一行的 `Alternative name "@device_pnp_..."`。用 PnP 名而不是显示名，是因为显示名可能重名。
  4. 日志级别和日志截获都是进程全局状态，因此用模块级 `_AV_LOG_LOCK` 串行化。
- [`_camera_input`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/pymybot/hal.py#L523)：
  按上表把设备索引转换成各平台的输入写法。字符串设备原样透传。不支持的平台报
  `camera capture is not supported on <platform>`。dshow 索引越界报
  `camera unavailable: N (K video devices found)`。
- [`_latest_frame`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/pymybot/hal.py#L538)：
  取最新帧，见下文「后续：采集返回陈旧帧」。
- [`_camera_capture`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/pymybot/hal.py#L566)：
  - 设备或尺寸变化时关闭设备，然后用 `video_size` 重新打开（macOS 另加 `framerate=30`），打开超时 10 s。
  - 用 `frame.to_image().save(..., "JPEG", quality=q)` 编码。
  - 结果里的 `source` 由 `opencv` 改为 `pyav`。
  - 出错时关闭设备，下一次采集重新打开。
- `_close_handle`：camera 不再走 `release()` 分支，统一调用 `close()`。

### 依赖（`pyproject.toml`）

- 删除 `opencv-python-headless>=4.10,<5`。
- 新增必选依赖 `pillow>=11,<14`。
- 新增可选依赖 `camera = ["av>=19,<20"]`。

### 测试

- `tests/test_hal.py`：
  - 原来的 `cv2_fake` 换成 `av_fake`，模拟了 Container、demux、Packet、Frame、`av.logging` 和 dshow 设备列表日志。设备列表样例里特意放了一个名称含括号的音频设备。
  - 新增 [`test_camera_platform_device_inputs`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/tests/test_hal.py#L458)（三个平台的输入写法）和 [`test_camera_platform_failures`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/tests/test_hal.py#L469)。
  - [`test_real_pillow_image_validation`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/tests/test_hal.py#L554) 使用真实的 Pillow，替代原来的 `test_real_cv2_image_validation`。其中新增了一个样例：IDAT 内容是垃圾数据、但 CRC 合法的 PNG。只看文件结构发现不了它，必须真正解码才能拒绝。
- `tests/test_agent_executor.py`：[`test_real_camera_file_source_and_jpeg`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/tests/test_agent_executor.py#L933) 改用 PIL 生成测试图片，不再依赖 cv2/numpy。

### 其他

- `modules/Camera.lua` 的头注释，以及 `modules/lib/HAL.lua` 的 `backend_name`（改为 `pyserial/pyftdi/pyav`）。
- `README.md`：校验命令改为 `import PIL`；补充 `.[camera]` 的说明和平台说明。
- `skills/pymybot-scripting/references/workflow-errors.md` 的 Camera 要点。
- 两份 CI 配置的注释。CI 不安装 av，采集逻辑由 fake 覆盖。

## 行为变化（相对 OpenCV）

- **分辨率严格匹配**：OpenCV 遇到摄像头不支持的宽高时，会静默协商成别的尺寸；FFmpeg 会直接拒绝
  打开。实测 1000×700 报 `camera unavailable: 0 (... I/O error)`。调用方必须传入摄像头实际支持的
  分辨率。
- **Windows 上的索引含义**：现在的索引是 dshow 枚举出的第 N 个视频设备，顺序可能和 OpenCV 的
  MSMF/DSHOW 不同。机器上只有一个摄像头时没有区别。
- **macOS 需要 14 及以上版本**（PyAV wheel 的限制），帧率固定按 30 打开。
- **结果字段 `source`** 由 `opencv` 变为 `pyav`。

## 实机验证（Windows）

设备为 Integrated Webcam_FHD，输出 MJPEG（`yuvj422p`），30 fps，后端 dshow。

| 场景 | 结果 |
| --- | --- |
| 首次采集（打开设备 + 自动曝光预热） | 1.2–1.5 s |
| 设备已打开后的后续采集 | 25–55 ms |
| 640×480 / 1280×720 / 1920×1080 | 均正常 |
| 1000×700 | 报 `camera unavailable ... I/O error`（见上文「分辨率严格匹配」） |
| 设备索引 1（本机只有 1 个视频设备） | 报 `camera unavailable: 1 (1 video devices found)` |
| CLI `sample --robot cam.sql --name cam --count 3 --interval-ms 1000 --allow-hardware` | 3 张 1280×720 JPEG，`source` 为 `pyav` |
| 同一条命令不加 `--allow-hardware` | 按预期以 `DriverError` 拒绝 |

## 后续：采集返回陈旧帧（2026-10-22）

### 现象

第一版直接用 `next(container.decode(video=0))` 取帧。实机上，打开设备后的第一次采集正常，之后
每次只要约 5 ms 就返回，但拿到的是很久以前的帧。下表中的「帧时间」是帧时间戳相对第一帧的偏移，
「实际经过」是两次采集之间真实流逝的时间：

| 距上次采集的间隔 | 帧时间 | 实际经过 |
| --- | --- | --- |
| 1 s | 0.11 s | 1.06 s |
| 3 s | 0.18 s | 4.06 s |
| 5 s | 0.24 s | 9.06 s |

也就是说，每次采集只前进了几帧，画面会越来越滞后。

### 根因

两者在两次采集之间的处理方式不同：

- FFmpeg dshow 会把设备持续送来的帧排进内部队列，实测空闲时最多积压约 75 帧，取帧时按 FIFO 从最旧的开始。
- OpenCV 的 DSHOW 后端只保留最新一帧，`read()` 总是返回当前画面。

所以，同样是"设备已打开时取一帧"，OpenCV 拿到的是当前画面，PyAV 拿到的是队列里最旧的一帧。

### 修法：`_latest_frame`

逐个 demux 数据包，并记录每次读取花了多长时间：

- 队列里已积压的包几乎瞬间就能读到，实测每次不到 1 ms。
- 一旦某次读取阻塞了至少半个帧间隔（`0.5 / 帧率`，拿不到帧率时按 5 ms 计），就说明积压已经清空，这个包是刚到的实时帧，于是停止读取。

读取过程中只缓存最近一个关键帧及其之后的包，最后只解码这些包，取最后一帧。这样：

- MJPEG 这类每帧都是关键帧的流，实际只需要解码一帧。
- H.264 这类帧间压缩的流也能正确解码，不会从中间的 P 帧开始解码。

为避免读取一直不停，整个过程受 `CAMERA_TIMEOUT`（10 s）兜底；流结束或读到空包时报 `camera stream ended`。

### 代价与效果

- 每次采集多花约一个帧间隔（30 fps 下约 33 ms），实测 25–55 ms，最多跳过约 75 帧积压。
- 修复后，帧时间与实际经过一致，误差约 0.01 s：

| 实际经过 | 帧时间 |
| --- | --- |
| 1.08 s | 1.09 s |
| 4.12 s | 4.13 s |
| 9.16 s | 9.17 s |

### 回归测试

fake Container 先瞬间吐出 `backlog` 个积压包，再隔 2 ms 吐一个"实时"包；只有实时包解码出的帧
允许调用 `to_image()`，否则断言失败。
[`test_camera_lazy_capture_fields_reconfigure_close`](file:///C:/Users/qingshuhong/Documents/GitHub/mybot/tests/test_hal.py#L431)
在第二次采集前把 `backlog` 设为 50，用来确认积压确实被跳过。

## 修复后的验证

| 场景 | 结果 |
| --- | --- |
| `pytest` 全量 | `1084 passed, 19 skipped` |
| 在 `sys.modules` 中屏蔽 `cv2`、`numpy` 后跑 `test_hal.py` + `test_agent_executor.py` | `150 passed`，确认不再依赖 OpenCV |
| 实机 CLI `sample` | 见上文「实机验证」 |

验证环境：Windows，Python 3.12.10，pillow 13.0.0，av 19.0.2。

## 相关但未处理的问题

- **Linux v4l2 和 macOS avfoundation 没有实机验证**，只有 fake 覆盖输入写法。v4l2 的内部缓冲
  深度与 dshow 不同，`_latest_frame` 的判据理论上通用（依据只是"读取是否阻塞"），但没有实测。
- **H.264 等帧间压缩摄像头没有实测**，关键帧逻辑只由 fake 覆盖。本机摄像头只输出 MJPEG。
- **dshow 设备枚举依赖解析 FFmpeg 的日志文本**。日志格式如果随 FFmpeg 版本变化，正则就会失配，
  表现为 `0 video devices found`。目前 av 锁在 `<20`，升级大版本时需要复查。
- **采集阻塞时无法中途取消**：一次 demux 或打开设备的读取会一直阻塞，直到返回或超时，Lua 的
  预算钩子打断不了原生调用。这与 OpenCV 时期相同，详见 `skills/pymybot-scripting/references/workflow-errors.md`
  的平台要点。
- **本地 `.venv` 里仍装着 opencv-python-headless 和 numpy**，没有卸载。上面"屏蔽 cv2/numpy"的那项
  测试已经证明代码不依赖它们；需要节省空间时可以执行 `pip uninstall opencv-python-headless numpy`。

## 后续：文档定稿后的复测（2026-10-22）

代码没有改动，重新跑了一遍 fake 测试和真机测试，确认结论依旧成立。

### fake 测试

| 范围 | 结果 |
| --- | --- |
| `test_hal.py` + `test_agent_executor.py` 中与 camera/pillow/image 相关的用例 | `30 passed, 1 skipped`（跳过的是 `test_camera_source_symlink_escape`，Windows 上没有创建软链的权限） |
| `test_agent.py`、`test_agent_cli.py`、`test_cli.py`、`test_robot.py`、`test_runtime.py` 中与 camera 相关的用例 | `6 passed` |

### 真机（同一摄像头，dshow）

直接调用 HAL，通过包一层 `_latest_frame` 记录 `frame.time`。所有返回的 JPEG 都用 Pillow 完整解码确认有效，抽查一张画面为当前实时场景。

| 场景 | 结果 |
| --- | --- |
| 首次采集 1280×720 | 1469 ms，`source=pyav` |
| 隔 1 / 3 / 5 s 再采 | 采集 47 / 78 / 62 ms；帧时间 1.07 / 4.14 / 9.22 s，实际经过 1.05 / 4.12 / 9.19 s |
| 切换到 640×480、1920×1080 | 均正常；每次切换都要重开设备，约 1.45 s |
| 1000×700 | `camera unavailable: 0 ([Errno 5] I/O error: 'video=@device_pnp_...')` |
| 设备号 1 | `camera unavailable: 1 (1 video devices found)` |
| 出错后再用设备 0、640×480 采集 | 正常，说明出错时关闭设备、下次重开的逻辑有效 |
| CLI `sample --count 3 --interval-ms 1000 --allow-hardware` | 3 张 1280×720 JPEG，退出码 0，总耗时约 4 s |
| 同一命令不加 `--allow-hardware` | 以 `DriverError` 拒绝，退出码 1，stdout 只有一条 JSON |

帧时间比实际经过多出约 0.02–0.03 s，比上一轮记录的约 0.01 s 略大。这在一个帧间隔（约 33 ms）之内，
不说明拿到的是旧帧。
