#include "world.h"

#include <algorithm>
#include <cmath>

#include "obb2d.h"
#include "sim_config.h"

namespace {

// 放置解算用常量：贴合判定留的缝隙、迭代放宽重推的最大轮数、单次放置允许累计
// 推出的总距离上限（防「深嵌 / 多堵墙连环顶」把箱子推到离机器人很远甚至身后——
// 超限视为几何不可行，place() 直接失败而不是硬塞一个离谱的结果）。
constexpr float kPlaceEps = 1e-3f;
constexpr int kMaxPlaceIter = 8;
constexpr float kMaxPlacePush = 3.0f;

// 「墙」判定：待放盒从释放高度 releaseBottom 下落到脚下高度 supportTop 附近，途中若
// oth 伸进这条竖直带（bottom < releaseBottom）又不是可踩的「地板」（top > supportTop），
// 放下去就会嵌进去 → 是墙，需要水平推开。顶面不高于脚下的箱是支撑、不推。
bool wallVerticalConflict(const Obstacle& oth, float releaseBottom, float supportTop) {
    return (oth.center.y + oth.half.y) > supportTop && (oth.center.y - oth.half.y) < releaseBottom;
}

// 沿 -f 把待放盒推到与墙 oth 沿 f 严格分离所需的近侧推出量。f 是待放盒的局部
// +X（place 里 ob.yaw=robot.theta()），故是 SAT 候选轴：沿 f 分开即证明两盒不相交、
// 且推的方向天然落在近侧。s = 待放盒心相对墙心在 f 上的投影（s<0 表示在近侧），
// d = s + R + kPlaceEps。注意不是 R-|s|——释放点已越过墙心（s>0）时那样会欠推。
// d<=0 表示无需推。
float nearSidePush(const Obstacle& ob, const Obstacle& oth, float fx, float fz) {
    const float s = (ob.center.x - oth.center.x) * fx + (ob.center.z - oth.center.z) * fz;
    return s + Obb2D::projRadius(ob, fx, fz) + Obb2D::projRadius(oth, fx, fz) + kPlaceEps;
}

// 两盒是否真正 3D 重叠：竖直区间相交 + XZ 投影重叠。place() 写回前用它做最终
// 校验——不信任「墙/支撑」的预分类（那是基于释放高度的启发式），直接按放置后
// 的最终位姿判一次事实，兜底仍不收敛时能被这里拦下而不是悄悄放行。
bool overlaps3D(const Obstacle& a, const Obstacle& b) {
    const bool vOverlap = (a.center.y - a.half.y) < (b.center.y + b.half.y) &&
                          (b.center.y - b.half.y) < (a.center.y + a.half.y);
    return vOverlap && Obb2D::overlapXZ(a, b);
}

}  // namespace

