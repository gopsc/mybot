#pragma once

#include "bridge.h"  // SimCommand, SimEvent::Type

// 语义动作分类学的单一事实源：每个动作的数字码、线上规范名、别名、类别
// （持续型/一次性）、是否带数值参数，都集中在这张表里。
//
// 谁消费它：
//   * bridge.cpp handleLine —— 按线上名查表分派，不再手写 if-else 字符串链；
//   * sim/tests/test_contract.cpp —— 交叉校验 modules/Sim.lua 的 CODES / PARAM_CODES /
//                                    CODE_MAX 是否与本表一致，漏改 Lua 会被测试挡下。
//
// 数字码是对外契约：.mt 动作脚本、robots/spider_sim.sql 注释、docs/sim.md 都用它。
// 改码即破坏兼容——**只增不改**，新动作追加一行、分配未用过的码。
enum class ActionKind {
    Continuous,  // 持续型：像油门位，保持到下一条持续型指令
    OneShot,     // 一次性：入队逐条触发，每条必执行一次
};

struct ActionDef {
    int code;                   // .mt 数字动作码（与 Sim.lua CODES 的下标一致）
    const char* wireName;       // 线上规范名（bridge 按它匹配）
    const char* alias;          // 线上别名（nullptr=无）；如 backward 的 "back"
    ActionKind kind;
    bool needsParam;            // fdist/turn/jump 需首个数值参数（米/度/米）
    bool needsParam2;           // jump 额外需第二数值参数（apex 高度）；其余动作 false
    SimCommand continuous;      // kind==Continuous 时的语义（OneShot 行忽略）
    SimEvent::Type oneShot;     // kind==OneShot 时的语义（Continuous 行忽略）
};

// 全表，按 code 升序、连续覆盖 0..kMaxActionCode。
extern const ActionDef kActions[];
extern const int kActionCount;
extern const int kMaxActionCode;  // 最大数字码（= Sim.lua 的 CODE_MAX）

// 按线上名（含别名）查表；未命中返回 nullptr。
const ActionDef* findActionByWireName(const char* name);
// 按数字码查表；未命中返回 nullptr。
const ActionDef* findActionByCode(int code);
