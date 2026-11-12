# 仿真器（sim/）

> 3D 蜘蛛机器人仿真器：GLFW/OpenGL 可视化从端，经五条 AF_UNIX 行文本 socket
> 接入 mybot 链路。本文是五条桥的协议、成败口径与架构约定的单一事实源；
> 逐字实现见 `sim/src/`（C++ 侧）与 `modules/Sim.lua` / `modules/Camera.lua`（驱动侧）。

## 是什么、不是什么

- **是**：可视化从端 + 感知源。上游只下发**语义动作**（前进/转向/停/拾取/放置），
  蜘蛛步态由仿真器按身体速度自己生成，关节角不过桥——这让 `.mt` 动作脚本与
  agent 工具层无需了解形态学。
- **不是**：物理引擎。平面运动学（一阶滞后逼近目标速度）+ 球-朝向盒（OBB）碰撞
  推出；**箱与箱之间不做逐帧碰撞**，只在 `place` 放置瞬间做一次几何解算（被占则近侧
  水平推开、按支撑面落地/叠放，见「放置解算」）。无足地接触、无 IK；搬运减速只是
  「质量越大越慢」的折算公式。
- **刻意缺席即成功**：命令桥的客户端（动作脚本）不该被一个调试窗口绑架，
  仿真器没开 = 命令静默丢弃（`BOT4CJ_DEBUG=1` 可见）；感知桥（拍照/测距）相反，
  抓不到就响亮 ERR——静默返回假数据比报错危险。

## 构建与运行

```bash
bash scripts/build_sim.sh        # 构建 + 自动跑 simcore 单测（ctest）
./sim/build/mybot-sim            # 监听五条缺省路径的 socket
```

独立 CMake 工程，刻意不被根 CMakeLists 引用（CI 五条 job 全 target 构建，
镜像无 GL/X11、musl 编不过 GLFW）。依赖经 FetchContent 拉 glfw 3.4 + glm 1.0.1，
仓库自带 glad 与 stb。

目标分两层：**simcore**（GL 无关：运动学/场景交互/五桥，可单测）与
**mybot-sim**（GLFW/OpenGL 壳）。`sim/tests/` 是 simcore 的单元测试（无 GL），
`test/test_sim.lua` 从 mybot 侧守门 Sim 驱动的 ERR 契约与线上协议。

## 五条 socket

路径解析各桥同规矩：**argv > 环境变量 > 缺省**；环境变量名是 mybot 侧与仿真器
侧的单一事实源，两侧同读。缺省路径的 C++ 侧单一事实源是 `sim/src/sim_config.h`
的 `kDefault*SocketPath`（main.cpp 不再各写字面量）；Lua 侧 `Sim.lua` 也硬编码了
命令/测距/IMU/里程计四条缺省路径——两套构建系统间不做代码生成，改由 `sim_tests` 的
`testSharedConstants` 与主干守门的 `scripts/check_sim_contract.py`（零编译依赖的
同款比对）交叉校验字面量一致，任一侧漏改即红
（拍照路径 Camera.lua 只取自 env、无硬编码缺省，不参与比对）。

| 桥 | 环境变量 | 缺省路径 | 语义 |
| --- | --- | --- | --- |
| 命令 | `MYBOT_SIM_SOCK` | `/tmp/mybot-sim.sock` | 持续型即发即忘 + 一次性事件 |
| 拍照 | `MYBOT_SIM_CAPTURE_SOCK` | `/tmp/mybot-sim-capture.sock` | 一问一答，回 JPEG 二进制体 |
| 测距 | `MYBOT_SIM_SENSOR_SOCK` | `/tmp/mybot-sim-sensor.sock` | 一问一答，回毫米整数 |
| IMU | `MYBOT_SIM_IMU_SOCK` | `/tmp/mybot-sim-imu.sock` | 一问一答，回姿态/角速度/加速度帧 |
| 里程计 | `MYBOT_SIM_ODOM_SOCK` | `/tmp/mybot-sim-odom.sock` | 一问一答，回地面真值位姿帧 |