std::vector<Obstacle> World::defaultScene() {
    // 与 sim/scenes/default.scene **逐字段同值**：那份是有场景文件时的正常路径，
    // 这里是无文件时的内置回落；两条路必须给出同一个世界，否则「跑没跑场景文件」
    // 会静默变成一次行为分叉。质量是每箱手调的，不统一用 体积×kDefaultDensity：
    // 800kg/m³ 会把最轻的红箱算成 409.6kg，按 Robot::kLoadSlowdownPerKg 搬起来
    // 基本推不动。两边十个字段由 scripts/check_sim_contract.py 零编译比对。
    std::vector<Obstacle> obs = {
        {{2.0f, 0.40f, 1.2f}, {0.40f, 0.40f, 0.40f}, {0.72f, 0.30f, 0.24f}, 61.44f},    // 前进左前方的红箱
        {{3.5f, 0.50f, -0.6f}, {0.20f, 0.50f, 1.20f}, {0.45f, 0.52f, 0.60f}, 192.00f},  // 横在右前的矮墙
        {{1.2f, 0.25f, -1.6f}, {0.50f, 0.25f, 0.50f}, {0.80f, 0.66f, 0.25f}, 100.00f},  // 右侧的黄块
        {{4.5f, 0.75f, 1.8f}, {0.25f, 0.75f, 0.25f}, {0.30f, 0.55f, 0.35f}, 75.00f},    // 远处的绿柱
        {{0.6f, 0.30f, 2.2f}, {0.30f, 0.30f, 0.30f}, {0.55f, 0.42f, 0.60f}, 69.12f},    // 左后的紫箱
        {{6.0f, 0.35f, 0.8f}, {0.35f, 0.35f, 0.35f}, {0.85f, 0.45f, 0.20f}, 137.20f},   // 第二排橙箱
        {{7.5f, 0.60f, -1.0f}, {0.20f, 0.60f, 0.80f}, {0.30f, 0.40f, 0.65f}, 153.60f},  // 深处蓝墙
        {{5.5f, 0.25f, -2.2f}, {0.45f, 0.25f, 0.45f}, {0.25f, 0.60f, 0.55f}, 101.25f},  // 右深的青块
        {{8.5f, 0.40f, 1.5f}, {0.40f, 0.40f, 0.40f}, {0.65f, 0.30f, 0.50f}, 61.44f},    // 远处品红箱
        {{6.8f, 0.30f, 2.8f}, {0.30f, 0.30f, 0.30f}, {0.55f, 0.65f, 0.25f}, 69.12f},    // 左深的绿黄箱
        {{9.5f, 0.50f, -0.2f}, {0.25f, 0.50f, 0.25f}, {0.75f, 0.75f, 0.72f}, 60.00f},   // 尽头白柱
    };
    return obs;
}

World::World(std::vector<Obstacle> obstacles) : obstacles_(std::move(obstacles)) {}

void World::resolveCollisions(Robot& robot) {
    const float footY = robot.y() + Robot::kGroundSnapTol;
    for (int i = 0; i < (int)obstacles_.size(); ++i) {
        if (i == robot.carriedIndex()) continue;  // 该机器人搬运物附着在身上，不参与碰撞
        // 高度感知：顶面不高于脚下的障碍是「地板」（能站上去/跳过去），不推；
        // 只有比脚高的「墙」才把机器人推出 XZ。跳够高越过矮箱即源于此。
        if (obstacles_[i].center.y + obstacles_[i].half.y <= footY) continue;
        float rx = robot.x(), rz = robot.z();
        if (Obb2D::resolveSphere(rx, rz, SimConfig::kRobotRadius, obstacles_[i])) {
            robot.setX(rx);
            robot.setZ(rz);
        }
    }
}

float World::supportHeight(const Robot& robot) const {
    float support = 0.0f;  // 缺省地面
    const float footY = robot.y() + Robot::kGroundSnapTol;
    const int carried = robot.carriedIndex();
    const float r2 = SimConfig::kRobotRadius * SimConfig::kRobotRadius;
    for (int i = 0; i < (int)obstacles_.size(); ++i) {
        if (i == carried) continue;  // 背着的箱子不能踩
        const Obstacle& ob = obstacles_[i];
        const float top = ob.center.y + ob.half.y;
        if (top > footY) continue;  // 比脚高的是墙，不是可站的地板
        // 脚下 XZ 圆与盒截面是否重叠（与碰撞同用最近点判定，见 Obb2D::distanceSqXZ）
        if (Obb2D::distanceSqXZ(ob, robot.x(), robot.z()) <= r2 && top > support) {
            support = top;
        }
    }
    return support;
}


