#pragma once

#include <algorithm>
#include <cmath>

struct Obstacle;

// XZ 平面上的 2D 有向盒（OBB）几何：局部系旋转、盒面最近点、前方向量、射线求交、
// SAT 重叠、球-盒推出。纯几何、无状态、GL 无关，归 simcore，可 headless 单测。
//
// 朝向盒（OBB）的局部系约定：盒局部 +X 轴在世界系的方向是 (cos yaw, -sin yaw)，
// 与 Robot::theta 同号。解算 OBB 的思路——绕 Y 旋转是等距变换（保长度、保点积），
// 所以把点/方向**旋进盒局部系**后就能复用轴对齐数学，再把结果旋回世界系。
// 下面两个辅助互逆。仅对「点相对盒心」的位移增量做旋回，避免把盒心也旋了。
//
// 2026-10-04 从 world.cpp 的匿名 namespace 抽出（第三轮重构 Phase 21）：原先
// 「旋进局部系 → clamp 最近点 → 算距离」在 resolveSphereOBB2D / supportHeight /
// pick 三处各抄一遍，「(cos θ, -sin θ) 前方向量」在 queryRange / pick / place 三处
// 各抄一遍——六份手抄同一条约定，任一处符号写错只会表现为「测距偏一点」「拾取够不
// 到」这类没有报错的几何偏差。函数体逐字搬迁、算法未改；命名去掉 obb/2D 前缀
// （由 namespace 承载，与 SimPaths / SimConfig 同款）：
//   worldToLocal2D → worldToLocal        localToWorld2D → localToWorld
//   obbProjRadius  → projRadius          obbOverlapXZ   → overlapXZ
//   rayOBB2D       → rayHit              resolveSphereOBB2D → resolveSphere
namespace Obb2D {

inline void worldToLocal(float dx, float dz, float yaw, float& lx, float& lz) {
    const float c = std::cos(yaw), s = std::sin(yaw);
    lx = dx * c - dz * s;
    lz = dx * s + dz * c;
}
inline void localToWorld(float lx, float lz, float yaw, float& dx, float& dz) {
    const float c = std::cos(yaw), s = std::sin(yaw);
    dx = lx * c + lz * s;
    dz = -lx * s + lz * c;
}

// 朝向 theta 的前方单位向量（世界系）。与上面「盒局部 +X 的世界方向」是同一条
// 约定，故 Robot::theta 与 Obstacle::yaw 可互换代入（place() 正依赖这一点：它把
// 待放盒的 yaw 设成 robot.theta()，于是机器人前方恰好是该盒的局部 +X 轴）。
inline void forwardOf(float theta, float& fx, float& fz) {
    fx = std::cos(theta);
    fz = -std::sin(theta);
}

// 局部系里（盒以原点为中心、半尺寸 ±(hx,hz)）盒面上离 (lx,lz) 最近的点：逐轴钳制。
// 点在盒内时两轴都被钳住，最近点即钳制点本身，位移增量为 0——「盒内」这一情形由
// 调用方自己判（resolveSphere 要沿最短轴推出，distanceSqXZ 直接报 0）。
inline void clampToBox(float lx, float lz, float hx, float hz, float& cx, float& cz) {
    cx = std::clamp(lx, -hx, hx);
    cz = std::clamp(lz, -hz, hz);
}

// 世界系点 (px,pz) 到 OBB 的 XZ 截面边界的距离平方（米²）；点在截面内为 0。
// 旋进盒局部系按轴对齐解算，旋转保距故局部系里算出的距离即世界系距离。
// 返回平方是因为两个调用方各取所需：supportHeight 只与半径²比大小（省一次开方），
// pick 要真实距离（自己开方）。
float distanceSqXZ(const Obstacle& ob, float px, float pz);

// OBB 在给定世界法向上的投影半径（SAT 用）：half.x*|uX·n| + half.z*|uZ·n|，
// 其中局部 +X 世界方向 uX=(cos,-sin)、+Z 为 uZ=(sin,cos)（与 worldToLocal 一致）。
float projRadius(const Obstacle& ob, float nx, float nz);

// 两个 OBB 在 XZ 平面是否重叠：2D SAT，候选轴 = 两盒各自局部 X/Z（4 条）。
// 任一轴上投影距离 >= 半径和即分离；用 >=（非 >）使「贴合」不算重叠——放置刚推到
// 相切时不应再触发推出。
bool overlapXZ(const Obstacle& a, const Obstacle& b);

// 2D 射线 vs OBB（XZ 平面）求交：把射线旋进盒局部系转为轴对齐 slab 法。
// 射线从世界系 (ox,oz) 沿世界系 (dx,dz) 方向；旋转保距，故局部系里算出的 tHit
// 直接可用。无命中返回 false。
bool rayHit(float ox, float oz, float dx, float dz, const Obstacle& ob, float& tHit);

// 水平射线 vs 有限高度的盒：XZ 命中点处射线高度 rayY 必须落在盒的竖直区间内。
// 射线水平（不按 y 衰减），故「站在箱顶上看过去」会穿过错过脚下的地板，只打到
// 比射线高的墙。rayY 低于盒底或高于盒顶都算未命中。
bool rayHitAtHeight(float ox, float oz, float dx, float dz, float rayY,
                    const Obstacle& ob, float& tHit);

// 球（XZ 平面）vs OBB（XZ 截面）碰撞解算：旋进盒局部系按原点盒解算，再把位移
// 增量旋回世界系叠加。返回 true 表示发生了碰撞（位置被修正）。
bool resolveSphere(float& sx, float& sz, float radius, const Obstacle& ob);

}  // namespace Obb2D