分五条的原因：Sim.lua 与 Camera.lua 是各自独立的驱动实例（各自的 lua_State /
各自的 fd），物理上无法共用一条连接；语义上持续型命令与请求-应答也不同构。
IMU/里程计虽同为一问一答，但与测距的响应帧形态不同（浮点五域 vs 整数毫米），
各自独立成桥保持「一座桥一种帧」的清晰度（桥的扩展成本就是派生
`RequestResponseBridge` + 一个关键字 + 一个 sendXxx，见 `request_bridge.h`）。

多机器人时命令桥/测距桥/IMU 桥/里程计桥**每只一套**（robot[0] 用上表原缺省
路径，robot[i>0] 在 `.sock` 前插 `-<i>`），拍照桥仍单条——详见「多机器人（C2）」。

### 命令桥（`sim/src/bridge.cpp`）

一行一条指令，`\n` 结尾，速度缺省 1.0：

```
forward | backward | left | right | stop   [速度 0.0~1.0]
fdist <meters>      # 相对前进 N 米后自动停（负=后退）
turn <degrees>      # 相对转向 N 度后自动停（正=左，负=右）
jump <meters> <height>  # 向前弹道跳：水平前跳 N 米、apex 离地 height 米
pick                # 拾取前方 0.6m 内最近障碍（上方贴着别的箱子时拒绝，需先搬走上层）
place               # 把搬运物放到前方 0.5m 处（被占则近侧推开；可叠放到下层箱顶；
                    # 几何不可行——推出距离超限/兜底仍重叠——则失败，物体仍背着）
save                # 把当前场景写回配置的场景文件（见「场景文件」）
```

指令分两类，**别混**：

- **持续型**（forward/backward/left/right/stop）：像油门位，保持到下一条持续型
  指令为止。新持续型指令打断进行中的相对运动；`stop` 只是松油门，**不打断**
  相对运动（要取消请发一条持续型指令或新的 fdist 0）。
- **一次性**（fdist/turn/jump/pick/place/save）：入队逐条触发，每条必执行一次。
  fdist 与 turn **顺序执行**（先走完再转，同帧连发也不互相吞），同通道新目标
  覆盖旧目标；到量前提前松油门刹车，实际位姿贴着目标（不再有减速尾程的
  滑出）。队列上限 32（防灌事件），控制器断开时未执行事件作废、持续型指令
  回落 stop（没人管的蜘蛛不该继续走）。

`.mt` 动作脚本里用**数字动作码**（矩阵单元格只解析 Float64）：

```
0=stop  1=forward  2=backward  3=left  4=right
5=fdist(配 param=米)  6=turn(配 param=度)  7=pick  8=place  9=save
10=jump(配 param=前跳米数, param2=apex 高度米数，两参都必填)
```

动作分类学（码↔线上名↔持续/一次性↔是否带参）的**单一事实源是
`sim/src/action_table.h`**：命令桥查表分派（不再手写 if-else 字符串链），
`sim/tests` 交叉校验 `modules/Sim.lua` 的 `CODES`/`PARAM_CODES`/`PARAM2_CODES`/`CODE_MAX`
与表一致——加动作只需在表里追加一行，漏改 Lua 会被测试挡下（数字码是对外契约，
`.mt`/`.sql`/本文都用它，**只增不改**）。

