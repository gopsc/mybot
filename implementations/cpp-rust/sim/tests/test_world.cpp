// World：射线测距、碰撞推出、拾取/放置/叠放、朝向盒（OBB）几何与 place 的
// 几何不可行路径。搬运态属于每只 Robot，World 无状态地服务 N 只。
// 拆分约定与共享工具（断言记账、socket 客户端助手）见 harness.h；套件名册见
// suites.h。本文件的用例正文自拆分前的单文件 sim/tests/main.cpp 逐字搬迁
// （2026-10-04，第三轮重构 Phase 21），未改断言、未改用例数。

#include <cmath>
#include <vector>

#include <glm/glm.hpp>

#include "harness.h"
#include "obb2d.h"
#include "robot.h"
#include "suites.h"
#include "world.h"

namespace SimTests {

// ---- World：射线测距 ----

std::vector<Obstacle> oneBox(float cx, float cz, float mass = 1.0f) {
    return {{{cx, 0.4f, cz}, {0.4f, 0.4f, 0.4f}, {1.0f, 1.0f, 1.0f}, mass}};
}

void testQueryRange() {
    Robot r;  // 原点 theta=0，射线起点 x=+0.2（半车长）
    // 盒中心 3.0 半宽 0.4 → 近面 2.6 → 命中距离 2.6-0.2 = 2.4
    World w(oneBox(3.0f, 0.0f));
    check(near(w.queryRange(r), 2.4f, 1e-3f), "正前方命中距离 = 2.4m");

    World empty(std::vector<Obstacle>{});
    check(near(empty.queryRange(r), Robot::kRangeMax, 1e-6f), "无障碍返回 maxRange");

    // 障碍在身后：射线反向无命中
    World behind(oneBox(-3.0f, 0.0f));
    check(near(behind.queryRange(r), Robot::kRangeMax, 1e-6f), "身后障碍不计入");

    // 转向后测侧方：theta=+90°（朝 -Z）时命中 -Z 方向的盒
    Robot side;
    side.setRelativeTurn(glm::radians(90.0f));
    RobotInput in;
    int guard = 0;
    while (side.tickRelative(1.0f / 60.0f, in) && guard++ < 600) {
        side.update(1.0f / 60.0f, in, Robot::kMaxSpeed);
    }
    World sideBox(oneBox(side.x(), -3.0f));
    check(near(sideBox.queryRange(side), 2.4f, 0.15f), "转 90° 后命中侧方障碍");

    // 高度感知：射线在身体中心高度（y=0 时约 0.33m）。矮箱顶面 0.10 < 射线，
    // 从上方穿过去，不当墙；同位置的高墙顶面 0.8、底面 0 挡住射线。
    World low(std::vector<Obstacle>{
        {{3.0f, 0.05f, 0.0f}, {0.4f, 0.05f, 0.4f}, {1, 1, 1}, 1.0f},
    });
    check(near(low.queryRange(r), Robot::kRangeMax, 1e-6f), "矮于射线的箱子不当墙");
    World tall(std::vector<Obstacle>{
        {{3.0f, 0.4f, 0.0f}, {0.4f, 0.4f, 0.4f}, {1, 1, 1}, 1.0f},
    });
    check(near(tall.queryRange(r), 2.4f, 1e-3f), "高过射线的墙仍命中近面");

    // 站上箱顶（y=0.8）后，脚下这块箱子的近面不再被当成前方障碍；更远处、
    // 顶面高于脚下的墙才计入。射线高度 = 0.8+0.26+0.07 = 1.13，墙必须够到它。
    Robot atop;
    atop.applySupport(0.8f);
    World onBox(std::vector<Obstacle>{
        {{0.0f, 0.4f, 0.0f}, {0.5f, 0.4f, 0.5f}, {1, 1, 1}, 1.0f},     // 脚下，顶面 0.8
        {{3.0f, 1.2f, 0.0f}, {0.4f, 0.5f, 0.4f}, {1, 1, 1}, 1.0f},     // 墙：底 0.7 顶 1.7
    });
    check(near(onBox.queryRange(atop), 2.4f, 1e-3f), "站箱上测距穿过脚下、命中前方墙");
    World onlyFloor(std::vector<Obstacle>{
        {{0.0f, 0.4f, 0.0f}, {0.5f, 0.4f, 0.5f}, {1, 1, 1}, 1.0f},
    });
    check(near(onlyFloor.queryRange(atop), Robot::kRangeMax, 1e-6f),
          "站箱上前方没有墙时返回 maxRange");
}

// ---- World：碰撞 ----

void testCollisions() {
    // 朝盒推进：解算把车推出盒面，车心进不到「近面 - 碰撞半径」以内
    World w(oneBox(2.0f, 0.0f));  // 盒近面 x=1.6
    Robot r;
    for (int i = 0; i < 300; ++i) {
        r.update(1.0f / 60.0f, {1.0f, 0.0f}, Robot::kMaxSpeed);
        w.resolveCollisions(r);
    }
    check(r.x() <= 1.401f, "碰撞把车挡在盒面外（1.6-0.2）");
    check(r.x() > 1.2f, "车确实贴到了盒面");
}

// ---- World：搬运 ----

void testPickPlace() {
    World world(std::vector<Obstacle>{
        {{0.7f, 0.2f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1.0f, 1.0f, 1.0f}, 5.0f},  // 前方近面 0.5
        {{2.0f, 0.2f, 3.0f}, {0.2f, 0.2f, 0.2f}, {1.0f, 1.0f, 1.0f}, 1.0f},  // 远处侧方
    });
    Robot r;
    check(!r.isCarrying(), "初始未搬运");

    // 前端在 0.2、近面在 0.5 → 距离 0.3 < 0.6，可拾取
    check(world.pick(r), "前方 0.3m 的盒可拾取");
    check(r.isCarrying(), "拾取后 isCarrying");
    check(r.carriedIndex() == 0, "拾取的是最近的 idx=0");
    check(near(r.carriedMass(), 5.0f, 1e-6f), "carriedMass = 障碍质量");
    check(r.effectiveMaxSpeed() < Robot::kMaxSpeed, "搬运时最大速度被压低");

    check(!world.pick(r), "已持有物体时再 pick 失败");
    check(near(world.queryRange(r), Robot::kRangeMax, 1e-6f), "被搬运物体不参与测距");

    // 被搬运物体跟随机器人：updateCarried 把它钉在机体正上方
    for (int i = 0; i < 60; ++i) {
        r.update(1.0f / 60.0f, {0.5f, 0.0f}, r.effectiveMaxSpeed());
    }
    world.updateCarried(r);
    check(r.x() > 0.1f, "搬运中机器人仍可前进（减速但不清零）");
    check(near(world.obstacles()[0].center.x, r.x(), 1e-6f), "搬运中物体 x 钉在机体正上方");
    check(world.obstacles()[0].center.y > Robot::kBodyY, "搬运中物体抬到身体上方");

    // place：放到身体前端 + kPlaceDist（0.2+0.5=0.7）
    const float px = r.x();
    check(world.obstacles()[0].center.y > Robot::kBodyY, "搬运中物体被抬高（place 前）");
    check(world.place(r), "place 成功");
    check(!r.isCarrying(), "place 后未搬运");
    check(near(world.obstacles()[0].center.x, px + 0.2f + 0.5f, 1e-3f),
          "物体落在前方 placeDist 处");
    check(near(world.obstacles()[0].center.y, world.obstacles()[0].half.y, 1e-3f),
          "place 后物体落回地面（center.y=half.y，不悬空）");
    // why 先填一个**错的**取值：若 place 忘了写它，下面这条会红，不会假绿。
    World::PlaceFail why = World::PlaceFail::Overlap;
    check(!world.place(r, &why), "未持有物体时 place 失败");
    check(why == World::PlaceFail::NotCarrying, "失败原因报「未持有物体」");

    // 拾不到的两种情形：太远 / 在身后
    Robot far;
    World farWorld(oneBox(2.0f, 0.0f));
    World behindWorld(oneBox(-1.0f, 0.0f));
    check(!farWorld.pick(far), "前方 1.8m 的盒拾取失败（超出 0.6m）");
    check(!behindWorld.pick(far), "身后的盒拾取失败");
}

// ---- World：朝向盒（OBB）几何 ----

void testYawGeometry() {
    // 细长盒：局部 X 半长 0.1、局部 Z 半长 0.6。yaw=0 时薄边朝前（在 +X 上，
    // 近面 x=1.9），yaw=90° 时把长边转到 +X 上（近面 x=1.4）。
    const glm::vec3 c{2.0f, 0.2f, 0.0f};
    const glm::vec3 h{0.1f, 0.2f, 0.6f};
    Robot r;  // 原点 theta=0，射线/前端起点 x=+0.2

    // 测距：yaw=0 薄边正对 → 命中 1.9-0.2=1.7；yaw=90° 长边正对 → 命中 1.4-0.2=1.2
    World flat(std::vector<Obstacle>{{c, h, {1, 1, 1}, 1.0f, 0.0f}});
    check(near(flat.queryRange(r), 1.7f, 1e-3f), "yaw=0 测距命中薄边近面");
    World turned(std::vector<Obstacle>{{c, h, {1, 1, 1}, 1.0f, glm::radians(90.0f)}});
    check(near(turned.queryRange(r), 1.2f, 1e-3f), "yaw=90° 测距命中长边近面");

    // 碰撞：同上，yaw=90° 时碰撞面更近（车被挡在 x≈1.2 而非 1.7）
    Robot cf;
    for (int i = 0; i < 300; ++i) {
        cf.update(1.0f / 60.0f, {1.0f, 0.0f}, Robot::kMaxSpeed);
        flat.resolveCollisions(cf);
    }
    check(cf.x() > 1.6f && cf.x() <= 1.701f, "yaw=0 车贴到薄边近面");
    Robot ct;
    for (int i = 0; i < 300; ++i) {
        ct.update(1.0f / 60.0f, {1.0f, 0.0f}, Robot::kMaxSpeed);
        turned.resolveCollisions(ct);
    }
    check(ct.x() <= 1.201f, "yaw=90° 车被挡在更近的长边近面");

    // 拾取：同样细长盒放在中心 1.0 处。yaw=0 薄边正对 → 近面 x=0.9，距前端 0.7 > 0.6
    // 拾不到；yaw=90° 长边正对 → 近面 x=0.4，距前端 0.2 < 0.6 可拾。
    World pickFlat(std::vector<Obstacle>{{{1.0f, 0.2f, 0.0f}, {0.1f, 0.2f, 0.6f}, {1, 1, 1}, 1.0f, 0.0f}});
    Robot pf;
    check(!pickFlat.pick(pf), "yaw=0 细长盒横放够不到（距前端 0.7 > 0.6）");
    World pickTurned(std::vector<Obstacle>{{{1.0f, 0.2f, 0.0f}, {0.1f, 0.2f, 0.6f}, {1, 1, 1}, 1.0f, glm::radians(90.0f)}});
    Robot pt;
    check(pickTurned.pick(pt), "yaw=90° 细长盒转正后可拾取（距前端 0.2 < 0.6）");
    check(pt.carriedIndex() == 0, "yaw=90° 拾取到该盒");
}

// ---- World：搬运物朝向跟随机体 + 放置保留朝向 ----

void testYawCarry() {
    World world(std::vector<Obstacle>{
        {{0.7f, 0.2f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 5.0f, 0.0f},
    });
    Robot r;
    check(world.pick(r), "朝向用例：拾取成功");

    // 转身 90°
    r.setRelativeTurn(glm::radians(90.0f));
    RobotInput in;
    int guard = 0;
    while (r.tickRelative(1.0f / 60.0f, in) && guard++ < 600) {
        r.update(1.0f / 60.0f, in, r.effectiveMaxSpeed());
    }
    check(near(r.theta(), glm::radians(90.0f), glm::radians(1.5f)), "朝向用例：转向 90° 完成");

    world.updateCarried(r);
    check(near(world.obstacles()[0].yaw, r.theta(), 1e-6f), "updateCarried 让搬运物 yaw 跟随机体朝向");

    check(world.place(r), "朝向用例：放置成功");
    check(near(world.obstacles()[0].yaw, r.theta(), 1e-6f), "place 后保留放置瞬间的朝向");
}

// ---- Obb2D：盒-盒 OBB 重叠（2D SAT） ----

void testObbOverlap() {
    // 两个轴对齐方盒：中心距 0.5 < 半宽和 0.8 → 重叠
    const Obstacle a{{0.0f, 0.2f, 0.0f}, {0.4f, 0.2f, 0.4f}, {1, 1, 1}, 1.0f, 0.0f};
    const Obstacle bFar{{0.9f, 0.2f, 0.0f}, {0.4f, 0.2f, 0.4f}, {1, 1, 1}, 1.0f, 0.0f};
    const Obstacle bHit{{0.5f, 0.2f, 0.0f}, {0.4f, 0.2f, 0.4f}, {1, 1, 1}, 1.0f, 0.0f};
    const Obstacle bTouch{{0.8f, 0.2f, 0.0f}, {0.4f, 0.2f, 0.4f}, {1, 1, 1}, 1.0f, 0.0f};
    check(Obb2D::overlapXZ(a, bHit), "轴对齐：相交 → 重叠");
    check(!Obb2D::overlapXZ(a, bTouch), "轴对齐：恰好贴合（距离=半径和）→ 不算重叠");
    check(!Obb2D::overlapXZ(a, bFar), "轴对齐：分离 → 不重叠");

    // 45° 斜置判别：两盒的**轴对齐包围盒**相交，但 OBB 实际分离（SAT 能分辨）
    const Obstacle sqA{{0.0f, 0.2f, 0.0f}, {0.1f, 0.15f, 0.1f}, {1, 1, 1}, 1.0f, 0.0f};
    const Obstacle sqB{{0.2f, 0.2f, -0.2f}, {0.1f, 0.15f, 0.1f}, {1, 1, 1}, 1.0f,
                       glm::radians(45.0f)};
    check(!Obb2D::overlapXZ(sqA, sqB), "45° 斜置：AABB 相交但 OBB 实际分离");

    // 同两盒改成 0° 摆放：中心距 0.2 < 半径和 0.2？——相等即贴合，不算重叠
    const Obstacle sqB0{{0.2f, 0.2f, -0.2f}, {0.1f, 0.15f, 0.1f}, {1, 1, 1}, 1.0f, 0.0f};
    check(!Obb2D::overlapXZ(sqA, sqB0), "轴对齐 0°：投影恰好贴合不算重叠");
    const Obstacle sqB0in{{0.15f, 0.2f, -0.15f}, {0.1f, 0.15f, 0.1f}, {1, 1, 1}, 1.0f, 0.0f};
    check(Obb2D::overlapXZ(sqA, sqB0in), "轴对齐 0°：投影相交 → 重叠");
}

// ---- World：place 放置解算（水平推开 + 落地/叠放） ----

// 不变量：world 中任意竖直相交的盒对，必须 XZ 不重叠（place 后应成立）。
void checkNoOverlapPairs(const World& w) {
    for (int i = 0; i < (int)w.obstacles().size(); ++i) {
        for (int j = i + 1; j < (int)w.obstacles().size(); ++j) {
            const Obstacle& a = w.obstacles()[i];
            const Obstacle& b = w.obstacles()[j];
            const bool vOverlap = (a.center.y - a.half.y) < (b.center.y + b.half.y) &&
                                  (b.center.y - b.half.y) < (a.center.y + a.half.y);
            if (vOverlap) {
                check(!Obb2D::overlapXZ(a, b), "不变量：竖直相交的盒对 XZ 不重叠");
            }
        }
    }
}

void testPlaceResolve() {
    // 空地对齐（旧行为回归）：无其他箱 → 精确落在前方 0.7、贴地 center.y=half.y
    {
        World world(std::vector<Obstacle>{
            {{5.0f, 0.2f, 5.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},  // idx0 被搬盒
        });
        Robot r;  // 原点 theta=0 → 前方 +X
        r.setCarried(0, 1.0f);
        check(world.place(r), "空地对齐：place 成功");
        const Obstacle& ob = world.obstacles()[0];
        check(near(ob.center.x, 0.7f, 1e-6f), "空地对齐：落点 x=0.7（车身半长 0.2 + placeDist 0.5）");
        check(near(ob.center.z, 0.0f, 1e-6f), "空地对齐：落点 z=0");
        check(near(ob.center.y, 0.2f, 1e-6f), "空地对齐：center.y=half.y 精确落地");
    }

    // 落点被「墙」占住（顶面 0.4 高于脚下）→ 沿机器人前方近侧推开
    {
        World world(std::vector<Obstacle>{
            {{5.0f, 0.2f, 5.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},  // idx0 被搬盒
            {{0.7f, 0.2f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},  // idx1 挡在落点上
        });
        Robot r;
        r.setCarried(0, 1.0f);
        check(world.place(r), "占位推出：place 成功");
        const Obstacle& ob = world.obstacles()[0];
        const Obstacle& wall = world.obstacles()[1];
        check(ob.center.x < wall.center.x, "占位推出：只往机器人近侧推（不穿到阻挡箱对面）");
        check(near(ob.center.x, 0.3f, 2e-3f), "占位推出：贴合（0.7 − 半径和 0.4 − eps）");
        check(!Obb2D::overlapXZ(ob, wall), "占位推出：推后两盒不重叠");
        check(near(ob.center.y, 0.2f, 1e-6f), "占位推出：仍落地（下方无支撑）");
        checkNoOverlapPairs(world);
    }

    // 深嵌（释放点已越过阻挡箱中心）→ 仍推回近侧
    {
        World world(std::vector<Obstacle>{
            {{5.0f, 0.2f, 5.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},
            {{0.5f, 0.2f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},  // 阻挡箱更近（s>0）
        });
        Robot r;
        r.setCarried(0, 1.0f);
        check(world.place(r), "深嵌：place 成功");
        const Obstacle& ob = world.obstacles()[0];
        const Obstacle& wall = world.obstacles()[1];
        check(ob.center.x < wall.center.x, "深嵌：仍推回近侧");
        check(!Obb2D::overlapXZ(ob, wall), "深嵌：推后不重叠");
        checkNoOverlapPairs(world);
    }
}

// ---- World：place 几何不可行时响亮失败（推出超限 / 兜底仍重叠），不留假结果 ----

void testPlaceInfeasible() {
    // 巨大的墙贴在落点上：单轮 nearSidePush 就远超 kMaxPlacePush(3m)——
    // 几何上"推得开"但代价离谱，应判不可行而失败，而不是真把箱子推出几米远。
    {
        World world(std::vector<Obstacle>{
            {{5.0f, 0.2f, 5.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},     // idx0 被搬盒
            {{0.7f, 0.2f, 0.0f}, {10.0f, 0.2f, 10.0f}, {1, 1, 1}, 1.0f},  // idx1 巨墙，正挡在落点上
        });
        Robot r;
        r.setCarried(0, 1.0f);
        const Obstacle before = world.obstacles()[0];
        World::PlaceFail why = World::PlaceFail::NotCarrying;
        check(!world.place(r, &why), "巨墙挡路：推出距离超限，place 失败");
        check(why == World::PlaceFail::PushExceeded, "巨墙挡路：失败原因报推出超限");
        check(r.isCarrying(), "place 失败后物体仍背着");
        check(r.carriedIndex() == 0, "place 失败后仍是原来那个物体");
        const Obstacle& after = world.obstacles()[0];
        check(near(after.center.x, before.center.x, 1e-6f) &&
                  near(after.center.y, before.center.y, 1e-6f) &&
                  near(after.center.z, before.center.z, 1e-6f),
              "place 失败后被搬盒位置未被改动（场景不受污染）");
    }

    // 多堵薄墙沿 -f 链式排列（相邻间距 0.3m < 箱宽0.4+墙宽0.1，清开一道立刻撞进下一道），
    // 12 道逼近/超出 Phase A 的 kMaxPlaceIter=8 轮与兜底的处理能力。不预判算法具体在哪
    // 一轮收敛/放弃，只断言核心安全不变量：成功则真不重叠，失败则物体仍背着、原场景
    // 不受污染——两者都不接受"返回成功但留下重叠"或"返回失败但场景已被改坏"。
    {
        std::vector<Obstacle> obs;
        obs.push_back({{5.0f, 0.2f, 5.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f});  // idx0 被搬盒
        for (int i = 0; i < 12; ++i) {
            const float cx = 0.7f - 0.3f * static_cast<float>(i);
            obs.push_back({{cx, 0.2f, 0.0f}, {0.05f, 0.2f, 5.0f}, {1, 1, 1}, 1.0f});
        }
        World world(obs);
        Robot r;
        r.setCarried(0, 1.0f);
        const Obstacle before = world.obstacles()[0];
        const bool ok = world.place(r);
        if (ok) {
            check(!r.isCarrying(), "连环墙：成功则不再搬运");
            checkNoOverlapPairs(world);
        } else {
            check(r.isCarrying(), "连环墙：失败则物体仍背着");
            const Obstacle& after = world.obstacles()[0];
            check(near(after.center.x, before.center.x, 1e-6f) &&
                      near(after.center.z, before.center.z, 1e-6f),
                  "连环墙：失败后被搬盒位置未被改动");
        }
    }

    // 悬空横梁：底面 0.60 高过释放底面 releaseBottom = kBodyY+kBodyHeight+kCarryLift = 0.50，
    // 按 wallVerticalConflict 的定义它不是「墙」，Phase A 不推它；它顶面 0.80 > supportTop，
    // 也不构成支撑，Phase B 照样把箱子落到地面——落定后箱顶 0.90 撞进横梁的竖直带。这正是
    // 写回前那次事实性 3D 校验存在的理由：启发式的「墙/支撑」二分漏掉的情形要被它拦下。
    {
        World world(std::vector<Obstacle>{
            {{5.0f, 0.45f, 5.0f}, {0.2f, 0.45f, 0.2f}, {1, 1, 1}, 1.0f},  // idx0 被搬盒（高箱）
            {{0.7f, 0.70f, 0.0f}, {0.3f, 0.10f, 0.3f}, {1, 1, 1}, 1.0f},  // idx1 横梁，悬在落点正上方
        });
        Robot r;
        r.setCarried(0, 1.0f);
        const Obstacle before = world.obstacles()[0];
        World::PlaceFail why = World::PlaceFail::NotCarrying;
        check(!world.place(r, &why), "悬空横梁：兜底仍重叠，place 失败");
        check(why == World::PlaceFail::Overlap, "悬空横梁：失败原因报仍重叠");
        check(r.isCarrying(), "重叠失败后物体仍背着");
        const Obstacle& after = world.obstacles()[0];
        check(near(after.center.x, before.center.x, 1e-6f) &&
                  near(after.center.y, before.center.y, 1e-6f) &&
                  near(after.center.z, before.center.z, 1e-6f),
              "重叠失败后被搬盒位置未被改动（场景不受污染）");
    }
}

// ---- World：叠放（机器人站上箱顶松手，物体落在下层箱顶） ----

void testStacking() {
    // 地面大板（顶面 0.4）供机器人站上去；被搬盒 idx1
    World world(std::vector<Obstacle>{
        {{0.7f, 0.2f, 0.0f}, {0.6f, 0.2f, 0.6f}, {1, 1, 1}, 100.0f},  // idx0 大板
        {{5.0f, 0.2f, 5.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},    // idx1 被搬盒
    });
    Robot r;
    r.setPose(0.0f, 0.0f, 0.0f);
    r.applySupport(0.4f);  // 站上大板顶
    check(near(r.y(), 0.4f, 1e-6f), "叠放：机器人站上大板顶（y=0.4）");
    r.setCarried(1, 1.0f);
    check(world.place(r), "叠放：place 成功");

    const Obstacle& ob = world.obstacles()[1];
    const Obstacle& board = world.obstacles()[0];
    check(near(ob.center.x, 0.7f, 1e-3f), "叠放：水平未被推开（下方是支撑不是墙）");
    check(near(ob.center.y, 0.6f, 1e-3f), "叠放：落在下层箱顶（bottom 0.4 + half 0.2）");
    check(near(ob.center.y - ob.half.y, board.center.y + board.half.y, 1e-3f),
          "叠放：被搬盒底面贴合大板顶面");

    // 放置后 supportHeight 能看到新顶面（0.8）
    Robot probe;
    probe.setPose(0.7f, 0.0f, 0.0f);
    probe.applySupport(0.8f);
    check(near(world.supportHeight(probe), 0.8f, 1e-3f), "叠放：supportHeight 看到新顶面 0.8");
}

// ---- World：pick 拒绝拿走被压住的下层箱 ----

void testPickBlockedByStack() {
    // idx0 下层箱（半0.2，顶面0.4）、idx1 贴着其顶面叠放（底面0.4=idx0顶面，
    // 顶面0.8）。两者 XZ 位置相同，pick() 按 XZ 距离找最近目标时会先命中 idx0
    // （先入遍历、严格 < 不覆盖），但 idx0 上方贴着 idx1，应拒绝拾取。
    World world(std::vector<Obstacle>{
        {{0.7f, 0.2f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 5.0f},  // idx0 下层
        {{0.7f, 0.6f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},  // idx1 叠在idx0顶上
    });
    Robot r;  // 原点 theta=0 → 前方 +X，前端 x=0.2，距idx0近面 0.5 → 0.3m < 0.6m 可及
    check(!world.pick(r), "下层箱上方贴着另一箱 → 拒绝拾取");
    check(!r.isCarrying(), "拒绝拾取后仍未搬运");

    // 拿走上层后，同样的下层箱单独存在时可以正常拾取（回归：不是永久锁死）。
    Robot r2;
    World worldAlone(std::vector<Obstacle>{
        {{0.7f, 0.2f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 5.0f},
    });
    check(worldAlone.pick(r2), "移除上层箱后，下层箱可正常拾取");
    check(r2.carriedIndex() == 0, "拾取到的是下层箱 idx=0");

    // 只有部分 XZ 搭边也算被压住（偏保守：宁可多拒绝）。
    World worldOverhang(std::vector<Obstacle>{
        {{0.7f, 0.2f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 5.0f},   // idx0 下层
        {{0.85f, 0.6f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},  // idx1 半搭边（中心偏移0.15 < 半宽和0.4）
    });
    Robot r3;
    check(!worldOverhang.pick(r3), "只搭半边也算压住 → 仍拒绝拾取");
}

// ---- World：失去支撑的静态箱落到下一支撑面 ----

void testSettleUnsupported() {
    // 下层顶面 0.4、上层底面 0.4 贴合：已经叠稳，settle 不动。
    World stacked(std::vector<Obstacle>{
        {{0.0f, 0.2f, 0.0f}, {0.3f, 0.2f, 0.3f}, {1, 1, 1}, 1.0f},
        {{0.0f, 0.6f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},
    });
    check(stacked.settleUnsupported() == 0, "贴合叠放：没有箱子落下");
    check(near(stacked.obstacles()[1].center.y, 0.6f, 1e-6f), "贴合叠放：上层高度不变");

    // 抽走下层后上层悬空（底面 0.4、脚下是地面）→ 落到地面。
    World gap(std::vector<Obstacle>{
        {{0.0f, 0.6f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},
    });
    check(gap.settleUnsupported() == 1, "悬空箱落到地面");
    check(near(gap.obstacles()[0].center.y, 0.2f, 1e-6f), "落地后 center.y = half.y");
    check(gap.settleUnsupported() == 0, "落地后再 settle 是空操作");

    // 三层叠放、抽走最下层：中层先落到地面，上层再落到中层顶。一轮只落「直接悬空」
    // 的那一层，故调用方要重复直到返回 0。
    World tower(std::vector<Obstacle>{
        {{1.0f, 0.5f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},  // 原中层，底 0.3（悬空）
        {{1.0f, 0.9f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},  // 原上层，底贴着中层顶 0.7
    });
    check(tower.settleUnsupported() == 1, "抽下层：先落直接悬空的中层");
    check(near(tower.obstacles()[0].center.y, 0.2f, 1e-6f), "中层落到地面");
    check(near(tower.obstacles()[1].center.y, 0.9f, 1e-6f), "第一轮上层还悬着（支撑面尚未更新）");
    check(tower.settleUnsupported() == 1, "第二轮上层落到中层新顶面");
    check(near(tower.obstacles()[1].center.y, 0.6f, 1e-6f), "上层底面贴合中层顶面 0.4");

    // 旁边不重叠的矮箱不能当支撑：悬空箱落到地面，而不是被拉到旁边那只的顶上。
    World aside(std::vector<Obstacle>{
        {{0.0f, 0.8f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},  // 悬空
        {{2.0f, 0.15f, 0.0f}, {0.2f, 0.15f, 0.2f}, {1, 1, 1}, 1.0f},  // 旁边，XZ 不重叠
    });
    check(aside.settleUnsupported() == 1, "旁边不重叠的箱子不当支撑");
    check(near(aside.obstacles()[0].center.y, 0.2f, 1e-6f), "悬空箱落到地面而非旁边的顶");
    check(near(aside.obstacles()[1].center.y, 0.15f, 1e-6f), "旁边的箱子自己没被挪");

    // 正被搬运的下标不参与落体，即使它的几何位置悬空。
    World carried(std::vector<Obstacle>{
        {{0.0f, 1.0f, 0.0f}, {0.2f, 0.2f, 0.2f}, {1, 1, 1}, 1.0f},
    });
    check(carried.settleUnsupported({0}) == 0, "背着的箱子不落下");
    check(near(carried.obstacles()[0].center.y, 1.0f, 1e-6f), "背着的箱子高度保持");
}

}  // namespace SimTests
