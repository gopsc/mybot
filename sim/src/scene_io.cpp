// 场景文件的读写实现（行文本格式）。声明与格式文档在 world.h 的尾部——SceneState /
// Obstacle / RobotSpawn 三个类型都在那儿，声明跟着类型走；本文件只是把实现从
// world.cpp 里分出来（2026-10-04，第三轮重构 Phase 21），故没有配套的 scene_io.h。
// 分出的理由：world.cpp 是「世界里的物体怎么相互作用」（碰撞推出、测距、拾取放置），
// 场景文件 IO 是「这些物体怎么落到磁盘、怎么读回来」，两件事只在数据类型上相交。
#include "world.h"

#include <sys/stat.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <glm/glm.hpp>

#include "sim_config.h"

namespace {

// 场景文件魔数：v1（单机器人）/v2（多机器人）/v3（box 行带朝向）都收，写一律 v3。
constexpr char kSceneMagicV1[] = "mybot-sim scene v1";
constexpr char kSceneMagicV2[] = "mybot-sim scene v2";
constexpr char kSceneMagicV3[] = "mybot-sim scene v3";

// 多机器人场景的机器人数上限（防滥用；每只一套 socket，太多也没意义）。
constexpr std::size_t kMaxSceneRobots = 64;

// 从 p 起连续解析至多 want 个浮点数，got 返回实际解析个数。
// 遇到非数字即停（返回 false）；解析不足 want 个不算错——由调用方按各自
// 的「必填/可选字段数」校验 got。
bool parseFloats(const char* p, float* vals, int want, int& got) {
    got = 0;
    while (got < want) {
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') {
            ++p;
        }
        if (*p == '\0') {
            break;
        }
        char* end = nullptr;
        const double v = std::strtod(p, &end);
        if (end == p) {
            return false;
        }
        vals[got++] = static_cast<float>(v);
        p = end;
    }
    return true;
}

}  // namespace

bool readScene(const std::string& path, SceneState& out) {
    FILE* f = std::fopen(path.c_str(), "r");
    if (!f) {
        std::fprintf(stderr, "scene: 无法打开 %s\n", path.c_str());
        return false;
    }

    SceneState st;
    char line[SimConfig::kMaxSceneLine];
    bool magicSeen = false;
    bool ok = true;
    while (std::fgets(line, sizeof(line), f)) {
        // 去注释与首尾空白
        if (char* hash = std::strchr(line, '#')) {
            *hash = '\0';
        }
        char* text = line;
        while (*text == ' ' || *text == '\t' || *text == '\r' || *text == '\n') {
            ++text;
        }
        if (*text == '\0') {
            continue;
        }

        if (!magicSeen) {
            if (std::strncmp(text, kSceneMagicV1, sizeof(kSceneMagicV1) - 1) == 0 ||
                std::strncmp(text, kSceneMagicV2, sizeof(kSceneMagicV2) - 1) == 0 ||
                std::strncmp(text, kSceneMagicV3, sizeof(kSceneMagicV3) - 1) == 0) {
                magicSeen = true;
            } else {
                std::fprintf(stderr, "scene: 首个有效行不是魔数 '%s'/'%s'/'%s'，拒绝整个文件\n",
                             kSceneMagicV1, kSceneMagicV2, kSceneMagicV3);
                ok = false;
                break;
            }
            continue;
        }

        char word[16] = {};
        if (std::sscanf(text, "%15s", word) != 1) {
            continue;
        }
        const char* rest = text + std::strlen(word);

        if (std::strcmp(word, "box") == 0) {
            float v[11] = {};
            int got = 0;
            if (!parseFloats(rest, v, 11, got) || (got != 9 && got != 10 && got != 11)) {
                std::fprintf(stderr, "scene: box 行需要 9/10/11 个数（cx cy cz hx hy hz r g b [mass [yaw_deg]]），跳过: %s", text);
                continue;
            }
            if (v[3] <= 0.0f || v[4] <= 0.0f || v[5] <= 0.0f) {
                std::fprintf(stderr, "scene: box 半尺寸必须为正，跳过: %s", text);
                continue;
            }
            if (st.obstacles.size() >= SimConfig::kMaxSceneObstacles) {
                std::fprintf(stderr, "scene: 障碍数超过上限 %zu，多余忽略\n", SimConfig::kMaxSceneObstacles);
                continue;
            }
            Obstacle ob;
            ob.center = glm::vec3(v[0], v[1], v[2]);
            ob.half = glm::vec3(v[3], v[4], v[5]);
            ob.color = glm::vec3(v[6], v[7], v[8]);
            ob.mass = (got >= 10) ? v[9]
                                  : 8.0f * ob.half.x * ob.half.y * ob.half.z * SimConfig::kDefaultDensity;
            ob.yaw = (got == 11) ? glm::radians(v[10]) : 0.0f;
            st.obstacles.push_back(ob);
        } else if (std::strcmp(word, "robot") == 0) {
            float v[4] = {};
            int got = 0;
            if (!parseFloats(rest, v, 4, got) || (got != 3 && got != 4)) {
                std::fprintf(stderr, "scene: robot 行需要 3 或 4 个数（x z theta_deg [carried_idx]），跳过: %s", text);
                continue;
            }
            if (st.robots.size() >= kMaxSceneRobots) {
                std::fprintf(stderr, "scene: 机器人数超过上限 %zu，多余忽略\n", kMaxSceneRobots);
                continue;
            }
            RobotSpawn rs;
            rs.x = v[0];
            rs.z = v[1];
            rs.theta = glm::radians(v[2]);
            rs.carriedIdx = (got == 4) ? static_cast<int>(v[3]) : -1;
            st.robots.push_back(rs);
        } else {
            std::fprintf(stderr, "scene: 未知行类型 '%s'（忽略）\n", word);
        }
    }
    std::fclose(f);

    if (!ok || !magicSeen) {
        return false;
    }
    if (st.robots.empty()) {
        st.robots.push_back(RobotSpawn{});  // 缺 robot 行：补一只原点默认
    }
    for (RobotSpawn& rs : st.robots) {
        if (rs.carriedIdx >= (int)st.obstacles.size()) {
            std::fprintf(stderr, "scene: carried_idx=%d 越界（共 %zu 个障碍），按无搬运处理\n",
                         rs.carriedIdx, st.obstacles.size());
            rs.carriedIdx = -1;
        }
    }
    out = std::move(st);
    return true;
}