这道校验**同时**由 `scripts/check_sim_contract.py`（零编译依赖的独立实现，
同一套比对逻辑）接入 `test/run_all_selftest.sh`（主干守门，push 前必跑）强制执行：
`sim/` 不在任何 CI job 的构建范围内（见 `sim/CMakeLists.txt` 顶部注释），单靠
`sim/tests` 的那份只有开发者手动跑 `bash scripts/build_sim.sh` 才会触发，不能
指望每次改动都被自动挡下；两份校验各自独立实现（C++/Python），互为印证。
同一个脚本还钉住另外两组手写双份的契约：五条缺省 socket 路径（见「五条 socket」）
与一问一答桥的请求关键字（`sensor.cpp` 的 `range` / `capture.cpp` 的 `capture` /
`imu.cpp` 的 `imu` / `odom.cpp` 的 `odom` ↔ `Sim.lua` 的 `range()`/`imu()`/`odom()`、
`src/agentimage.cpp`、`Camera.lua` 的 `capture_live()` 各自硬编码的 `"<word>\n"`）。

漏改还有第二道、且是编译期的防线：新增一个 `SimCommand` / `SimEvent::Type` 枚举值后，
若忘了在 `sim_engine.cpp` 的 `commandToInput` / `applyEvent` 里补对应 case，动作会静默
no-op。这两处 switch 刻意不写 `default`，配合 CMake 对本地三 target 开的
`-Werror=switch`（`-Wall -Wextra` 之外单挑这一条升级为错误），漏 case 直接编译不过。
第三方头（stb/glfw/glm）标 SYSTEM 或独立 target，不受这些告警影响。

手测：`socat - UNIX-CONNECT:/tmp/mybot-sim.sock` 然后敲 `forward 0.5` / `stop`。

### 跳跃与竖直动力学（动作码 10）

`jump` 是仿真器**唯一的竖直动作**：其余动作全在 XZ 平面，蜘蛛身体高度是常量。
它引入一套受控的最小竖直动力学（`robot.h`/`world.cpp`），既能跳过矮障碍，也能
跳上箱子、在箱顶行走、走下箱沿坠落——但刻意不做完整刚体物理。

- **起跳**：`launch(dist,height)` 折算竖直冲量 `vy0=√(2g·height)`、滞空
  `t=2vy0/g`、水平发射速度 `vx=dist/t`。空中水平速度守恒（无阻力）、朝向冻结
  （无空中转向/油门），只受重力拉一条抛物线。`height`/`dist` 分别钳到
  `kMaxJumpHeight=1.5m`/`kMaxJumpDist=4m`。落到更低处会比 `dist` 滑得更远。
- **支撑面**：`World::supportHeight()` 每帧算脚下（XZ 圆重叠、顶面不高于脚）
  最高的箱顶，无箱则地面 0；`Robot::applySupport()` 据此在 `y≤support` 时吸附
  落地、否则保持离地。走下箱沿 → 支撑突降 → 自动转坠落，带着走出边缘时的动量。
- **高度感知碰撞**：`resolveCollisions` 把顶面 ≤ 脚下 `y+kGroundSnapTol(2cm)` 的
  障碍当「地板」（可站/可跳过、不推），只有比脚高的「墙」才 XZ 推出。所以跳弧
  apex 高过箱顶就能越过/落上它，不够高则被当墙挡回。2cm 容差也意味着**地面行驶
  几乎不会自动爬箱**（碰撞语义与加跳跃前一致），要上箱必须跳。
- **放置解算**：`World::place` 先把搬运物落点定在机器人前方 0.5m，再做一次几何解算：
  与「墙」（顶面高于脚下的箱、且压在落点竖直带上）XZ 重叠时沿机器人前方把盒子水平
  推开，**只推近侧**（绝不穿到阻挡箱对面）；落地高度取脚印下最高的支撑面（顶面不高于
  脚下的箱顶），无则地面。于是机器人**自己站上箱顶再松手**，物体就落在下层箱顶（叠放）；
  在平地上则一律贴地并把被占的箱子推开（箱-箱永不重合）。静态箱不做逐帧求解。
  解算在局部副本上进行，写回前做一次事实性 3D 重叠校验；**累计推出距离超过
  `kMaxPlacePush`（3m）或兜底后仍重叠**，视为几何不可行，`place()` 返回 false、
  物体保留在搬运状态、场景不变——宁可放置失败，也不留一个相互穿插的假结果。
  失败原因由 `place()` 的 `why` 出参给出（`World::PlaceFail`），sim 日志据此把三种
  失败分开报：未持有物体 / 推出距离超限 / 落点仍与障碍重叠。
