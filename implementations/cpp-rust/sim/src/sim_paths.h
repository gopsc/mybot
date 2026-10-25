#pragma once

#include <string>

// 状态目录（`$MYBOT_HOME`，缺省 `$HOME/.mybot`）下的路径规则，GL 无关、可单测。
//
// 与 agent 侧 `session_store` 同源：同样是「固定根 + 自造路径」，同样把环境变量
// 读取收在 `mybotHome()` 一处。地图（场景文件）落在 `<home>/maps/`，仓库里的
// `sim/scenes/*.scene` 退回「只读模板」角色——缺哪个名字就从模板播种一份到地图
// 目录，此后 sim 只读写地图目录里的那份。
namespace SimPaths {

// 状态目录根：`MYBOT_HOME` > `$HOME/.mybot` > `""`（空 = 无家目录，持久化退回内置）。
std::string mybotHome();

// 地图目录：`<home>/maps`（home 为空 → ""）。
std::string mapsDir(const std::string& home);

// 场景路径解析：
//   * raw 为空      → ""（调用方退回内置场景）
//   * raw 含 '/'    → raw 原样（显式路径，如仓库 `sim/scenes/default.scene`）
//   * raw 是裸名字  → `<maps>/<raw>.scene`（无家目录 → ""）
std::string resolveScenePath(const std::string& home, const std::string& raw);

// 播种模板查找（name 是场景文件名，含 `.scene`）：
//   优先编译期 `MYBOT_SIM_SCENES_DIR`（源码树 `sim/scenes`），回退 `/proc/self/exe`
//   相对的 `../scenes/<name>`。都取不到 → ""（调用方不播种、告警、退回内置）。
std::string templateScene(const std::string& name);

// 逐级建目录，**只对本次新建的层级**设 0700（既有目录不擅自改权限）。
// 成功返回 true；失败置 *err 并返回 false。
bool ensureDir0700(const std::string& dir, std::string* err);

// 若 dest 不存在则从 tmpl 复制一份（temp + rename，0600 不留残留）；**已存在绝不覆盖**。
// *seeded 报本次是否真的播种了。tmpl 非空由调用方保证。失败置 *err 并返回 false。
bool seedSceneIfMissing(const std::string& dest, const std::string& tmpl, bool* seeded,
                        std::string* err);

}  // namespace SimPaths