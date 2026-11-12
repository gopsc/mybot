// 场景文件 IO 与状态目录路径：行文本 round-trip、解析容错、SimPaths 的家目录
// 取值链/场景路径解析/建目录 0700/播种不覆盖。
// 拆分约定与共享工具（断言记账、socket 客户端助手）见 harness.h；套件名册见
// suites.h。本文件的用例正文自拆分前的单文件 sim/tests/main.cpp 逐字搬迁
// （2026-10-04，第三轮重构 Phase 21），未改断言、未改用例数。

#include <sys/stat.h>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include <glm/glm.hpp>

#include "harness.h"
#include "robot.h"
#include "sim_engine.h"
#include "sim_paths.h"
#include "suites.h"
#include "world.h"

namespace SimTests {

// ---- 场景文件：round-trip 与解析容错 ----

void testSceneIo() {
    const std::string path = "/tmp/mybot-sim-tests-" + std::to_string(::getpid()) + "-scene.scene";

    // round-trip：障碍 + 多机器人位姿/搬运（writeScene 一律写 v3）
    SceneState st;
    st.obstacles = {
        {{1.0f, 0.2f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1.0f, 0.0f, 0.0f}, 7.5f, 0.0f},
        {{3.0f, 0.2f, 1.0f}, {0.3f, 0.3f, 0.3f}, {0.0f, 1.0f, 0.0f}, 2.0f, glm::radians(30.0f)},
    };
    st.robots = {
        {1.5f, -0.25f, 0.7f, 1},   // robot0：位姿 + 搬运 idx1
        {-2.0f, 0.5f, 1.57f, -1},  // robot1：空载
    };
    check(writeScene(path, st), "writeScene 成功");
    SceneState back;
    check(readScene(path, back), "readScene 成功");
    check(back.obstacles.size() == 2, "障碍数 round-trip");
    check(near(back.obstacles[1].mass, 2.0f, 1e-4f), "质量 round-trip");
    check(near(back.obstacles[0].center.x, 1.0f, 1e-4f) &&
              near(back.obstacles[1].half.z, 0.3f, 1e-4f) &&
              near(back.obstacles[0].color.g, 0.0f, 1e-4f),
          "盒字段 round-trip");
    check(near(back.obstacles[1].yaw, glm::radians(30.0f), 1e-4f), "盒朝向 round-trip");
    check(back.robots.size() == 2, "机器人数 round-trip（v2 多 robot 行）");
    check(near(back.robots[0].x, 1.5f, 1e-4f) && near(back.robots[0].z, -0.25f, 1e-4f) &&
              near(back.robots[0].theta, 0.7f, 1e-4f),
          "robot0 位姿 round-trip");
    check(back.robots[0].carriedIdx == 1, "robot0 搬运索引 round-trip");
    check(near(back.robots[1].x, -2.0f, 1e-4f) && near(back.robots[1].z, 0.5f, 1e-4f) &&
              back.robots[1].carriedIdx == -1,
          "robot1 位姿/空载 round-trip");

    // writeScene 一律写 v3 魔数（v3 是 v1/v2 超集，box 行带朝向）
    {
        std::ifstream mf(path);
        std::string magic;
        std::getline(mf, magic);
        check(magic.rfind("mybot-sim scene v3", 0) == 0, "writeScene 落 v3 魔数");
    }

    // applyScene：只整体替换障碍集合（搬运状态属于每只 Robot，不由场景承载）
    World w(std::vector<Obstacle>{});
    w.applyScene(back);
    check(w.obstacles().size() == 2, "applyScene 替换障碍集合");
    // 搬运恢复是调用方（SimEngine.reloadScene）按各 RobotSpawn.carriedIdx 落到对应 Robot：
    const int c0 = back.robots[0].carriedIdx;
    Robot carried;
    carried.setCarried(c0, w.obstacles()[c0].mass);
    check(carried.isCarrying() && near(carried.carriedMass(), 2.0f, 1e-4f),
          "按场景索引恢复某只机器人的搬运态");
    check(near(carried.effectiveMaxSpeed(), Robot::kMaxSpeed / (1.0f + 2.0f * 0.01f), 1e-4f),
          "恢复搬运后减速生效");

    // v1 文件（单 robot 行）仍可读，读成 1 只；坏行/未知行告警跳过不毁整个文件
    writeTextFile(path,
                  "mybot-sim scene v1\n"
                  "# 注释行\n"
                  "\n"
                  "box abc def ghi\n"
                  "bogus 1 2 3\n"
                  "box 1 0.2 0 0.2 0.2 0.2 1 0 0\n"
                  "robot 1 2 90\n");
    SceneState st2;
    check(readScene(path, st2), "v1 容错解析成功");
    check(st2.obstacles.size() == 1, "坏行/未知行被跳过");
    check(near(st2.obstacles[0].mass, 51.2f, 0.1f), "缺省质量按体积×800");
    check(near(st2.obstacles[0].yaw, 0.0f, 1e-6f), "v1 box 无朝向字段读成 yaw=0");
    check(st2.robots.size() == 1, "v1 单 robot 行读成 1 只");
    check(near(st2.robots[0].theta, glm::radians(90.0f), 1e-4f), "theta 度→弧度换算");
    check(st2.robots[0].carriedIdx == -1, "robot 行无 carried 即无搬运");

    // 缺 robot 行：补一只原点默认（robots 至少 1 只，保证 reload 后 robot() 可访问）
    writeTextFile(path, "mybot-sim scene v2\nbox 1 0.2 0 0.2 0.2 0.2 1 0 0\n");
    check(readScene(path, st2) && st2.robots.size() == 1, "缺 robot 行补一只默认");
    check(near(st2.robots[0].x, 0.0f, 1e-6f) && near(st2.robots[0].z, 0.0f, 1e-6f) &&
              near(st2.robots[0].theta, 0.0f, 1e-6f),
          "默认机器人在原点 theta=0");

    // 多 robot 行（v2）：按出现顺序读进 robots；carried 越界（无 box）归一为 -1
    writeTextFile(path,
                  "mybot-sim scene v2\n"
                  "robot 0 0 0\n"
                  "robot 1 2 90\n"
                  "robot -1 -2 -45 0\n");
    check(readScene(path, st2) && st2.robots.size() == 3, "v2 多 robot 行按序读入");
    check(near(st2.robots[1].x, 1.0f, 1e-4f) && near(st2.robots[1].z, 2.0f, 1e-4f) &&
              near(st2.robots[1].theta, glm::radians(90.0f), 1e-4f),
          "第二只位姿/朝向正确");
    check(st2.robots[2].carriedIdx == -1, "carried 越界按无搬运处理");

    // v3：box 行追加第 11 个数 yaw_deg（度→弧度）；v2 文件无该字段读成 yaw=0
    writeTextFile(path,
                  "mybot-sim scene v3\n"
                  "box 1 0.2 0 0.2 0.2 0.2 1 0 0 5 30\n"
                  "box 2 0.2 0 0.2 0.2 0.2 1 0 0 5\n"
                  "robot 0 0 0\n");
    SceneState st3;
    check(readScene(path, st3) && st3.obstacles.size() == 2, "v3 box 行解析成功");
    check(near(st3.obstacles[0].mass, 5.0f, 1e-4f), "v3 box mass 解析");
    check(near(st3.obstacles[0].yaw, glm::radians(30.0f), 1e-4f), "v3 box yaw_deg→弧度");
    check(near(st3.obstacles[1].yaw, 0.0f, 1e-6f), "v3 box 缺 yaw_deg 读成 0");

    // 缺魔数：整文件拒绝
    writeTextFile(path, "# 只有注释\nbox 1 2 3 4 5 6 7 8 9\n");
    check(!readScene(path, st2), "缺魔数整文件拒绝");

    // 缺文件
    check(!readScene("/tmp/mybot-sim-tests-not-exist.scene", st2), "缺文件返回 false");

    // 原子写不残留 .tmp
    check(writeScene(path, st), "再次 writeScene 成功");
    const std::string tmp = path + ".tmp";
    FILE* probe = std::fopen(tmp.c_str(), "r");
    check(probe == nullptr, "原子写不残留 .tmp");
    if (probe) {
        std::fclose(probe);
    }

    ::unlink(path.c_str());
    ::unlink(tmp.c_str());
}

// ---- 状态目录路径（SimPaths）：家目录链、场景路径解析、建目录 0700、播种 ----

void testSimPaths() {
    const std::string tag = std::to_string(::getpid());
    const std::string root = "/tmp/mybot-sim-tests-" + tag + "-paths";

    // 本用例会改 HOME / MYBOT_HOME，用完原样还原，不给后续用例留环境副作用
    const char* oldHome = std::getenv("HOME");
    const std::string savedHome = oldHome ? oldHome : "";
    const char* oldMh = std::getenv("MYBOT_HOME");
    const std::string savedMh = oldMh ? oldMh : "";

    // mybotHome：MYBOT_HOME > HOME/.mybot > 空（顺序执行，故 setenv 安全）
    ::setenv("MYBOT_HOME", root.c_str(), 1);
    check(SimPaths::mybotHome() == root, "mybotHome 取 MYBOT_HOME");
    ::unsetenv("MYBOT_HOME");
    ::setenv("HOME", "/home/testuser", 1);
    check(SimPaths::mybotHome() == "/home/testuser/.mybot", "mybotHome 回落 $HOME/.mybot");
    ::unsetenv("HOME");
    check(SimPaths::mybotHome().empty(), "两处都没有 → 空家目录");

    // mapsDir / resolveScenePath
    check(SimPaths::mapsDir(root) == root + "/maps", "mapsDir 拼 /maps");
    check(SimPaths::mapsDir("").empty(), "mapsDir 空家目录 → 空");
    check(SimPaths::resolveScenePath(root, "").empty(), "空场景名 → 空");
    check(SimPaths::resolveScenePath(root, "default") == root + "/maps/default.scene",
          "裸名 → <maps>/<名>.scene");
    check(SimPaths::resolveScenePath(root, "sim/scenes/x.scene") == "sim/scenes/x.scene",
          "含 '/' 的显式路径原样");
    check(SimPaths::resolveScenePath("", "default").empty(), "无家目录 + 裸名 → 空");
    check(SimPaths::resolveScenePath("", "/abs/x.scene") == "/abs/x.scene",
          "无家目录 + 绝对路径仍原样");

    // ensureDir0700：逐级建出且只对新建层级设 0700
    const std::string deep = root + "/a/b/c";
    std::string err;
    check(SimPaths::ensureDir0700(deep, &err), "ensureDir0700 成功");
    for (const std::string& p : {root, root + "/a", root + "/a/b", deep}) {
        struct stat st;
        const bool ok = ::stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
        check(ok, "目录建出");
        check(ok && (st.st_mode & 0777) == 0700, "目录权限 0700");
    }
    check(SimPaths::ensureDir0700(deep, &err), "ensureDir0700 幂等（已存在不报错）");

    // seedSceneIfMissing：缺 → 复制且 0600，无 .tmp 残留
    const std::string tmpl = root + "/tmpl.scene";
    writeTextFile(tmpl, "mybot-sim scene v3\nbox 1 0.2 0 0.2 0.2 0.2 1 0 0\n");
    check(SimPaths::ensureDir0700(root + "/maps", &err), "先备好 maps 目录");
    const std::string dest = root + "/maps/default.scene";
    bool seeded = false;
    check(SimPaths::seedSceneIfMissing(dest, tmpl, &seeded, &err), "播种成功");
    check(seeded, "首次播种 seeded=true");
    {
        struct stat st;
        check(::stat(dest.c_str(), &st) == 0 && S_ISREG(st.st_mode), "播种出目标文件");
        check((st.st_mode & 0777) == 0600, "播种文件权限 0600");
        std::ifstream in(dest);
        std::string body((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        check(body.find("mybot-sim scene v3") == 0, "播种内容与模板一致");
        check(::access((dest + ".tmp." + tag).c_str(), F_OK) != 0, "无 .tmp 残留");
    }

    // 已存在 → 绝不覆盖（seeded=false）
    writeTextFile(dest, "已存在的内容\n");
    seeded = true;
    check(SimPaths::seedSceneIfMissing(dest, tmpl, &seeded, &err), "已存在时返回成功");
    check(!seeded, "已存在不覆盖 seeded=false");
    {
        std::ifstream in(dest);
        std::string body((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        check(body == "已存在的内容\n", "既有内容未被改写");
    }

    // templateScene：编译期先例指向源码树 sim/scenes，故缺省模板能命中
    check(!SimPaths::templateScene("default.scene").empty(),
          "templateScene 命中源码树 sim/scenes/default.scene");
    check(SimPaths::templateScene("no-such-scene.scene").empty(), "不存在的模板 → 空");

    if (oldHome) {
        ::setenv("HOME", savedHome.c_str(), 1);
    } else {
        ::unsetenv("HOME");
    }
    if (oldMh) {
        ::setenv("MYBOT_HOME", savedMh.c_str(), 1);
    } else {
        ::unsetenv("MYBOT_HOME");
    }
}

}  // namespace SimTests