- **失去支撑时落下**：静态箱没有逐帧重力，但 `settleUnsupported()` 在每帧推进末尾
  把「底面悬空、脚下还有更低支撑面」的箱子落到该支撑面（地面或另一箱顶）。抽走
  堆叠下层后，上层不会停在原处悬空——一层落稳后才轮到压在它上面的那一层，故
  引擎按障碍数重复直到不再有箱子落下。正被搬运的箱子跳过（跟着机体走）。旁边
  XZ 不重叠的箱子不当支撑。`pick()` 仍拒绝拾取上方贴着另一个箱子的目标（顶面与
  上层箱底面的距离 <= `kGroundSnapTol`、且 XZ 有重叠，哪怕只搭边角也算）——落下
  是抽走之后的补救，不是允许把下层从叠放里抽出来。
- **不影响**：搬运物 y 跟随机体离地高度一起升降。相机跟随目标带上机体 y，跳跃时镜头跟着抬。

`.mt` 侧：`scripts/sim_jump.mt` 用第二参数列 `sim.Q`（`spider_sim.sql` 的
`Q→param2` 别名）传高度，`run_action_script(script="sim_jump.mt",
vars={"dist":0.8,"height":0.35})` 注入。


### 拍照桥（`sim/src/capture.cpp`）

请求 `capture\n`；响应先文本头一行、紧跟二进制体：

```
OK jpeg <len> <w> <h>\n   + <len> 字节 JPEG
ERR <reason>\n
```

抓的是本帧渲染结果（SwapBuffers 前的 GL_BACK，垂直翻正后 stb 编码，质量 90）。
mybot 侧归 `modules/Camera.lua` 的 sim-live 图源（`capture_image` 工具）。
手测：`printf 'capture\n' | socat - UNIX-CONNECT:/tmp/mybot-sim-capture.sock | head -c 64`。

### 测距桥（`sim/src/sensor.cpp`）

请求 `range\n`；响应 `OK <mm>\n` 或 `ERR <reason>\n`。距离是身体前端、身体中心
高度的**水平**射线与障碍盒的最近交点：顶面不高于脚下的障碍是地板，射线从它
上方穿过去（站在箱顶上读到的是前方的墙，不是脚下这块箱子的近面）；无命中返回
10.0m 上限；被搬运的物体不计入。
mybot 侧两个消费者：`Sim.lua` 的 `range()`（动作脚本可用）与 C++ 侧
`querySimRange()`（`capture_image` 时把距离附进照片描述）。
手测：`printf 'range\n' | socat - UNIX-CONNECT:/tmp/mybot-sim-sensor.sock`。

### IMU 桥（`sim/src/imu.cpp`，2026-10-16）

请求 `imu
`；响应 `OK <yaw_deg> <gyro_z> <acc_fwd> <vy> <airborne>
` 或
`ERR <reason>
`，五域都是本帧最终状态（碰撞解算后）：

- `yaw_deg` 航向角（度，+左）；`gyro_z` 角速度（rad/s，即 d(yaw)/dt，+左转）
- `acc_fwd` 机体系前向加速度（m/s²，`Robot::update` 的帧差分实导数——起步/刹车
  时非零、稳态趋 0）
- `vy` 竖直速度（m/s，+上升）；`airborne` 0/1 是否离地

仿真器是**运动学模型**（非刚体动力学），这台虚拟 IMU 的域集合如实反映它测得到
什么：没有横摆加速度计、没有磁力计，不编造物理量。mybot 侧两个消费者：
`Sim.lua` 的 `imu()`（动作脚本可用）与 `lib/sim_sensor_daemon.lua` 守护采样
（`kind=imu`）。手测：`printf 'imu\n' | socat - UNIX-CONNECT:/tmp/mybot-sim-imu.sock`。

