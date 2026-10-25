#include <glad/glad.h>
#include <GLFW/glfw3.h>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>

#include <algorithm>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "bridge.h"
#include "camera.h"
#include "capture.h"
#include "framegrab.h"
#include "mesh.h"
#include "robot.h"
#include "imu.h"
#include "odom.h"
#include "sensor.h"
#include "shader.h"
#include "shaders.h"
#include "sim_config.h"
#include "sim_engine.h"
#include "sim_paths.h"
#include "spider.h"
#include "world.h"

namespace {

// 各桥 socket 同一规矩：argv > 环境变量 > 缺省。缺省路径的单一事实源是
// SimConfig::kDefault*SocketPath（sim_config.h），环境变量名是运行期的单一事实
// 源，mybot 侧 Sim.lua / Camera.lua 与这里同读。sim_tests 交叉校验两侧缺省一致。
std::string resolveSocketPath(int argc, char** argv, int argvIndex, const char* envName,
                              const char* fallback) {
    if (argc > argvIndex) {
        return argv[argvIndex];
    }
    if (const char* fromEnv = std::getenv(envName)) {
        if (fromEnv[0] != '\0') {
            return fromEnv;
        }
    }
    return fallback;
}

// 多机器人寻址（C2 选项 b）：每只机器人一套独立 socket，**行协议零改动**。
// robot 0 沿用 argv/env/缺省解析出的原路径（字节不变，旧客户端无感）；robot i>0
// 在末尾的 ".sock" 前插入 "-<i>"（无 .sock 后缀则直接追加），例如
// /tmp/mybot-sim.sock → /tmp/mybot-sim-1.sock。多 agent 各自连自己的路径即可。
std::string deriveRobotPath(const std::string& base, std::size_t idx) {
    if (idx == 0) {
        return base;
    }
    const std::string suffix = "-" + std::to_string(idx);
    static const std::string kExt = ".sock";
    if (base.size() >= kExt.size() &&
        base.compare(base.size() - kExt.size(), kExt.size(), kExt) == 0) {
        return base.substr(0, base.size() - kExt.size()) + suffix + kExt;
    }
    return base + suffix;
}

// 每只机器人一份壳侧装置。命令桥/测距桥/蜘蛛步态永远同生同灭、共用同一个下标，
// 故收在一个 struct 里：原本是数条平行 vector，「同长同序」只靠 buildPerRobot 把各桥
// 建在同一个循环里维持（wantRange 就按 sensor 的长度分配、却用 cmd 的下标去写）。
// 收成一条后，长度不一致这个状态根本写不出来。
struct PerRobotRig {
    std::unique_ptr<CommandBridge> cmd;
    std::unique_ptr<SensorBridge> sensor;
    std::unique_ptr<ImuBridge> imu;      // IMU 桥（2026-10-16）：yaw/角速度/前向加速度/竖直
    std::unique_ptr<OdomBridge> odom;    // 里程计桥（2026-10-16）：地面真值位姿/速度/里程
    std::unique_ptr<Spider> spider;
};

Camera g_camera;
bool g_resetRequested = false;
bool g_toggleCamera = false;
bool g_saveRequested = false;
bool g_dragging = false;
double g_lastX = 0.0, g_lastY = 0.0;

// 退出请求（SIGTERM/SIGINT）：demo 拆链路用 kill -TERM，默认会**瞬杀**进程，
// 来不及保存场景。这里把信号折成「请求关窗」——只置一个 async-signal-safe 的
// sig_atomic_t 标志（信号处理器里绝不碰 GLFW/IO），主循环每帧轮询到它就优雅退出，
// 退出前统一 saveScene()。于是 ESC、点窗口 X、Ctrl-C、demo 的 SIGTERM 走同一条
// 「保存再退」的路。
volatile std::sig_atomic_t g_signalClose = 0;
void signalCloseHandler(int) { g_signalClose = 1; }

void framebufferSizeCallback(GLFWwindow*, int width, int height) {
    glViewport(0, 0, width, height);
}

void keyCallback(GLFWwindow* window, int key, int, int action, int) {
    if (key == GLFW_KEY_ESCAPE && action == GLFW_PRESS)
        glfwSetWindowShouldClose(window, GLFW_TRUE);
    if (key == GLFW_KEY_R && action == GLFW_PRESS)
        g_resetRequested = true;
    if (key == GLFW_KEY_C && action == GLFW_PRESS)
        g_toggleCamera = true;
    if (key == GLFW_KEY_S && action == GLFW_PRESS)
        g_saveRequested = true;
}

void mouseButtonCallback(GLFWwindow*, int button, int action, int) {
    if (button == GLFW_MOUSE_BUTTON_LEFT)
        g_dragging = (action == GLFW_PRESS);
}

void cursorPosCallback(GLFWwindow*, double x, double y) {
    if (g_dragging)
        g_camera.onMouseDrag((float)(x - g_lastX), (float)(y - g_lastY));
    g_lastX = x;
    g_lastY = y;
}

void scrollCallback(GLFWwindow*, double, double yOffset) {
    g_camera.onScroll((float)yOffset);
}

// 窗口标题即仪表盘：动作/速度/位姿/测距/搬运/三桥状态一页看全。多机器人时展示
// **主机器人**（idx 0）的命令/测距/搬运，末尾附机器人总数。
void updateTitle(GLFWwindow* window, const CommandBridge& bridge, const CaptureBridge& capture,
                 const SensorBridge& sensor, const ImuBridge& imu, const OdomBridge& odom,
                 const Robot& robot, const World& world,
                 const char* sceneName, std::size_t robotCount) {
    char cmdBuf[48];
    if (bridge.command() == SimCommand::Stop) {
        std::snprintf(cmdBuf, sizeof(cmdBuf), "stop");
    } else {
        std::snprintf(cmdBuf, sizeof(cmdBuf), "%s %.0f%%", commandName(bridge.command()),
                      bridge.speed() * 100.0f);
    }

    char lastBuf[48];
    std::snprintf(lastBuf, sizeof(lastBuf), "%s", bridge.lastLine().c_str());

    const float rangeM = world.queryRange(robot);

    char carryBuf[32];
    if (robot.isCarrying()) {
        std::snprintf(carryBuf, sizeof(carryBuf), "carrying %.1fkg", robot.carriedMass());
    } else {
        std::snprintf(carryBuf, sizeof(carryBuf), "empty");
    }

    char title[512];
    std::snprintf(title, sizeof(title),
                  "MyBot Spider | cmd %-16s last %-14s v %+.2f m/s  w %+.2f rad/s | pose (%.1f, %.1f) th %.0f deg odo %.1fm | range %.2fm | %s | scene %s | robots %zu | %s %s | cam %s sensor %s imu %s odom %s | C camera[%s]  R reset+reload  S save",
                  cmdBuf,
                  lastBuf,
                  robot.v(), robot.omega(),
                  robot.x(), robot.z(), glm::degrees(robot.theta()), robot.odo(),
                  rangeM,
                  carryBuf,
                  sceneName,
                  robotCount,
                  bridge.listening() ? "listening" : "NOT LISTENING",
                  bridge.path().c_str(),
                  capture.listening() ? "on" : "OFF",
                  sensor.listening() ? "on" : "OFF",
                  imu.listening() ? "on" : "OFF",
                  odom.listening() ? "on" : "OFF",
                  g_camera.follow ? "follow" : "free");
    glfwSetWindowTitle(window, title);
}

// 场景落点：argv[4] > MYBOT_SIM_SCENE > 缺省裸名 "default"（家目录地图目录）。
// 裸名字解析为 `<home>/maps/<名字>.scene`，缺失则从仓库模板（`sim/scenes`）播种
// 一份；含 '/' 的显式路径原样使用。返回空串 = 退回内置默认场景（无家目录 / 无模板 /
// 建目录失败——绝不让 sim 起不来）。仓库 `sim/scenes/*` 从此只读。
std::string resolveSceneForRun(int argc, char** argv) {
    const std::string raw = resolveSocketPath(argc, argv, 4, "MYBOT_SIM_SCENE", "default");
    if (raw.empty()) {
        std::fprintf(stderr, "scene: 未指定场景，用内置默认场景\n");
        return "";
    }
    const std::string home = SimPaths::mybotHome();
    const std::string resolved = SimPaths::resolveScenePath(home, raw);
    if (resolved.empty()) {
        std::fprintf(stderr,
                     "scene: 无状态目录（MYBOT_HOME 与 HOME 都未设置），无法解析 '%s'，"
                     "退回内置默认场景\n",
                     raw.c_str());
        return "";
    }
    if (raw.find('/') != std::string::npos) {
        std::fprintf(stderr, "scene: 场景文件 %s（来源 命令行/环境变量显式路径）\n",
                     resolved.c_str());
        return resolved;
    }
    const std::string maps = SimPaths::mapsDir(home);
    std::string err;
    if (!SimPaths::ensureDir0700(home, &err) || !SimPaths::ensureDir0700(maps, &err)) {
        std::fprintf(stderr, "scene: 无法准备地图目录（%s），退回内置默认场景\n", err.c_str());
        return "";
    }
    const std::size_t slash = resolved.rfind('/');
    const std::string base = slash == std::string::npos ? resolved : resolved.substr(slash + 1);
    const std::string tmpl = SimPaths::templateScene(base);
    if (tmpl.empty()) {
        std::fprintf(stderr,
                     "scene: 未找到模板 %s（MYBOT_SIM_SCENES_DIR 未命中，且 exe 相对 scenes "
                     "不存在），退回内置默认场景\n",
                     base.c_str());
        return "";
    }
    bool seeded = false;
    if (!SimPaths::seedSceneIfMissing(resolved, tmpl, &seeded, &err)) {
        std::fprintf(stderr, "scene: 播种 %s 失败（%s），退回内置默认场景\n", resolved.c_str(),
                     err.c_str());
        return "";
    }
    std::fprintf(stderr, "scene: 场景文件 %s（来源 %s）\n", resolved.c_str(),
                 seeded ? "仓库模板播种" : "家目录已有");
    return resolved;
}

}  // namespace

