/* main.cpp —— C++ 单测入口
 *
 * 用法：./build/mybot_tests            跑全部
 *       ./build/mybot_tests matrix     只跑名字含 matrix 的用例
 * 退出码：0 = 全通过；1 = 有失败或过滤器无命中（**不用失败用例数**——退出状态
 * 只有 8 位，256 个失败会回绕成 0，见 harness.hpp 的 C10 注释）。
 */

#include <string>

#include "harness.hpp"

int main(int argc, char** argv) {
	const std::string filter = argc > 1 ? std::string(argv[1]) : std::string();
	const int rc = th::runAll(filter);
	return rc < 0 ? 1 : rc;	/* runAll 只返回 0/1/-1（-1 = 过滤器无命中） */
}