### 里程计桥（`sim/src/odom.cpp`，2026-10-16）

请求 `odom
`；响应 `OK <x> <z> <theta_deg> <v> <odo>
` 或 `ERR <reason>
`：

- `x`/`z` 世界坐标位置（米，+x 前、+z 右；theta=0 时朝 +x）
- `theta_deg` 航向角（度，+左）；`v` 机体前向速度（m/s，带符号：负=后退）
- `odo` 累计路径长度（米，**绝对值口径**：前进/后退/跳跃的水平位移都计，
  `Robot::update` 逐帧累计，reset/场景重载清零）

这是**地面真值**（仿真器的权威状态），不是轮速积分的估计值——仿真里没有轮子
打滑模型，两者的差为零，如实标注口径即可。mybot 侧两个消费者：`Sim.lua` 的
`odom()`（动作脚本可用）与 `lib/sim_sensor_daemon.lua` 守护采样（`kind=odom`）。
手测：`printf 'odom\n' | socat - UNIX-CONNECT:/tmp/mybot-sim-odom.sock`。

## 三桥共同的行为约定（`sim/src/unix_line_server.cpp`）

- **单线程**：无独立线程，主渲染循环每帧 `poll()` 一次；recv 非阻塞绝不卡画面，
  发送侧带 3s 绝对 deadline（对端连上不读就断开，绝不无限阻塞）。
- **单客户端、新顶旧**：新连接直接顶掉旧连接（对端每次请求都可能重连）。
- **EOF 延迟断开**：对端关写端（socat 手测「发完即关」模式）时先把已到的行
  全部派发、答复发出后再断开——请求不允许被 EOF 连带清掉。
- **垃圾有界**：攒够 1024/4096 字节还没换行就断开，不无界吃内存；认不出的
  指令整行忽略并告警，**不改当前状态**（持续型指令被垃圾打成 stop 是事故）。
- SIGPIPE 一律 `MSG_NOSIGNAL` 折成 EPIPE 处理；上次异常退出留下的 socket inode
  先 unlink 再 bind。

## 场景文件（环境与代码解耦）

障碍布局与机器人数量都是**数据不是代码**：`sim/scenes/default.scene`（单机器人，
行文本，与三桥协议同风格，可手编可 diff）、`sim/scenes/two_robots.scene`（双机器人
v2 示例）。C++ 里的 `World::defaultScene()` 只是无场景文件时的内置回落，与
default.scene 的 box 十字段（位置/半尺寸/颜色/质量）逐字段同值——由
`scripts/check_sim_contract.py` 零编译比对（见 [testing.md](testing.md)）。
**仓库里这两份现只作播种模板**：运行时缺省落点是家目录
地图目录（见下「路径解析」），首次运行从模板拷一份过去，仓库文件不再被弄脏。

```
mybot-sim scene v3            ← 首行魔数 v1/v2/v3，缺了整文件拒绝
# box: cx cy cz hx hy hz r g b [mass [yaw_deg]]，mass 缺省=体积×800kg/m³，
#      yaw_deg = 绕 Y 朝向（度，0=轴对齐，缺省 0）
box 2.0 0.40 1.2 0.40 0.40 0.40 0.72 0.30 0.24 61.44
# robot: x z theta_deg [carried_idx]，carried 恢复搬运状态
robot 0 -1.5 0                ← 多条 robot 行 = 多机器人，按序对应 robot[0]、[1]…
robot 0  1.5 0
```

