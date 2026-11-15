/* test_hal_state.cpp —— 宿主状态文件（SGP30 baseline）的 C++ HAL 单测
 *
 * 覆盖：BOT4CJ_STATE_DIR 根下的 6 字节往返、缺失文件返回 null、坏数据拒绝、
 * 目录/绝对路径/traversal/软链/NUL 全部拒绝。测试只碰临时 state 根，不写真机。
 */

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <sys/stat.h>

#include "hal.hpp"
#include "harness.hpp"

namespace {

class TempStateDir {
	std::string path_;
	bool hadOld_ = false;
	std::string oldValue_;

public:
	TempStateDir() {
		char tmpl[] = "/tmp/mybot-state-XXXXXX";
		char* made = ::mkdtemp(tmpl);
		if (made == nullptr) { throw std::runtime_error("mkdtemp failed"); }
		path_ = made;
		if (const char* old = std::getenv("BOT4CJ_STATE_DIR"); old != nullptr) {
			hadOld_ = true;
			oldValue_ = old;
		}
		if (::setenv("BOT4CJ_STATE_DIR", path_.c_str(), 1) != 0) {
			throw std::runtime_error("setenv BOT4CJ_STATE_DIR failed");
		}
	}

	~TempStateDir() {
		if (hadOld_) {
			(void)::setenv("BOT4CJ_STATE_DIR", oldValue_.c_str(), 1);
		} else {
			(void)::unsetenv("BOT4CJ_STATE_DIR");
		}
		std::error_code ec;
		std::filesystem::remove_all(path_, ec);
	}

	TempStateDir(const TempStateDir&) = delete;
	TempStateDir& operator=(const TempStateDir&) = delete;

	const std::string& path() const { return path_; }
};

bot::Json bytes(std::initializer_list<int> values) {
	bot::Json out = bot::JsonArray();
	for (int value : values) { out.add(bot::JsonInt(value)); }
	return out;
}

} // namespace

TH_TEST(hal_state_round_trip_and_missing) {
	TempStateDir dir;
	bot::HALManager hal;

	bot::Json wrote = hal.call("state_write",
		{ bot::JsonString("sgp30-baseline.bin"), bytes({ 1, 2, 3, 4, 5, 6 }) });
	TH_CHECK(wrote.isInt() && wrote.getInt() == 0);

	const std::string file = dir.path() + "/sgp30-baseline.bin";
	std::ifstream in(file, std::ios::binary);
	const std::string raw((std::istreambuf_iterator<char>(in)),
		std::istreambuf_iterator<char>());
	TH_CHECK(raw.size() == 6);
	TH_CHECK(static_cast<unsigned char>(raw[0]) == 1);
	TH_CHECK(static_cast<unsigned char>(raw[5]) == 6);
	struct stat st{};
	TH_CHECK(::stat(file.c_str(), &st) == 0);
	TH_CHECK((st.st_mode & 0777) == 0600);

	bot::Json read = hal.call("state_read", { bot::JsonString("sgp30-baseline.bin") });
	TH_CHECK(read.isArr() && read.size() == 6);
	for (std::size_t i = 0; i < read.size(); ++i) {
		TH_CHECK(read.at(i).isInt());
		TH_CHECK(read.at(i).getInt() == static_cast<std::int64_t>(i + 1));
	}

	bot::Json missing = hal.call("state_read", { bot::JsonString("missing.bin") });
	TH_CHECK(missing.isNull());
}

TH_TEST(hal_state_rejects_unsafe_names_and_payloads) {
	TempStateDir dir;
	bot::HALManager hal;

	const char* unsafe[] = { "", ".", "..", "../escape.bin", "a/b.bin",
		"/etc/passwd", "a\\b.bin" };
	for (const char* name : unsafe) {
		bot::Json wrote = hal.call("state_write",
			{ bot::JsonString(name), bytes({ 1, 2, 3 }) });
		TH_CHECK(wrote.isInt() && wrote.getInt() == -1);
		bot::Json read = hal.call("state_read", { bot::JsonString(name) });
		TH_CHECK(read.isInt() && read.getInt() == -1);
	}

	std::string nulName("a\0b", 3);
	bot::Json nul = hal.call("state_write",
		{ bot::JsonString(nulName), bytes({ 1 }) });
	TH_CHECK(nul.isInt() && nul.getInt() == -1);

	bot::Json notArray = hal.call("state_write",
		{ bot::JsonString("bad.bin"), bot::JsonString("abc") });
	TH_CHECK(notArray.isInt() && notArray.getInt() == -1);

	bot::Json badByte = hal.call("state_write",
		{ bot::JsonString("bad.bin"), bytes({ 256 }) });
	TH_CHECK(badByte.isInt() && badByte.getInt() == -1);
}

TH_TEST(hal_state_rejects_symlink_targets) {
	TempStateDir dir;
	bot::HALManager hal;
	const std::string link = dir.path() + "/link.bin";
	std::error_code ec;
	std::filesystem::create_symlink("/etc/passwd", link, ec);
	if (ec) { TH_SKIP("该文件系统不支持创建符号链接，无法验证 O_NOFOLLOW 策略"); }

	bot::Json wrote = hal.call("state_write",
		{ bot::JsonString("link.bin"), bytes({ 1, 2, 3 }) });
	TH_CHECK(wrote.isInt() && wrote.getInt() == -1);
	bot::Json read = hal.call("state_read", { bot::JsonString("link.bin") });
	TH_CHECK(read.isInt() && read.getInt() == -1);
}
