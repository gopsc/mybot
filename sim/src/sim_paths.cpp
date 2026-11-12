#include "sim_paths.h"

#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <fstream>

// 源码树 `sim/scenes` 由 CMake 在编译期注入（照抄 sim_tests 的 MYBOT_MODULES_DIR
// 先例）。未定义时退回 /proc/self/exe 相对查找。
#ifndef MYBOT_SIM_SCENES_DIR
#define MYBOT_SIM_SCENES_DIR ""
#endif

namespace {

bool isFile(const std::string& p) {
    struct stat st;
    return !p.empty() && ::stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

bool isDir(const std::string& p) {
    struct stat st;
    return !p.empty() && ::stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// 可执行文件所在目录（/proc/self/exe 的 dirname）；取不到 → ""。
std::string exeDir() {
    char buf[4096];
    const ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) {
        return "";
    }
    buf[n] = '\0';
    const std::string exe(buf);
    const std::size_t slash = exe.rfind('/');
    return slash == std::string::npos ? "" : exe.substr(0, slash);
}

}  // namespace

namespace SimPaths {

// 状态目录取值链：MYBOT_HOME 非空 > $HOME/.mybot > 不可用（返回空）。
// 规则单点在 docs/reference.md 的 MYBOT_HOME 行；同一条链在 Rust agent
// （agent/src/config/mod.rs 的 derive_state_dir）与 scripts/sim_agent_demo.sh
// 各手写一份——跨两套构建系统不做代码生成，缺省目录名的三处一致由
// test/run_all_selftest.sh 钉住。
std::string mybotHome() {
    if (const char* v = std::getenv("MYBOT_HOME")) {
        if (v[0] != '\0') {
            return v;
        }
    }
    if (const char* h = std::getenv("HOME")) {
        if (h[0] != '\0') {
            return std::string(h) + "/.mybot";
        }
    }
    return "";
}

std::string mapsDir(const std::string& home) { return home.empty() ? "" : home + "/maps"; }

std::string resolveScenePath(const std::string& home, const std::string& raw) {
    if (raw.empty()) {
        return "";
    }
    if (raw.find('/') != std::string::npos) {
        return raw;
    }
    const std::string maps = mapsDir(home);
    if (maps.empty()) {
        return "";
    }
    return maps + "/" + raw + ".scene";
}

std::string templateScene(const std::string& name) {
    if (name.empty()) {
        return "";
    }
    const std::string dir = MYBOT_SIM_SCENES_DIR;
    if (!dir.empty()) {
        const std::string p = dir + "/" + name;
        if (isFile(p)) {
            return p;
        }
    }
    const std::string ed = exeDir();
    if (!ed.empty()) {
        const std::string p = ed + "/../scenes/" + name;
        if (isFile(p)) {
            return p;
        }
    }
    return "";
}

bool ensureDir0700(const std::string& dir, std::string* err) {
    if (dir.empty()) {
        if (err) {
            *err = "空目录路径";
        }
        return false;
    }
    std::string cur;
    std::size_t i = 0;
    if (dir[0] == '/') {
        cur = "/";
        i = 1;
    }
    while (i <= dir.size()) {
        const std::size_t j = dir.find('/', i);
        const std::string comp = dir.substr(i, j == std::string::npos ? std::string::npos : j - i);
        if (!comp.empty() && comp != ".") {
            if (cur.empty() || cur.back() != '/') {
                cur += '/';
            }
            cur += comp;
            if (isDir(cur)) {
                // 既有层级不擅自改权限（里面可能有别人的东西）
            } else if (::mkdir(cur.c_str(), 0700) != 0) {
                if (err) {
                    *err = "无法创建目录 " + cur;
                }
                return false;
            } else {
                // mkdir 的 mode 受 umask 影响，显式再设一次确保 0700
                ::chmod(cur.c_str(), 0700);
            }
        }
        if (j == std::string::npos) {
            break;
        }
        i = j + 1;
    }
    return true;
}

bool seedSceneIfMissing(const std::string& dest, const std::string& tmpl, bool* seeded,
                        std::string* err) {
    if (seeded) {
        *seeded = false;
    }
    if (dest.empty()) {
        if (err) {
            *err = "空目标路径";
        }
        return false;
    }
    if (isFile(dest)) {
        return true;  // 已存在绝不覆盖
    }
    std::ifstream in(tmpl, std::ios::binary);
    if (!in) {
        if (err) {
            *err = "无法读取模板 " + tmpl;
        }
        return false;
    }
    const std::string tmp = dest + ".tmp." + std::to_string(::getpid());
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) {
            if (err) {
                *err = "无法写入临时文件 " + tmp;
            }
            return false;
        }
        out << in.rdbuf();
        if (!out) {
            out.close();
            ::unlink(tmp.c_str());
            if (err) {
                *err = "复制模板内容失败 " + tmpl;
            }
            return false;
        }
    }
    ::chmod(tmp.c_str(), 0600);
    if (::rename(tmp.c_str(), dest.c_str()) != 0) {
        ::unlink(tmp.c_str());
        if (err) {
            *err = "无法把播种结果落到 " + dest;
        }
        return false;
    }
    if (seeded) {
        *seeded = true;
    }
    return true;
}

}  // namespace SimPaths