三个版本的差别：v1 恒 1 只机器人；v2 允许多条 robot 行（多机器人）；v3 在 box 行
末尾追加可选 `yaw_deg`（朝向盒 OBB）。readScene 三者都收（v1/v2 的盒读成 yaw=0，
旧文件无感继续用），按出现顺序读进 `SceneState.robots`；无 robot 行补一只原点默认，
`carried_idx` 越界归一为 -1。writeScene **一律写 v3**（v3 是 v1/v2 超集）。
注释（`#`）与空行忽略，未知/坏行告警跳过。
`sim/tests` 有 v1/v2/v3 round-trip、多 robot 行、缺 robot 行补默认、朝向几何
（测距/碰撞/拾取的 yaw 影响）与容错解析的守门。

**路径解析**：`argv[4] > env MYBOT_SIM_SCENE > 缺省裸名 "default"`，落点按名字形态分两种：

- **含 `/` 的显式路径**原样使用（来源标「命令行/环境变量显式路径」）；
- **裸名**（`default`、`my_map`…）解析为 **`$MYBOT_HOME/maps/<名字>.scene`**（`$MYBOT_HOME`
  缺省 `$HOME/.mybot`）。首次缺失时从仓库模板 `sim/scenes/<名字>.scene` **播种**一份
  （临时文件 + rename，`0600`；**已存在绝不覆盖**——那是用户/agent 改过的地图）；
- **退回内置**：无状态目录（`MYBOT_HOME` 与 `HOME` 都空）/ 找不到模板 / 建目录或播种
  失败 → 打印原因并退回内置默认场景，**绝不让 sim 起不来**。代价是此后**场景路径为空**：
  `S` 键 / `save` 指令 / 退出即保存都无处可写（`save: 未配置场景路径…`），改动只活在这
  一次进程里。所以「只在 `$MYBOT_HOME/maps/` 放一份 `my_map.scene`」是**不够**的——裸名
  还要求 `sim/scenes/` 里有同名模板；要跑模板之外的布局就传绝对路径（含 `/` 即绕开查找）。
- 启动时把**实际落点**打到 stderr（`scene: 场景文件 <路径>（来源 家目录已有/仓库模板播种）`）。
- 场景文件读失败同样回落内置并告警，不开黑屏世界。

> 「配置只能收紧不能放宽」在这里的体现：模板目录由编译期定义
> `MYBOT_SIM_SCENES_DIR`（照 `MYBOT_MODULES_DIR` 先例）+ `/proc/self/exe` 相对回退两级
> 定位，运行期不接受任意模板路径；`MYBOT_SIM_SCENE` 仍只决定**写回哪一份**，线上协议
> 从不收路径参数。

**保存**：`S` 键、命令桥 `save` 指令（动作码 9）、**或退出时自动**把当前世界状态
（障碍位置 + **全部机器人**位姿 + 各自搬运状态）**原子写回**（先落 `.tmp`、`chmod 0600`、
再 rename）启动时配置的场景文件——与播种出来的那份同为 `0600`，不会因 `fopen` 的缺省
权限变成组/他人可读。线上不接受路径参数——只写本进程启动时定下的那一个文件，与
Camera.lua「杜绝连任意 socket」同源的安全口径。`sim_agent_demo.sh` 缺省**不再显式传
场景**：由 sim 自己落 `$MYBOT_HOME/maps/default.scene`（缺失则从仓库模板播种），agent
搬动过的环境经 save 存回这里、下次续用；仓库 `sim/scenes/*` 从此只读。

**退出即保存**：ESC、点窗口 X、Ctrl-C（SIGINT）、以及 demo 拆链路的 SIGTERM 都走
同一条「保存再退」的路——`main.cpp` 把 SIGTERM/SIGINT 折成一个 async-signal-safe
的关窗标志（信号处理器里绝不碰 GLFW/IO），主循环轮询到即优雅退出，退出前统一
`saveScene()`。未配置场景路径（内置默认）时 `saveScene` 自行 no-op（打印「无处置写」）。
SIGKILL 不可捕获，故 `kill -9` 不会保存。

