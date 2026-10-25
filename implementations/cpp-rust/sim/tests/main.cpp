// simcore 单元测试入口：只负责按名册调用各域套件、出汇总行与退出码。用例正文按域分在
// test_*.cpp（robot / world / scene / bridges / contract / engine），共享底座与拆分约定
// 见 harness.h，套件声明见 suites.h。
//
// 覆盖 GL 无关的核心逻辑——运动学、相对运动、射线测距、碰撞、搬运、场景文件 IO、五座
// AF_UNIX 桥的线上协议、动作码表的跨语言一致性、引擎。GLFW/OpenGL 可视化壳**不在覆盖
// 范围，也没有任何自动守门兜住它**：scripts/sim_agent_demo.sh 那条三层端到端链路是
// 手动冒烟（要显示器、要真模型凭据 mybot.llm.json、要先 bash scripts/build_sim.sh），
// run_all.sh / CI / pre-push 都不调用它；本仓唯一对它的机械检查是 run_all_selftest.sh
// 静态比对其中 MYBOT_HOME 的拼法。GL 壳改坏了要靠人跑一次 demo 才会发现。
//
// 运行：./sim/build/sim_tests（或 ctest --test-dir sim/build）
// 风格与 test/ 的 Lua 守门一致：不起测试框架，宏断言 + 汇总退出码。
// socket 用例的监听路径带 pid，与开发会话里可能开着的真仿真器互不干扰。

#include <cstdio>

#include "harness.h"
#include "suites.h"

// 名册与汇总行逐字保持单文件时代的写法。顺序有意义：它决定 stderr 上 [FAIL] 的出现
// 顺序，也决定共享 /tmp 路径的用例之间谁先建谁先删。
using namespace SimTests;

int main() {
    testKinematics();
    testRelativeMotion();
    testOdomAccel();
    testQueryRange();
    testCollisions();
    testPickPlace();
    testYawGeometry();
    testYawCarry();
    testObbOverlap();
    testPlaceResolve();
    testPlaceInfeasible();
    testStacking();
    testPickBlockedByStack();
    testSettleUnsupported();
    testSceneIo();
    testSimPaths();
    testActionTable();
    testSharedConstants();
    testCommandBridge();
    testActionTableDispatch();
    testSensorBridge();
    testImuBridge();
    testOdomBridge();
    testCaptureBridge();
    testRequestResponseBase();
    testSimEngine();
    testMultiRobot();
    testEngineMultiRobot();
    testJump();

    std::printf("sim_tests: %d 通过, %d 失败\n", g_total - g_failed, g_failed);
    return g_failed == 0 ? 0 : 1;
}
