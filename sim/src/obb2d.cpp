#include "obb2d.h"

#include <algorithm>
#include <cmath>

#include "world.h"  // Obstacle 的完整定义（本头里只前向声明）

// 函数体自 world.cpp 的匿名 namespace 逐字搬迁（2026-10-04，第三轮重构 Phase 21），
// 算法未改；只把命名交给 Obb2D 承载（见 obb2d.h 顶部的改名对照）。

namespace Obb2D {

float distanceSqXZ(const Obstacle& ob, float px, float pz) {
    float lx, lz;
    worldToLocal(px - ob.center.x, pz - ob.center.z, ob.yaw, lx, lz);
    float cx, cz;
    clampToBox(lx, lz, ob.half.x, ob.half.z, cx, cz);
    const float dx = lx - cx, dz = lz - cz;
    return dx * dx + dz * dz;
}

bool rayHit(float ox, float oz, float dx, float dz,
            const Obstacle& ob, float& tHit) {
    const float yaw = ob.yaw;
    float lox, loz, ldx, ldz;
    worldToLocal(ox - ob.center.x, oz - ob.center.z, yaw, lox, loz);
    worldToLocal(dx, dz, yaw, ldx, ldz);

    const float hx = ob.half.x, hz = ob.half.z;
    float tmin = -1e30f, tmax = 1e30f;

    if (std::abs(ldx) < 1e-8f) {
        if (lox < -hx || lox > hx) return false;
    } else {
        float t1 = (-hx - lox) / ldx;
        float t2 = (hx - lox) / ldx;
        if (t1 > t2) std::swap(t1, t2);
        tmin = std::max(tmin, t1);
        tmax = std::min(tmax, t2);
        if (tmin > tmax) return false;
    }

    if (std::abs(ldz) < 1e-8f) {
        if (loz < -hz || loz > hz) return false;
    } else {
        float t1 = (-hz - loz) / ldz;
        float t2 = (hz - loz) / ldz;
        if (t1 > t2) std::swap(t1, t2);
        tmin = std::max(tmin, t1);
        tmax = std::min(tmax, t2);
        if (tmin > tmax) return false;
    }

    if (tmin < 0.0f) return false;
    tHit = tmin;
    return true;
}

bool rayHitAtHeight(float ox, float oz, float dx, float dz, float rayY,
                    const Obstacle& ob, float& tHit) {
    float t;
    if (!rayHit(ox, oz, dx, dz, ob, t)) return false;
    const float bottom = ob.center.y - ob.half.y;
    const float top = ob.center.y + ob.half.y;
    // 射线水平：命中点高度就是 rayY。贴在顶面或底面上算命中（闭区间），
    // 否则站在恰好与射线齐平的箱顶边缘会被当成「没有墙」。
    if (rayY < bottom || rayY > top) return false;
    tHit = t;
    return true;
}

bool resolveSphere(float& sx, float& sz, float radius,
                   const Obstacle& ob) {
    const float yaw = ob.yaw;
    float lx, lz;
    worldToLocal(sx - ob.center.x, sz - ob.center.z, yaw, lx, lz);
    const float hx = ob.half.x, hz = ob.half.z;

    // 盒（局部系里以原点为中心，半尺寸 ±half）面上离球心最近的点
    float cx, cz;
    clampToBox(lx, lz, hx, hz, cx, cz);
    const float dx = lx - cx, dz = lz - cz;
    const float distSq = dx * dx + dz * dz;
    if (distSq >= radius * radius) {
        return false;  // 无碰撞
    }

    float nlx = lx, nlz = lz;
    const float dist = std::sqrt(distSq);
    if (dist < 1e-5f) {
        // 球心在盒内：沿最短轴推出
        const float penXp = hx - lx, penXn = lx + hx;
        const float penZp = hz - lz, penZn = lz + hz;
        float minPen = penXp;
        int axis = 0;  // 0=x, 1=z
        float sign = 1.0f;
        if (penXn < minPen) { minPen = penXn; axis = 0; sign = -1.0f; }
        if (penZp < minPen) { minPen = penZp; axis = 1; sign = 1.0f; }
        if (penZn < minPen) { minPen = penZn; axis = 1; sign = -1.0f; }
        const float push = radius + minPen;
        if (axis == 0) {
            nlx += sign * push;
        } else {
            nlz += sign * push;
        }
    } else {
        // 球心在盒外但距离 < radius：沿 dx,dz 方向推出
        const float push = radius - dist;
        nlx += (dx / dist) * push;
        nlz += (dz / dist) * push;
    }

    // 只把位移增量旋回世界系叠加
    float wdx, wdz;
    localToWorld(nlx - lx, nlz - lz, yaw, wdx, wdz);
    sx += wdx;
    sz += wdz;
    return true;
}

float projRadius(const Obstacle& ob, float nx, float nz) {
    const float c = std::cos(ob.yaw), s = std::sin(ob.yaw);
    return ob.half.x * std::abs(c * nx - s * nz) + ob.half.z * std::abs(s * nx + c * nz);
}

bool overlapXZ(const Obstacle& a, const Obstacle& b) {
    const float ca = std::cos(a.yaw), sa = std::sin(a.yaw);
    const float cb = std::cos(b.yaw), sb = std::sin(b.yaw);
    const float axes[4][2] = {
        {ca, -sa}, {sa, ca},  // a 的局部 +X / +Z 世界方向
        {cb, -sb}, {sb, cb},  // b 的局部 +X / +Z 世界方向
    };
    const float dx = b.center.x - a.center.x;
    const float dz = b.center.z - a.center.z;
    for (const auto& ax : axes) {
        if (std::abs(dx * ax[0] + dz * ax[1]) >=
            projRadius(a, ax[0], ax[1]) + projRadius(b, ax[0], ax[1])) {
            return false;
        }
    }
    return true;
}

}  // namespace Obb2D