bool writeScene(const std::string& path, const SceneState& state) {
    const std::string tmp = path + ".tmp";
    FILE* f = std::fopen(tmp.c_str(), "w");
    if (!f) {
        std::fprintf(stderr, "scene: 无法写 %s\n", tmp.c_str());
        return false;
    }

    std::fprintf(f, "%s\n", kSceneMagicV3);
    std::fprintf(f, "# box cx cy cz hx hy hz r g b [mass（缺省=体积x800kg/m3）[yaw_deg（绕Y朝向，0=轴对齐）]]\n");
    std::fprintf(f, "# robot x z theta_deg [carried_idx]（多机器人 = 多条 robot 行）\n");
    for (const RobotSpawn& rs : state.robots) {
        std::fprintf(f, "robot %.4f %.4f %.4f", rs.x, rs.z, glm::degrees(rs.theta));
        if (rs.carriedIdx >= 0) {
            std::fprintf(f, " %d", rs.carriedIdx);
        }
        std::fputc('\n', f);
    }
    for (const Obstacle& ob : state.obstacles) {
        std::fprintf(f, "box %.4f %.4f %.4f %.4f %.4f %.4f %.3f %.3f %.3f %.2f %.4f\n",
                     ob.center.x, ob.center.y, ob.center.z,
                     ob.half.x, ob.half.y, ob.half.z,
                     ob.color.r, ob.color.g, ob.color.b, ob.mass,
                     glm::degrees(ob.yaw));
    }

    const bool flushed = std::fflush(f) == 0;
    if (!flushed || std::fclose(f) != 0) {
        std::fprintf(stderr, "scene: 写 %s 失败（磁盘满？）\n", tmp.c_str());
        return false;
    }
    // 收窄权限到 0600：地图（与播种出来的那份同源）是用户数据，不该因 fopen 的
    // 缺省 0666&~umask 变成组/他人可读。chmod 失败只影响权限，不阻断保存。
    ::chmod(tmp.c_str(), 0600);
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        std::fprintf(stderr, "scene: rename %s -> %s 失败\n", tmp.c_str(), path.c_str());
        return false;
    }
    return true;
}
