#pragma once

// sim_tests 各域套件的入口声明。**执行顺序不在这里**——由 main.cpp 的名册单点决定
// （拆前拆后逐字一致，顺序即 stderr 上 [FAIL] 的出现顺序）；本文件只按域分组声明，
// 各 test_*.cpp 把定义放进同一个 namespace，于是「声明了没人实现」会直接链接不过。
//
// 反方向没有自动守门，说清楚：某个套件**实现了却忘了进 main.cpp 的名册**，链接器不
// 报错、退出码照样 0，唯一症状是汇总行的通过数变少（少掉那个套件的断言）。所以本轮
// 把「断言总数 = 拆分前基线」列为验收项，改这套测试时也请拿汇总行的数字对一下账。
namespace SimTests {

// ---- Robot：平面运动学 + 相对运动（test_robot.cpp）----
void testKinematics();
void testRelativeMotion();
void testOdomAccel();

// ---- World：测距/碰撞/搬运/OBB 几何/放置解算（test_world.cpp）----
void testQueryRange();
void testCollisions();
void testPickPlace();
void testYawGeometry();
void testYawCarry();
void testObbOverlap();
void testPlaceResolve();
void testPlaceInfeasible();
void testStacking();
void testPickBlockedByStack();
void testSettleUnsupported();

// ---- 场景文件 IO 与状态目录路径（test_scene.cpp）----
void testSceneIo();
void testSimPaths();

// ---- 动作表：内部不变量 + 与 modules/Sim.lua 的跨语言一致性（test_contract.cpp）----
void testActionTable();
void testSharedConstants();
void testActionTableDispatch();

// ---- 五座 AF_UNIX 桥 + 请求-应答基类（test_bridges.cpp）----
void testCommandBridge();
void testSensorBridge();
void testImuBridge();
void testOdomBridge();
void testCaptureBridge();
void testRequestResponseBase();

// ---- SimEngine：headless 仿真逻辑（test_engine.cpp）----
void testSimEngine();
void testMultiRobot();
void testEngineMultiRobot();
void testJump();

}  // namespace SimTests