> 段错误旧账：`Shader`/`Mesh`/`Spider` 的析构里是 `glDelete*`，必须**早于**
> `glfwTerminate()`。此前显式在 main 末尾 terminate、而这些是更早声明的局部量
> （析构序在 terminate 之后）——只是过去 demo 用 SIGTERM 瞬杀、析构根本没跑才没暴露。
> 现改由一个**早声明的 RAII 守卫**在最后 terminate（析构序 = 声明序逆序），先释放
> 全部 GL 再关 GLFW。

**复位**：`R` 键从场景源头整体重载（文件版重读文件、内置版回默认），所有机器人
位姿与步态一并复位——被搬走的箱子能回来了。若重载后机器人数量变化，壳会按新数量
重建每只的命令桥/测距桥与蜘蛛（见「多机器人」）。

## 多机器人（C2）

一个 sim 进程可承载 N 只机器人，数量由场景 robot 行数决定。寻址用**每只一套独立
socket**（选项 b），好处是**行协议零改动**——线上语法、动作码、三桥行为全不变：

- `robot[0]` 用原缺省路径（`/tmp/mybot-sim.sock`、`/tmp/mybot-sim-sensor.sock`），
  字节不变，旧客户端与单机器人链路完全无感。
- `robot[i>0]` 在末尾 `.sock` 前插 `-<i>`：`/tmp/mybot-sim-1.sock`、
  `/tmp/mybot-sim-sensor-1.sock`（无 `.sock` 后缀则直接追加）。
- **拍照桥单条**：它抓的是整幅 GL 视口（一帧全景），与机器人数量无关。

为什么是「每只一套」而非「一条 socket 多路复用」：`UnixLineServer` 是**单客户端、
新顶旧**的骨架（见下节），多 agent 共用一条会互相顶掉连接；每只一套 socket 则天然
隔离，多 agent 各把 `MYBOT_SIM_SOCK` / `MYBOT_SIM_SENSOR_SOCK` 指向自己那套即可，
`Sim.lua` / `Camera.lua` **无需任何改动**（缺省路径本就来自 env）。

引擎侧：`SimEngine` 持 `vector<RobotSlot>`，每个 slot = 一只 `Robot` + 它自己的持续型
命令通道（command/speed/lastContinuous）。`applyContinuous` / `applyEvent` /
`queryRange` / `robot` 都带一个默认 `kPrimaryRobot` 的 `idx` 尾参（单机器人旧调用方
零改动），壳按 robot-id 把各自桥的状态喂进对应 slot；`step(dt)` 逐只按**本 slot 的
命令**推进。相机跟随、标题栏取主机器人（idx 0），标题附机器人总数。由
`testEngineMultiRobot`（两只各拾各的、朝相反方向各走各的）headless 守门。


## 架构分层

```
simcore（GL 无关，可单测/可上 CI）        mybot-sim 壳
├─ sim_engine.cpp  引擎：拥有 vector<RobotSlot>+World+场景，├─ main.cpp  薄壳：主循环/输入/HUD
│                  每帧逐只推进 + 按 idx 派发指令（可 headless 测）├─ spider.cpp 四足外观步态
├─ robot.cpp    平面运动学+相对运动+各自搬运态  ├─ mesh/shader/camera
├─ obb2d.cpp    XZ 平面有向盒几何：局部系旋转/盒面最近点/前向量/射线/SAT（纯函数）
├─ world.cpp    障碍场景/碰撞/测距/拾放（无状态，按 Robot 参数化）└─ framegrab.cpp glReadPixels→JPEG
├─ scene_io.cpp 场景文件读写（行文本，魔数 v1/v2/v3，原子写 + 0600）
├─ action_table.cpp  动作分类学单一事实源
├─ sim_config.h   全局可调常量 + 缺省 socket 路径（C++ 侧 SSOT）
├─ unix_line_server.cpp  三桥公共骨架
├─ request_bridge.cpp  请求-应答桥公共基类（一问一答）
├─ bridge.cpp   命令桥（状态+事件队列，查 action_table 分派）
├─ capture.cpp  拍照桥（RequestResponseBridge 子类，只补二进制体帧化）
└─ sensor.cpp   测距桥（RequestResponseBridge 子类，只补文本响应帧化）
```