float World::queryRange(const Robot& robot, float maxRange) const {
    float forwardX, forwardZ;
    Obb2D::forwardOf(robot.theta(), forwardX, forwardZ);
    // 射线从身体前端、身体中心高度水平发出。高度不随俯仰变化（仿真器没有俯仰）。
    const float ox = robot.x() + forwardX * (Robot::kBodyLength * 0.5f);
    const float oz = robot.z() + forwardZ * (Robot::kBodyLength * 0.5f);
    const float rayY = robot.y() + Robot::kBodyY + Robot::kBodyHeight * 0.5f;
    // 与碰撞同一条「地板」线：顶面不高于脚下的障碍射线从上方穿过，不当墙。
    const float footY = robot.y() + Robot::kGroundSnapTol;

    float nearest = maxRange;
    for (int i = 0; i < (int)obstacles_.size(); ++i) {
        if (i == robot.carriedIndex()) continue;  // 跳过该机器人搬运的物体
        const Obstacle& ob = obstacles_[i];
        if (ob.center.y + ob.half.y <= footY) continue;  // 脚下的地板
        float t;
        if (Obb2D::rayHitAtHeight(ox, oz, forwardX, forwardZ, rayY, ob, t) && t < nearest) {
            nearest = t;
        }
    }
    return nearest;
}

int World::settleUnsupported(const std::vector<int>& carriedIdxs) {
    auto carried = [&](int idx) {
        return std::find(carriedIdxs.begin(), carriedIdxs.end(), idx) != carriedIdxs.end();
    };
    // 先按**本轮开始时**的几何决定谁落、落到哪，再一起写回。同轮里先处理的
    // 下层不能立刻变成上层的新支撑——否则结果依赖遍历顺序（下层下标更小就
    // 一层落完、更大就留下悬空）。一层落稳后由调用方再调一轮。
    struct Drop {
        int idx;
        float y;
    };
    std::vector<Drop> drops;
    for (int i = 0; i < (int)obstacles_.size(); ++i) {
        if (carried(i)) continue;  // 背着的箱子跟着机体，不参与落体
        const Obstacle& ob = obstacles_[i];
        const float bottom = ob.center.y - ob.half.y;
        // 已经贴地（含浮点噪声）的不处理。贴地判定用 kGroundSnapTol，与「地板」同容差。
        if (bottom <= Robot::kGroundSnapTol) continue;

        float support = 0.0f;  // 缺省地面
        bool found = false;
        for (int j = 0; j < (int)obstacles_.size(); ++j) {
            if (j == i || carried(j)) continue;
            const Obstacle& oth = obstacles_[j];
            const float top = oth.center.y + oth.half.y;
            // 支撑必须在自己底面之下（含贴合容差）。顶面高于自己底面的是穿插或
            // 旁边的墙，不能当落点——否则会把已经叠好的箱子再往上抬。
            if (top > bottom + Robot::kGroundSnapTol) continue;
            if (!Obb2D::overlapXZ(ob, oth)) continue;
            if (!found || top > support) {
                support = top;
                found = true;
            }
        }
        // 贴着当前支撑面（另一箱顶或地面）就不落。悬空量必须大于容差，避免
        // 每帧把「刚好叠上」的箱子来回抖动。
        if (bottom <= support + Robot::kGroundSnapTol) continue;
        drops.push_back({i, support + ob.half.y});
    }
    for (const Drop& d : drops) {
        obstacles_[d.idx].center.y = d.y;
    }
    return static_cast<int>(drops.size());
}

bool World::isObstacleCovered(int idx) const {
    const Obstacle& base = obstacles_[idx];
    const float top = base.center.y + base.half.y;
    for (int i = 0; i < (int)obstacles_.size(); ++i) {
        if (i == idx) continue;
        const Obstacle& other = obstacles_[i];
        const float bottom = other.center.y - other.half.y;
        // 贴合判定：other 的底面落在 base 顶面的 kGroundSnapTol 容差带内，
        // 且两者 XZ 有重叠——即 other 搭在 base 上面（哪怕只搭一个边角，
        // 偏保守：宁可多拒绝拾取，也不悄悄抽掉下层留个悬空的上层）。
        if (std::abs(bottom - top) <= Robot::kGroundSnapTol && Obb2D::overlapXZ(base, other)) {
            return true;
        }
    }
    return false;
}

