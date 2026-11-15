/* test_hal_speaker.cpp —— C++ HAL 的 Speaker/ALSA 操作分派与错误路径
 *
 * 不依赖声卡：只验证句柄校验、错误码回传、speaker_errmsg 的文本出口，
 * 以及无效设备名/非法采样率不会静默成功。真实 PCM 播放由硬件/手工验证。
 */

#include <string>
#include <vector>

#include "hal.hpp"
#include "harness.hpp"

namespace {

bot::Json callSpeaker(bot::HALManager& hal, const char* operation,
		std::initializer_list<bot::Json> args) {
	return hal.call(operation, std::vector<bot::Json>(args));
}

} // namespace

TH_TEST(hal_speaker_rejects_invalid_handles) {
	bot::HALManager hal;
	TH_CHECK(callSpeaker(hal, "speaker_write",
		{ bot::JsonInt(0), bot::JsonString(std::string(2, '\0')) }).getInt() == -1);
	TH_CHECK(callSpeaker(hal, "speaker_prepare", { bot::JsonInt(0) }).getInt() == -1);
	TH_CHECK(callSpeaker(hal, "speaker_drain", { bot::JsonInt(0) }).getInt() == -1);
	TH_CHECK(callSpeaker(hal, "speaker_close", { bot::JsonInt(0) }).getInt() == -1);
}

TH_TEST(hal_speaker_rejects_malformed_write_payload) {
	bot::HALManager hal;
	TH_CHECK(callSpeaker(hal, "speaker_write",
		{ bot::JsonInt(0), bot::JsonString("x") }).getInt() == -1);
	TH_CHECK(callSpeaker(hal, "speaker_write",
		{ bot::JsonInt(0), bot::JsonString("") }).getInt() == -1);
}

TH_TEST(hal_speaker_errmsg_returns_text) {
	bot::HALManager hal;
	bot::Json result = callSpeaker(hal, "speaker_errmsg", { bot::JsonInt(-32) });
	TH_CHECK(result.isStr());
	TH_CHECK(!result.getValue().empty());
}

TH_TEST(hal_speaker_open_rejects_bad_device_or_rate) {
	bot::HALManager hal;
	bot::Json badRate = callSpeaker(hal, "speaker_open",
		{ bot::JsonString("default"), bot::JsonInt(1) });
	TH_CHECK(badRate.isInt() && badRate.getInt() == -1);

	bot::Json badDevice = callSpeaker(hal, "speaker_open",
		{ bot::JsonString("__mybot_no_such_alsa_device__"), bot::JsonInt(16000) });
	TH_CHECK(badDevice.isInt());
	if (badDevice.getInt() >= 0) {
		/* 极端环境若把未知设备映射到某个插件，至少验证句柄可关闭。 */
		TH_CHECK(callSpeaker(hal, "speaker_close", { badDevice }).getInt() == 0);
	} else {
		bot::Json last = hal.call("last_error", {});
		TH_CHECK(last.isStr() && !last.getValue().empty());
	}
}