**SimEngine**（`sim/src/sim_engine.cpp`）是仿真逻辑的落点：拥有 `vector<RobotSlot>` +
`World` + 场景路径，暴露 `reloadScene/saveScene`、`applyContinuous(cmd,speed,idx)`、
`applyEvent(ev,idx)`、`step(dt)`、`queryRange(idx)`、`robot(idx)`/`robotCount()`。此前
这些是 `main.cpp` 里的自由函数与 lambda，困在 GLFW 壳中无法单测；抽进 simcore 后，
fdist 到量、pick/place、save/reload、多机器人寻址都能在 `sim/tests` 里 headless 验证。
壳只管窗口/输入/渲染/HUD，每帧把每只命令桥的持续型状态与一次性事件按 idx 喂给引擎、
调 `step(dt)`，再逐只读 `robot(i)/world()` 渲染——蜘蛛外观步态（`Spider`）是可视化，
仍留在壳里按各只 `robot(i).v()` 自己生成。

**多机器人**：`step(dt)` 逐只推进 `slots_`，每个 slot 各用自己的命令通道；`World`
不持有任何单只机器人的状态、所有交互（碰撞/测距/拾放/背负跟随）都按传入的 `Robot`
参数化，**搬运状态下沉到每只 `Robot` 各自持有**（此前是 World 级单例，两只会互相
覆盖）。因此同一 World 可服务 N 只、各搬各的，由 `testMultiRobot`（核心层两只各搬各的）
与 `testEngineMultiRobot`（引擎层按 idx 独立受控）headless 守门。机器人数量由场景
robot 行数决定，壳按 `robotCount()` 建对应套数的命令桥/测距桥（见「多机器人」）。

`Robot` 管运动学（`update(dt, input, maxSpeed)`）与**自己背着哪个障碍**（`carriedIndex/`
`carriedMass`，`effectiveMaxSpeed()` 按自身负载折算上限）；「世界里有什么、撞了怎么解、
能不能搬、搬起来钉哪」全在 World。协调坐标系：机体局部 +X 前、+Y 上、+Z 右，theta 增大
= 左转。

## 端到端链路

`scripts/sim_agent_demo.sh` 起三层：sim + `mybot --mcp-backend` + `mybot-agent`，
任务提示词从 `prompts/sim_obstacle_nav/`（避障探索）或 `PROMPTS_DIR` 指定目录
按序号拼接；搬运任务提示词见 `prompts/sim_carry_task.md`（配
`scripts/sim_pick.mt` / `sim_place.mt`）。退出时自动拆链路清 socket，日志保留。

**这条链路是手动冒烟，不是守门**：`test/run_all.sh`、`.gitlab-ci.yml` 的十条 job、
`scripts/git-hooks/pre-push` 都不调用它（仓内对它的唯一机械检查是
`test/run_all_selftest.sh` 静态比对其中 `MYBOT_HOME` 的拼法，属「状态目录缺省名」那段，
并不执行脚本）。它跑一次要三样东西，任一缺失都使它进不了自动守门：显示器（GLFW/OpenGL
窗口）、真模型凭据（缺省读 `mybot.llm.json`，该文件按 `*.llm.json` 被 gitignore）、
以及先 `bash scripts/build_sim.sh`（`sim/` 是独立 CMake 工程，同样不在任何 CI job 的
构建范围内）。所以**GL 可视化壳没有任何自动覆盖**：改坏了要靠人跑一次 demo 才会发现，
提交前请自行跑一遍并在提交信息里写明结果。核心逻辑（运动学/碰撞/搬运/场景 IO/三桥线上
协议/动作码表）另由 `sim_tests` 与主干守门的零编译跨源校验覆盖，见
[testing.md](testing.md)。