bool World::pick(Robot& robot) {
    if (robot.isCarrying()) {
        return false;  // 该机器人已搬运
    }

    float forwardX, forwardZ;
    Obb2D::forwardOf(robot.theta(), forwardX, forwardZ);
    const float ox = robot.x() + forwardX * (Robot::kBodyLength * 0.5f);
    const float oz = robot.z() + forwardZ * (Robot::kBodyLength * 0.5f);

    // 找前方最近的、在拾取半径内的障碍物
    int bestIdx = -1;
    float bestDist = kPickRange;
    for (int i = 0; i < (int)obstacles_.size(); ++i) {
        const auto& ob = obstacles_[i];
        // 机器人前端到 OBB 表面最近点的距离（解算见 Obb2D::distanceSqXZ）
        const float dist = std::sqrt(Obb2D::distanceSqXZ(ob, ox, oz));
        if (dist < bestDist) {
            // 还要判断在前方（点积 > 0）
            const float toCenterX = ob.center.x - ox;
            const float toCenterZ = ob.center.z - oz;
            const float dot = toCenterX * forwardX + toCenterZ * forwardZ;
            if (dot > 0.0f) {
                bestDist = dist;
                bestIdx = i;
            }
        }
    }

    if (bestIdx >= 0) {
        if (isObstacleCovered(bestIdx)) {
            return false;  // 上面贴着别的箱子，抽不出来
        }
        robot.setCarried(bestIdx, obstacles_[bestIdx].mass);
        return true;
    }
    return false;
}