int main(int argc, char** argv) {
    // 五条 socket：命令（持续型即发即忘）、拍照（一问一答带二进制体）、测距、
    // IMU/里程计（一问一答浮点帧）；argv 位：1 命令 2 拍照 3 测距 4 场景 5 IMU 6 里程计
    // （同步查询）。mybot 侧 Sim.lua 与 Camera.lua 是独立驱动实例，无法共用连接。
    const std::string socketPath =
        resolveSocketPath(argc, argv, 1, "MYBOT_SIM_SOCK", SimConfig::kDefaultSocketPath);
    const std::string capturePath =
        resolveSocketPath(argc, argv, 2, "MYBOT_SIM_CAPTURE_SOCK", SimConfig::kDefaultCaptureSocketPath);
    const std::string sensorPath =
        resolveSocketPath(argc, argv, 3, "MYBOT_SIM_SENSOR_SOCK", SimConfig::kDefaultSensorSocketPath);
    const std::string imuPath =
        resolveSocketPath(argc, argv, 5, "MYBOT_SIM_IMU_SOCK", SimConfig::kDefaultImuSocketPath);
    const std::string odomPath =
        resolveSocketPath(argc, argv, 6, "MYBOT_SIM_ODOM_SOCK", SimConfig::kDefaultOdomSocketPath);

    if (!glfwInit()) {
        std::fprintf(stderr, "failed to initialize GLFW\n");
        return 1;
    }
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

    GLFWwindow* window = glfwCreateWindow(1280, 800, "MyBot Spider Simulator", nullptr, nullptr);
    if (!window) {
        std::fprintf(stderr, "failed to create window\n");
        glfwTerminate();
        return 1;
    }
    glfwMakeContextCurrent(window);
    glfwSetFramebufferSizeCallback(window, framebufferSizeCallback);
    glfwSetKeyCallback(window, keyCallback);
    glfwSetMouseButtonCallback(window, mouseButtonCallback);
    glfwSetCursorPosCallback(window, cursorPosCallback);
    glfwSetScrollCallback(window, scrollCallback);
    glfwSwapInterval(1);

    if (!gladLoadGLLoader((GLADloadproc)glfwGetProcAddress)) {
        std::fprintf(stderr, "failed to load OpenGL\n");
        glfwTerminate();
        return 1;
    }

    glEnable(GL_DEPTH_TEST);

    // glfwTerminate 必须**晚于**所有持 GL 资源的对象（Shader/Mesh/Spider）析构——
    // 它们的析构里是 glDeleteProgram/glDeleteVertexArrays/glDeleteBuffers，上下文
    // 已经没了就是 use-after-free（退出时段错误）。此前显式在 main 末尾调
    // glfwTerminate()，而这些对象是更早声明的局部量、析构序在 terminate 之后，
    // 只是过去 demo 用 SIGTERM 瞬杀进程、析构根本没跑，问题被掩盖了。改用一个
    // **早声明**的 RAII 守卫：C++ 析构序 = 声明序逆序，它最后走，于是先释放全部
    // GL 再 terminate。建窗/加载 GL 之前的早退失败路径不经过这里，仍各自手动 terminate。
    struct GlfwGuard { ~GlfwGuard() { glfwTerminate(); } } glfwGuard;

    // 拍照桥单条即可：它抓的是整个 GL 视口（一帧全景），与机器人数量无关。
    // 命令桥/测距桥则**每只机器人一套**（见 deriveRobotPath），多 agent 各连各的。
    // 监听失败不退出：窗口照常开着，标题上标出 NOT LISTENING 让人去查路径，
    // 比直接崩掉好定位（多半是路径太长或目录不可写）。
    CaptureBridge capture(capturePath);
    if (capture.listening()) {
        std::fprintf(stderr, "listening for capture requests on %s\n", capture.path().c_str());
        std::fprintf(stderr, "  try: printf 'capture\\n' | socat - UNIX-CONNECT:%s | head -c 64\n",
                     capture.path().c_str());
    }

    Shader phong(kPhongVs, kPhongFs);
    Shader lines(kLineVs, kLineFs);
    SceneMeshes meshes = buildSceneMeshes();

    // 场景：argv[4] > MYBOT_SIM_SCENE > 缺省裸名 default，落家目录地图目录
    // （见 resolveSceneForRun）。环境与代码解耦的落点：障碍布局与机器人数量都来自
    // 文件。save 只写这个启动时定下的路径——socket 线上不收路径参数，杜绝「连任意
    // 文件写」原语（与 Camera.lua 同源）。
    const std::string scenePath = resolveSceneForRun(argc, argv);

    // 仿真逻辑（场景会话 + 每帧推进 + 指令派发）全在 GL 无关的 SimEngine 里，
    // 可 headless 单测；壳只负责窗口/输入/渲染/HUD，把语义动作喂引擎再 step()。
    SimEngine engine(scenePath);
    engine.reloadScene();

    // robot 0 用原路径（字节不变），robot i>0 用派生路径。数量随场景 robot 行数，
    // reload 后可变，故抽成可按新数量重建的过程（R 键重载若机器人增减，这里同步重建 socket）。
    std::vector<PerRobotRig> rigs;
    auto buildPerRobot = [&](std::size_t n) {
        rigs.clear();
        for (std::size_t i = 0; i < n; ++i) {
            PerRobotRig rig;
            rig.cmd = std::make_unique<CommandBridge>(deriveRobotPath(socketPath, i));
            rig.sensor = std::make_unique<SensorBridge>(deriveRobotPath(sensorPath, i));
            rig.imu = std::make_unique<ImuBridge>(deriveRobotPath(imuPath, i));
            rig.odom = std::make_unique<OdomBridge>(deriveRobotPath(odomPath, i));
            rig.spider = std::make_unique<Spider>();
            if (rig.cmd->listening()) {
                std::fprintf(stderr, "listening for robot[%zu] commands on %s\n", i,
                             rig.cmd->path().c_str());
                std::fprintf(stderr, "  try: socat - UNIX-CONNECT:%s   then type: forward\n",
                             rig.cmd->path().c_str());
            }
            if (rig.sensor->listening()) {
                std::fprintf(stderr, "listening for robot[%zu] sensor requests on %s\n", i,
                             rig.sensor->path().c_str());
                std::fprintf(stderr, "  try: printf 'range\\n' | socat - UNIX-CONNECT:%s\n",
                             rig.sensor->path().c_str());
            }
            if (rig.imu->listening()) {
                std::fprintf(stderr, "listening for robot[%zu] imu requests on %s\n", i,
                             rig.imu->path().c_str());
                std::fprintf(stderr, "  try: printf 'imu\\n' | socat - UNIX-CONNECT:%s\n",
                             rig.imu->path().c_str());
            }
            if (rig.odom->listening()) {
                std::fprintf(stderr, "listening for robot[%zu] odom requests on %s\n", i,
                             rig.odom->path().c_str());
                std::fprintf(stderr, "  try: printf 'odom\\n' | socat - UNIX-CONNECT:%s\n",
                             rig.odom->path().c_str());
            }
            rigs.push_back(std::move(rig));
        }
    };
    buildPerRobot(engine.robotCount());

    const glm::vec3 lightDir = glm::normalize(glm::vec3(-0.45f, -1.0f, -0.3f));
    const glm::vec3 lightColor(1.0f, 0.98f, 0.92f);

    // SIGTERM/SIGINT → 请求关窗（见 g_signalClose 注释）：让 demo 的 kill -TERM
    // 与 Ctrl-C 都走「保存再退」而非瞬杀。SIGPIPE 不在此列——三桥 send 一律
    // MSG_NOSIGNAL 折成 EPIPE，进程级无需处理。
    std::signal(SIGTERM, signalCloseHandler);
    std::signal(SIGINT, signalCloseHandler);

    double last = glfwGetTime();
    while (!glfwWindowShouldClose(window) && !g_signalClose) {
        double now = glfwGetTime();
        float dt = std::min(0.05f, (float)(now - last));
        last = now;

        // 记下本帧各机器人是否有测距请求；真正算距离要等 step() 之后（拿到本帧
        // 最终位姿），故此处只收标志。拍照同理：抓帧要等画完、SwapBuffers 之前。
        const bool wantCapture = capture.poll();
        std::vector<char> wantRange(rigs.size(), 0);
        std::vector<char> wantImu(rigs.size(), 0);
        std::vector<char> wantOdom(rigs.size(), 0);
        for (std::size_t i = 0; i < rigs.size(); ++i) {
            rigs[i].cmd->poll();
            wantRange[i] = rigs[i].sensor->poll() ? 1 : 0;
            wantImu[i] = rigs[i].imu->poll() ? 1 : 0;
            wantOdom[i] = rigs[i].odom->poll() ? 1 : 0;
        }

        if (g_resetRequested) {
            // 复位 = 场景连同所有机器人回到装载时状态（文件版重读文件、内置版回默认）
            engine.reloadScene();
            // 机器人数量可能随新场景变化：变了就重建 socket/蜘蛛，没变只复位步态。
            if (engine.robotCount() != rigs.size()) {
                buildPerRobot(engine.robotCount());
                wantRange.assign(rigs.size(), 0);
                wantImu.assign(rigs.size(), 0);
                wantOdom.assign(rigs.size(), 0);
            } else {
                for (PerRobotRig& rig : rigs) {
                    rig.spider->reset();
                }
            }
            g_resetRequested = false;
        }
        if (g_saveRequested) {
            engine.saveScene();
            g_saveRequested = false;
        }
        if (g_toggleCamera) {
            g_camera.follow = !g_camera.follow;
            g_toggleCamera = false;
        }

        // 语义动作喂引擎：每只机器人从各自的命令桥取持续型状态（同步）+ drain 一次性
        // 事件到空——每条必触发一次（连续两次 fdist 不再互相吞）。idx 寻址到对应 slot。
        for (std::size_t i = 0; i < rigs.size(); ++i) {
            engine.applyContinuous(rigs[i].cmd->command(), rigs[i].cmd->speed(), i);
            SimEvent ev;
            while (rigs[i].cmd->pollEvent(ev)) {
                engine.applyEvent(ev, i);
            }
        }

        engine.step(dt);
        // 每只蜘蛛按各自机器人的线速度生成步态（外观与物理分离）。
        for (std::size_t i = 0; i < rigs.size(); ++i) {
            rigs[i].spider->update(dt, engine.robot(i).v());
        }

        // 测距响应：碰撞解算完成后算距离，保证拿到的是本帧最终位姿。逐机器人应答
        // 各自的测距桥。
        for (std::size_t i = 0; i < rigs.size(); ++i) {
            if (!wantRange[i]) {
                continue;
            }
            const float dist = engine.queryRange(i);
            const int distMm = static_cast<int>(dist * 1000.0f + 0.5f);
            if (!rigs[i].sensor->sendRange(distMm)) {
                rigs[i].sensor->sendError("range send failed");
            }
        }
        // IMU/里程计响应：与测距同一口径——碰撞解算后应答，快照即本帧最终状态。
        for (std::size_t i = 0; i < rigs.size(); ++i) {
            const Robot& r = engine.robot(i);
            if (wantImu[i] &&
                !rigs[i].imu->sendImu(glm::degrees(r.theta()), r.omega(), r.accel(), r.vy(),
                                       r.isAirborne())) {
                rigs[i].imu->sendError("imu send failed");
            }
            if (wantOdom[i] &&
                !rigs[i].odom->sendOdom(r.x(), r.z(), glm::degrees(r.theta()), r.v(), r.odo())) {
                rigs[i].odom->sendError("odom send failed");
            }
        }

        // 相机跟随主机器人（idx 0）。跟随目标 y 带上机体离地高度，跳跃时镜头跟着抬。
        if (g_camera.follow) {
            glm::vec3 robotPos(engine.robot().x(), engine.robot().y() + 0.2f, engine.robot().z());
            float k = std::min(1.0f, 5.0f * dt);
            g_camera.target += (robotPos - g_camera.target) * k;
        }

        int width = 1, height = 1;
        glfwGetFramebufferSize(window, &width, &height);
        glViewport(0, 0, width, height);
        glClearColor(0.62f, 0.73f, 0.86f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        glm::mat4 projection = glm::perspective(glm::radians(45.0f), (float)width / (float)height, 0.1f, 300.0f);
        glm::mat4 view = g_camera.view();

        phong.use();
        phong.setMat4("view", view);
        phong.setMat4("projection", projection);
        phong.setVec3("lightDir", lightDir);
        phong.setVec3("lightColor", lightColor);
        phong.setVec3("viewPos", g_camera.position());

        glm::mat4 ground = glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, -0.05f, 0.0f)) *
                           glm::scale(glm::mat4(1.0f), glm::vec3(62.0f, 0.1f, 62.0f));
        phong.setMat4("model", ground);
        phong.setVec3("objectColor", glm::vec3(0.38f, 0.46f, 0.36f));
        meshes.cube.draw();

        // 障碍盒：unit cube 经 translate(center)*rotate(yaw,+Y)*scale(2*half) 摆到位。
        // 绕 +Y 旋转 yaw 把局部 +X 映到世界 (cos yaw, -sin yaw)，与 world.cpp 的
        // OBB 局部系约定同号。
        for (const Obstacle& ob : engine.world().obstacles()) {
            glm::mat4 m = glm::translate(glm::mat4(1.0f), ob.center) *
                          glm::rotate(glm::mat4(1.0f), ob.yaw, glm::vec3(0.0f, 1.0f, 0.0f)) *
                          glm::scale(glm::mat4(1.0f), ob.half * 2.0f);
            phong.setMat4("model", m);
            phong.setVec3("objectColor", ob.color);
            meshes.cube.draw();
        }

        // 逐只渲染机器人：每只用自己的 Spider 步态实例（腿相位各自独立）。
        for (std::size_t i = 0; i < engine.robotCount(); ++i) {
            drawSpider(engine.robot(i), *rigs[i].spider, phong, meshes);
        }

        lines.use();
        lines.setMat4("mvp", projection * view);
        lines.setVec3("color", glm::vec3(0.18f, 0.22f, 0.18f));
        meshes.grid.draw();

        // 标题栏展示主机器人（idx 0）的状态 + 机器人总数。
        updateTitle(window, *rigs[0].cmd, capture, *rigs[0].sensor, *rigs[0].imu,
                    *rigs[0].odom, engine.robot(),
                    engine.world(), engine.sceneName().c_str(), engine.robotCount());

        // 抓帧回传放在 SwapBuffers 之前：此刻 GL_BACK 是刚画好的这一帧。
        if (wantCapture) {
            int capW = 0, capH = 0;
            std::vector<unsigned char> jpeg = grabFrameJpeg(SimConfig::kJpegQuality, capW, capH);
            if (jpeg.empty()) {
                capture.sendError("frame grab or jpeg encode failed");
            } else {
                capture.sendFrame(jpeg.data(), jpeg.size(), capW, capH);
            }
        }

        glfwSwapBuffers(window);
        glfwPollEvents();
    }

    // 退出即保存：无论 ESC / 点窗口 X / Ctrl-C / demo 的 SIGTERM，都把当前世界
    // 状态（障碍位置 + 各机器人位姿 + 搬运态）原子写回启动时配置的场景文件，
    // 下次从改过的环境续用。未配置场景路径（内置默认）时 saveScene 自行 no-op。
    engine.saveScene();

    // glfwTerminate 由上面早声明的 glfwGuard 在所有 GL 对象析构后统一调用。
    return 0;
}