bool World::place(Robot& robot, PlaceFail* why) {
    const int idx = robot.carriedIndex();
    if (idx < 0 || idx >= (int)obstacles_.size()) {
        if (why) *why = PlaceFail::NotCarrying;
        return false;
    }

    // 在局部副本上做几何解算，只有最终校验通过才写回 obstacles_[idx]：
    // 几何不可行（兜底仍重叠、或推出距离超限）时宁可响亮失败、物体留在搬运态，
    // 也不要硬塞一个可能与别的箱子重叠的结果（与本仓「宁可报错不给假数据」同口径）。
    Obstacle candidate = obstacles_[idx];

    // f = 机器人前方，也恰是待放盒的局部 +X（下面 candidate.yaw=robot.theta()），
    // 故是 SAT 候选轴。
    float fx, fz;
    Obb2D::forwardOf(robot.theta(), fx, fz);
    // 松手瞬间背着的物体底面所在高度。用机器人姿态推算，而不是读 candidate.center.y——
    // pick 与 place 可能落在同一帧的事件批里，那时 updateCarried 还没跑过。
    const float releaseBottom = robot.y() + Robot::kBodyY + Robot::kBodyHeight + kCarryLift;
    // 「地板高度」＝机器人脚下（与 resolveCollisions/supportHeight 同口径）：顶面不高于
    // 此高度的箱是它踩得上的支撑面、可叠放；高于此高度的箱相对它是「墙」、要推开。
    // 「一律落地 + 推开、只在机器人自己抬高（站上箱顶）时叠放」就落在这条线上。
    const float supportTop = robot.y() + Robot::kGroundSnapTol;

    // 先定 XZ 与朝向（y 留到 Phase B 按最终脚印的支撑面算）
    candidate.center.x = robot.x() + fx * (Robot::kBodyLength * 0.5f + kPlaceDist);
    candidate.center.z = robot.z() + fz * (Robot::kBodyLength * 0.5f + kPlaceDist);
    candidate.yaw = robot.theta();

    // Phase A：把待放盒从「墙」（竖直冲突且 XZ 重叠的箱）里沿 -f 水平推开，只往机器人
    // 这一侧推、绝不穿到阻挡箱对面。每轮取最严格的一堵墙推，最多 kMaxPlaceIter 轮。
    // 墙集合只依赖 releaseBottom/supportTop（常量），不依赖落地高度，故无「推↔落地」震荡。
    // 累计推出量超过 kMaxPlacePush 视为不可行（如被巨大/多堵墙连环顶），提前放弃。
    bool resolved = false;
    bool pushExceeded = false;
    float totalPush = 0.0f;
    for (int iter = 0; iter < kMaxPlaceIter; ++iter) {
        float push = 0.0f;
        for (int i = 0; i < (int)obstacles_.size(); ++i) {
            if (i == idx) continue;
            const Obstacle& oth = obstacles_[i];
            if (!wallVerticalConflict(oth, releaseBottom, supportTop)) continue;
            if (!Obb2D::overlapXZ(candidate, oth)) continue;
            push = std::max(push, nearSidePush(candidate, oth, fx, fz));
        }
        if (push <= 0.0f) {
            resolved = true;
            break;
        }
        totalPush += push;
        if (totalPush > kMaxPlacePush) {
            pushExceeded = true;
            break;
        }
        candidate.center.x -= fx * push;
        candidate.center.z -= fz * push;
    }
    if (!resolved && !pushExceeded) {
        // 兜底：迭代未收敛（如两侧都堆着墙）时去掉 overlap 过滤，对全部竖直冲突的墙取
        // 最严格者再推一次，尽量保证不嵌墙；同样受累计推出上限约束。
        float push = 0.0f;
        for (int i = 0; i < (int)obstacles_.size(); ++i) {
            if (i == idx) continue;
            const Obstacle& oth = obstacles_[i];
            if (!wallVerticalConflict(oth, releaseBottom, supportTop)) continue;
            push = std::max(push, nearSidePush(candidate, oth, fx, fz));
        }
        if (push > 0.0f) {
            totalPush += push;
            if (totalPush > kMaxPlacePush) {
                pushExceeded = true;
            } else {
                candidate.center.x -= fx * push;
                candidate.center.z -= fz * push;
            }
        }
    }
    if (pushExceeded) {
        if (why) *why = PlaceFail::PushExceeded;
        return false;  // 推出距离超限：几何不可行，放弃本次放置（物体仍背着）
    }

    // Phase B：按最终脚印（XZ+yaw）定落地高度——取所有「顶面不高于脚下且脚印重叠」的箱
    // 里最高的顶面作支撑面，没有则落地 0。机器人自己站上箱顶再松手就落在这层箱顶，即叠放。
    float bottom = 0.0f;
    for (int i = 0; i < (int)obstacles_.size(); ++i) {
        if (i == idx) continue;
        const Obstacle& oth = obstacles_[i];
        const float top = oth.center.y + oth.half.y;
        if (top > supportTop) continue;  // 比脚下高的是墙（Phase A 已处理），不是支撑
        if (!Obb2D::overlapXZ(candidate, oth)) continue;
        if (top > bottom) bottom = top;
    }
    candidate.center.y = bottom + candidate.half.y;

    // 最终校验：不信任上面基于释放高度的「墙/支撑」启发式分类，直接按放置后的
    // 最终位姿对全部障碍做一次事实性 3D 重叠检查。兜底仍未收敛的罕见情形会在
    // 这里被拦下，而不是悄悄放行一个重叠结果。
    for (int i = 0; i < (int)obstacles_.size(); ++i) {
        if (i == idx) continue;
        if (overlaps3D(candidate, obstacles_[i])) {
            if (why) *why = PlaceFail::Overlap;
            return false;  // 兜底仍无法消除重叠：几何不可行，放弃本次放置
        }
    }

    obstacles_[idx] = candidate;
    robot.clearCarried();
    return true;
}

void World::updateCarried(const Robot& robot) {
    const int idx = robot.carriedIndex();
    if (idx < 0 || idx >= (int)obstacles_.size()) {
        return;
    }
    auto& ob = obstacles_[idx];
    // 放在机器人正上方，抬高避免挡住摄像机；y 跟随机器人离地高度（跳起/站箱上时
    // 背着的箱子一起升，否则会相对机体下沉）。
    ob.center.x = robot.x();
    ob.center.z = robot.z();
    ob.center.y = robot.y() + Robot::kBodyY + Robot::kBodyHeight + ob.half.y + kCarryLift;
    // 朝向跟随机体：机器人转向时背着的箱子一起转（可见 + 放置后保留）。
    ob.yaw = robot.theta();
}

void World::applyScene(const SceneState& scene) {
    obstacles_ = scene.obstacles;
}
