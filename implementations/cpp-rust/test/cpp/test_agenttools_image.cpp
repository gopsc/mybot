/* test_agenttools_image.cpp —— capture_image 工具面
 *
 * 自 test_agenttools.cpp 拆出（2026-10-01，行为保持），镜像 src/agentimage.cpp
 * 的域边界：真 Camera.lua 仿真驱动、MIME 随内容（AG-9）、体积判据在 base64
 * 之前命中（AG-19）、尺寸参数（#6）、白名单根、FakeCamRig 夹具随迁。 */

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <string>
#include <sys/wait.h>
#include <system_error>
#include <vector>
#include <unistd.h>

#include "agent_subprocess.hpp"
#include "agentdispatch.hpp"
#include "agentproto.hpp"
#include "agenttools.hpp"
#include "agenttools_internal.hpp"
#include "jsonparse.hpp"
#include "luaend.hpp"
#include "luaexec.hpp"
#include "luavar.hpp"
#include "robot.hpp"
#include "util_env.hpp"
#include "util_except.hpp"
#include "util_utf8.hpp"
#include "fixtures.hpp"
#include "harness.hpp"
#include "agenttools_fixtures.hpp"

namespace fs = std::filesystem;

using namespace bot;
using namespace bot::agent;

using fx::ModulePathGuard;
using fx::TempDir;
using afx::readAll;
using afx::writeFile;
TH_TEST(agenttools_capture_image_via_real_camera_driver) {
	/* 用**真驱动** modules/Camera.lua 的仿真模式（src=<文件>）跑通「拍照 → 图片通道」，
	 * 不需要任何摄像头硬件；返回的 base64 必须与源文件逐字节一致 */
	TempDir tmp("cam");
	fs::path pic = tmp.path() / "pic.jpg";
	/* 必须是真的 JPEG 头（FF D8 FF）：AG-9 之后宿主会拿魔数与驱动声明的 format
	 * 交叉校验，随便一段字节不再能当图片用。base64("\xff\xd8\xff" "foobar") 固定。 */
	const std::string jpeg = std::string("\xff\xd8\xff", 3) + "foobar";
	writeFile(pic, jpeg);

	MemoryReader reader("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	RobotStruct robot(reader);
	robot.injectLuaDriver("Camera", "cam0");
	robot.active();

	AgentToolContext ctx;
	ctx.robot = &robot;
	ctx.camera = robot.registry().find("cam0");
	TH_CHECK(ctx.camera != nullptr);
	ctx.cameraSrc = pic.string();
	ctx.cameraSrcFromCli = true;	/* H1：用例扮演"操作者用 --camera-src 指定" */
	AgentToolRegistry tools = makeAgentTools(ctx);
	TH_CHECK(tools.contains("capture_image"));

	AgentToolResult res = tools.execute("capture_image", parseJson("{}"));
	TH_CHECK(res.text.find("已拍摄照片") != std::string::npos);
	TH_CHECK(res.text.find("模拟图片") != std::string::npos);
	TH_CHECK(res.text.find("9 字节") != std::string::npos);
	TH_CHECK(res.imageDataUrl.rfind("data:image/jpeg;base64,", 0) == 0);

	robot.deactivate();
}

/* ---- AG-9：data URL 的 MIME 必须来自内容，而不是硬编码 ----
 * 修复前宿主恒拼 `data:image/jpeg;base64,`：传一张 PNG 就得到「JPEG 标签 +
 * PNG 字节」，严格网关按图片解析直接 400。现在 MIME 取自驱动按**魔数**判定的
 * format，宿主只做自洽交叉校验。 */
namespace {

/* 各格式的最小可判样本（只需魔数，驱动与宿主都只读魔数） */
std::string pngBytes() { return std::string("\x89PNG\r\n\x1a\n", 8) + "payload-png"; }
std::string gifBytes() { return std::string("GIF89a", 6) + "payload-gif"; }
std::string webpBytes() {
	return std::string("RIFF", 4) + std::string(4, '\0') + "WEBPpayload-webp";
}
std::string bmpBytes() { return std::string("BM", 2) + std::string(30, 'x'); }

} // namespace

/* 三种非 JPEG 格式都必须产出正确的 MIME 标签（PNG/GIF/WebP 各有独立分支） */
TH_TEST(agenttools_capture_image_mime_follows_content_format) {
	const std::pair<const char*, std::string (*)()> cases[] = {
		{"png", &pngBytes}, {"gif", &gifBytes}, {"webp", &webpBytes},
	};
	for (const auto& [name, make] : cases) {
		TempDir tmp(std::string("mime_") + name);
		const fs::path pic = tmp.path() / (std::string("pic.") + name);
		writeFile(pic, make());

		MemoryReader reader("CREATE TABLE Timer (name String);\n"
			"INSERT INTO Timer (name) VALUES ('t0');\n");
		RobotStruct robot(reader);
		robot.injectLuaDriver("Camera", "cam0");
		robot.active();

		AgentToolContext ctx;
		ctx.robot = &robot;
		ctx.camera = robot.registry().find("cam0");
		ctx.cameraSrc = pic.string();
		ctx.cameraSrcFromCli = true;	/* H1：用例扮演"操作者用 --camera-src 指定" */
		AgentToolRegistry tools = makeAgentTools(ctx);
		const AgentToolResult res = tools.execute("capture_image", parseJson("{}"));

		const std::string expect = std::string("data:image/") + name + ";base64,";
		TH_CHECK_MSG(res.imageDataUrl.rfind(expect, 0) == 0,
			std::string("MIME 应为 ") + expect + "，实际 " + res.imageDataUrl.substr(0, 40));
		TH_CHECK_MSG(res.text.find("已拍摄照片") != std::string::npos, res.text);
		robot.deactivate();
	}
}

/* 不受支持/无法识别的格式必须**响亮拒绝**，而不是猜一个 MIME 发出去 */
TH_TEST(agenttools_capture_image_rejects_non_image_source) {
	TempDir tmp("notimg");
	const fs::path pic = tmp.path() / "note.jpg";	/* 扩展名像图片，内容是 BMP */
	writeFile(pic, bmpBytes());

	MemoryReader reader("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	RobotStruct robot(reader);
	robot.injectLuaDriver("Camera", "cam0");
	robot.active();

	AgentToolContext ctx;
	ctx.robot = &robot;
	ctx.camera = robot.registry().find("cam0");
	ctx.cameraSrc = pic.string();
	ctx.cameraSrcFromCli = true;	/* H1：用例扮演"操作者用 --camera-src 指定" */
	AgentToolRegistry tools = makeAgentTools(ctx);
	const AgentToolResult res = tools.execute("capture_image", parseJson("{}"));

	TH_CHECK_MSG(res.imageDataUrl.empty(), "不该为不可识别的来源产出图片 URL");
	TH_CHECK_MSG(res.text.find("unsupported sim image format") != std::string::npos,
		"应点名「格式不受支持」，实际: " + res.text);
	robot.deactivate();
}

/* 审计 E：一张图就是历史单块的主项，而 maxHistoryBytes 刻意不封顶单块——
 * 所以宿主侧必须有一道入口硬上限，否则一次拍照就能把请求体顶到网关限额之外。 */
TH_TEST(agenttools_capture_image_rejects_oversize_image) {
	TempDir tmp("bignum");
	/* raw = 3 的倍数且 base64 后刚好越过上限（4 字节一组，无填充歧义） */
	static_assert(kMaxImageBase64Bytes % 4 == 0);
	const std::size_t raw = kMaxImageBase64Bytes / 4 * 3 + 3;
	fs::path pic = tmp.path() / "big.jpg";
	/* 带真实 JPEG 头：让「超限」成为这条用例**唯一**的失败原因（否则它会因为
	 * 魔数不符而红，测不到上限本身） */
	writeFile(pic, std::string("\xff\xd8\xff", 3) + std::string(raw - 3, 'x'));

	MemoryReader reader("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	RobotStruct robot(reader);
	robot.injectLuaDriver("Camera", "cam0");
	robot.active();

	AgentToolContext ctx;
	ctx.robot = &robot;
	ctx.camera = robot.registry().find("cam0");
	ctx.cameraSrc = pic.string();
	ctx.cameraSrcFromCli = true;	/* H1：用例扮演"操作者用 --camera-src 指定" */
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult res = tools.execute("capture_image", parseJson("{}"));
	TH_CHECK(res.text.find("图像过大") != std::string::npos);
	TH_CHECK(res.imageDataUrl.empty());

	robot.deactivate();
}

/* PL-4（2026-09-22）：2 MiB 上限此前只在**用例内部**由被测常量推导——上面两条
 * 用例的夹具尺寸都是 `kMaxImageBase64Bytes / 4 * 3 + 3`，常量被改错时夹具跟着走，
 * 用例仍然绿：它测的是「越过自己」，不是「越过 2 MiB」。
 * 这里改用**字面量**钉住，两道：
 *   ① 编译期：常量必须字面等于 2 MiB——改了这里编译不过，逼改动者面对
 *      docs/agent.md 的已知限制与 capture_image 的工具描述（两处都写着 2 MiB）；
 *   ② 运行期：raw = 3/4 × 2 MiB（base64 恰好 2 MiB）放行，多 3 字节即拒
 *      ——判据是 `>`，边界值属于放行侧。 */
TH_TEST(agenttools_image_cap_boundary_is_pinned_by_literal) {
	constexpr std::size_t kLiteralB64Cap = 2u << 20;		/* 2 MiB */
	constexpr std::size_t kLiteralRawCap = kLiteralB64Cap / 4 * 3;	/* 1572864 */
	static_assert(kMaxImageBase64Bytes == kLiteralB64Cap,
		"图片 base64 上限变了：docs/agent.md 的已知限制与 capture_image 的工具描述"
		"都写着 2 MiB，改这里就必须同步那两处");

	ModulePathGuard guard("./modules:test/cpp");
	TempDir tmp("litcap");

	auto capture = [&](std::size_t raw) {
		const fs::path sqlFile = tmp.path() / ("cam" + std::to_string(raw) + ".sql");
		writeFile(sqlFile,
			"CREATE TABLE AgentFakeCamera (name String, raw_bytes String, omit_bytes String);\n"
			"INSERT INTO AgentFakeCamera (name, raw_bytes, omit_bytes) "
			"VALUES ('cam0', '" + std::to_string(raw) + "', 'no');\n");
		MemoryReader reader(readAll(sqlFile.string()));
		RobotStruct robot(reader);
		robot.active();
		AgentToolContext ctx;
		ctx.robot = &robot;
		ctx.camera = robot.registry().find("cam0");
		AgentToolRegistry tools = makeAgentTools(ctx);
		AgentToolResult res = tools.execute("capture_image", parseJson("{}"));
		robot.deactivate();
		return res;
	};

	AgentToolResult atCap = capture(kLiteralRawCap);
	TH_CHECK_MSG(!atCap.imageDataUrl.empty(),
		"恰好 1.5 MiB 原始字节（base64 恰为 2 MiB）应放行，实际: " + atCap.text);

	AgentToolResult overCap = capture(kLiteralRawCap + 3);
	TH_CHECK_MSG(overCap.imageDataUrl.empty(), "越过 2 MiB 就该拒");
	TH_CHECK_MSG(overCap.text.find("图像过大") != std::string::npos, overCap.text);
}

/* ---- AG-19：体积判据必须在 base64 编码**之前**命中 ----
 * 修复前宿主只按 base64 长度判，而驱动侧的仿真上限是 16 MiB（base64 约 21 MB）：
 * 一张注定被拒的图要先被 base64 编码、跨 Json/Lua 边界搬运、再被拒。实测 10 MiB
 * 的图让进程峰值到 219 MiB（.tmp/memaudit/）。现在先用驱动声明的原始字节数判。
 * 「命中哪一道」由文案区分：早退那道会点名「未做 base64 编码即拒绝」，
 * 兜底那道会点名实际的 base64 字节数——所以断言文案即可证明顺序。 */
TH_TEST(agenttools_capture_image_rejects_oversize_raw_before_base64) {
	TempDir tmp("bigraw");
	/* 原始字节数刚好越过折算上限（3/4 × kMaxImageBase64Bytes），但仍远在驱动侧
	 * 16 MiB 仿真上限之内——即「驱动会照常返回、只有宿主这道判据能拦」的区间 */
	const std::size_t maxRaw = kMaxImageBase64Bytes / 4 * 3;
	const std::size_t raw = maxRaw + 3;
	fs::path pic = tmp.path() / "big.jpg";
	writeFile(pic, std::string("\xff\xd8\xff", 3) + std::string(raw - 3, 'x'));

	MemoryReader reader("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	RobotStruct robot(reader);
	robot.injectLuaDriver("Camera", "cam0");
	robot.active();

	AgentToolContext ctx;
	ctx.robot = &robot;
	ctx.camera = robot.registry().find("cam0");
	ctx.cameraSrc = pic.string();
	ctx.cameraSrcFromCli = true;	/* H1：用例扮演"操作者用 --camera-src 指定" */
	AgentToolRegistry tools = makeAgentTools(ctx);
	const AgentToolResult res = tools.execute("capture_image", parseJson("{}"));

	TH_CHECK_MSG(res.imageDataUrl.empty(), "超限图不该产出图片 URL");
	TH_CHECK_MSG(res.text.find("图像过大") != std::string::npos, res.text);
	TH_CHECK_MSG(res.text.find("未做 base64 编码即拒绝") != std::string::npos,
		"应在拿到 base64 之前就拒绝（声明字节数那道判据），实际: " + res.text);
	TH_CHECK_MSG(res.text.find(std::to_string(raw)) != std::string::npos,
		"报错应点名驱动声明的原始字节数，实际: " + res.text);
	robot.deactivate();
}

/* 声明缺失/偏低时的兜底：驱动不报 bytes，base64 长度这道仍要拦住 */
TH_TEST(agenttools_capture_image_falls_back_to_base64_length_when_undeclared) {
	ModulePathGuard guard("./modules:test/cpp");
	/* 原始字节数刚好越过 2 MiB base64 上限折算出的 1572864 字节（+3 即多一组），
	 * 由夹具合成的假图给出；base64 长度按 4/3 上取整精确可算 */
	const std::size_t raw = kMaxImageBase64Bytes / 4 * 3 + 3;
	const std::size_t b64Len = (raw + 2) / 3 * 4;
	TempDir tmp("nobytes");
	const fs::path sqlFile = tmp.path() / "cam.sql";
	writeFile(sqlFile,
		"CREATE TABLE AgentFakeCamera (name String, raw_bytes String, omit_bytes String);\n"
		"INSERT INTO AgentFakeCamera (name, raw_bytes, omit_bytes) "
		"VALUES ('cam0', '" + std::to_string(raw) + "', 'yes');\n");

	MemoryReader reader(readAll(sqlFile.string()));
	RobotStruct robot(reader);
	robot.active();
	TH_CHECK(robot.registry().find("cam0") != nullptr);

	AgentToolContext ctx;
	ctx.robot = &robot;
	ctx.camera = robot.registry().find("cam0");
	AgentToolRegistry tools = makeAgentTools(ctx);
	const AgentToolResult res = tools.execute("capture_image", parseJson("{}"));

	TH_CHECK_MSG(res.imageDataUrl.empty(), "超限图不该产出图片 URL");
	TH_CHECK_MSG(res.text.find("图像过大") != std::string::npos, res.text);
	TH_CHECK_MSG(res.text.find(std::to_string(b64Len)) != std::string::npos,
		"兜底判据应点名实际 base64 字节数 " + std::to_string(b64Len) + "，实际: " + res.text);
	robot.deactivate();
}

TH_TEST(agenttools_capture_image_reports_device_failure) {
	/* 设备打不开时要把驱动的 ERR 折成文本回给模型（不崩会话、也不给假图片） */
	MemoryReader reader("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	RobotStruct robot(reader);
	robot.injectLuaDriver("Camera", "cam0");
	robot.active();

	AgentToolContext ctx;
	ctx.robot = &robot;
	ctx.camera = robot.registry().find("cam0");
	ctx.cameraDevice = "/dev/video999";
	AgentToolRegistry tools = makeAgentTools(ctx);

	AgentToolResult res = tools.execute("capture_image", parseJson("{}"));
	TH_CHECK(res.imageDataUrl.empty());
	TH_CHECK(res.text.find("工具执行失败") != std::string::npos);
	TH_CHECK(res.text.find("/dev/video999") != std::string::npos);

	robot.deactivate();
}

/* ---- #6（2026-09-25）：capture_image 可请求 width/height ----
 * schema 必须声明这两个可选整数参数（模型是照着描述传参的）；「同给同缺」、
 * 范围校验在触碰硬件之前（paramError 口径），回执按**实际协商尺寸**如实报告。 */
TH_TEST(agenttools_capture_image_schema_declares_size_params) {
	AgentToolContext ctx;
	ctx.robot = nullptr;
	ctx.camera = nullptr;
	AgentToolRegistry tools = makeAgentTools(ctx);
	TH_CHECK(!tools.contains("capture_image"));	/* 无摄像头不注册（既有口径） */

	MemoryReader reader("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	RobotStruct robot(reader);
	robot.injectLuaDriver("Camera", "cam0");
	robot.active();
	AgentToolContext ctx2;
	ctx2.robot = &robot;
	ctx2.camera = robot.registry().find("cam0");
	AgentToolRegistry tools2 = makeAgentTools(ctx2);

	std::string desc, params;
	for (const ToolSpec& s : tools2.specs()) {
		if (s.name == "capture_image") { desc = s.description; params = s.parameters.toString(); }
	}
	TH_CHECK_MSG(!params.empty(), "capture_image 应已注册");
	TH_CHECK_MSG(params.find("\"width\"") != std::string::npos, params);
	TH_CHECK_MSG(params.find("\"height\"") != std::string::npos, params);
	TH_CHECK_MSG(params.find("\"required\":[]") != std::string::npos,
		"width/height 是可选的，required 必须为空: " + params);
	TH_CHECK_MSG(desc.find("640x480") != std::string::npos, desc);

	robot.deactivate();
}

namespace {

/* 用 AgentFakeCamera 当摄像头的夹具（fixed_size 配成「设备调档后的尺寸」）。
 * 按声明序析构：registry（值，随函数退出）→ ctx → robot（值）→ reader（值）
 * → guard → tmp，任意时刻工具上下文持有的都是活对象。 */
struct FakeCamRig {
	TempDir tmp;
	ModulePathGuard guard;
	std::string sqlText;
	MemoryReader reader;
	RobotStruct robot;
	AgentToolContext ctx;
	AgentToolRegistry tools;

	FakeCamRig(const std::string& tag, const std::string& fixedSize)
		: tmp("cam6_" + tag), guard("./modules:test/cpp"),
		  sqlText("CREATE TABLE AgentFakeCamera (name String, raw_bytes String, omit_bytes String,"
			" fixed_size String);\n"
			"INSERT INTO AgentFakeCamera (name, raw_bytes, omit_bytes, fixed_size) "
			"VALUES ('cam0', '32', 'no', '" + fixedSize + "');\n"),
		  reader(sqlText), robot(reader), ctx(), tools() {
		/* 与 litcap 夹具同法：结构脚本声明 AgentFakeCamera 表即可解析到假驱动，
		 * 不能再 injectLuaDriver（会与表内同名变量撞「Duplicate hardware variable」） */
		robot.active();
		ctx.robot = &robot;
		ctx.camera = robot.registry().find("cam0");
		tools = makeAgentTools(ctx);
	}
};

} // namespace

TH_TEST(agenttools_capture_image_size_param_errors) {
	FakeCamRig rig("param", "");
	auto bad = [&](const std::string& args, const std::string& needle) {
		const AgentToolResult r = rig.tools.execute("capture_image", parseJson(args));
		TH_CHECK_MSG(!r.ok && r.paramError, args + " → " + r.text);
		TH_CHECK_MSG(r.imageDataUrl.empty(), "参数错误不该产出图片");
		TH_CHECK_MSG(r.error.find(needle) != std::string::npos, args + " → " + r.error);
	};
	bad("{\"width\":320}", "同时给出");
	bad("{\"height\":240}", "同时给出");
	bad("{\"width\":0,\"height\":240}", "width/height 须在");
	bad("{\"width\":15,\"height\":240}", "width/height 须在");
	bad("{\"width\":320,\"height\":9000}", "width/height 须在");
	bad("{\"width\":\"abc\",\"height\":240}", "整数");
}

TH_TEST(agenttools_capture_image_reports_negotiated_size) {
	/* 请求 300x200，假设备「就近调档」成 320x240：回执必须报告**实际**值并说明调档 */
	FakeCamRig rig("nego", "320x240");

	const AgentToolResult res = rig.tools.execute("capture_image",
		parseJson("{\"width\":300,\"height\":200}"));
	TH_CHECK_MSG(res.ok, res.text);
	TH_CHECK_MSG(res.text.find("（320x240）") != std::string::npos, res.text);
	TH_CHECK_MSG(res.text.find("请求 300x200 被设备就近调档为 320x240") != std::string::npos,
		res.text);
	TH_CHECK(res.imageDataUrl.rfind("data:image/jpeg;base64,", 0) == 0);

	/* 请求与协商一致时不出现调档说明 */
	const AgentToolResult exact = rig.tools.execute("capture_image",
		parseJson("{\"width\":320,\"height\":240}"));
	TH_CHECK_MSG(exact.ok, exact.text);
	TH_CHECK_MSG(exact.text.find("（320x240）") != std::string::npos, exact.text);
	TH_CHECK_MSG(exact.text.find("调档") == std::string::npos, exact.text);
}

/* 仿真来源不缩放图片：请求的尺寸必须被如实标注为「无效」，而不是假装生效 */
TH_TEST(agenttools_capture_image_sim_source_ignores_requested_size) {
	TempDir tmp("cam6sim");
	fs::path pic = tmp.path() / "pic.jpg";
	writeFile(pic, std::string("\xff\xd8\xff", 3) + "foobar");

	MemoryReader reader("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	RobotStruct robot(reader);
	robot.injectLuaDriver("Camera", "cam0");
	robot.active();

	AgentToolContext ctx;
	ctx.robot = &robot;
	ctx.camera = robot.registry().find("cam0");
	ctx.cameraSrc = pic.string();
	ctx.cameraSrcFromCli = true;
	AgentToolRegistry tools = makeAgentTools(ctx);

	const AgentToolResult res = tools.execute("capture_image",
		parseJson("{\"width\":128,\"height\":96}"));
	TH_CHECK_MSG(res.ok, res.text);
	TH_CHECK_MSG(res.text.find("128x96") != std::string::npos, res.text);
	TH_CHECK_MSG(res.text.find("对模拟图片无效") != std::string::npos, res.text);
	TH_CHECK(res.imageDataUrl.rfind("data:image/jpeg;base64,", 0) == 0);

	robot.deactivate();
}

/* H1：白名单根**不得**由 src 自己推导。
 * 旧实现无条件把 canonical(src).parent_path() 当 src_root —— 而 src 的所在目录
 * 当然包含 src，判据**恒真**，白名单形同不存在：一份落在 CWD 的 ./mybot.llm.json
 * 写 camera_src=/etc/shadow 就能把它 base64 读进模型上下文（allow_camera 缺省为真、
 * cam0 自动注入，**不需要 --agent-shell**），再由同一份配置可控的 endpoint 外发。
 * 现在的口径：显式根（--camera-src-dir）优先；否则只有**命令行来源**的 src 才推导
 * 所在目录；配置文件来源不推导，交由驱动默认拒绝。 */
TH_TEST(agenttools_capture_image_whitelist_root_is_not_derived_from_config_src) {
	TempDir tmp("cam_h1");
	fs::path pic = tmp.path() / "pic.jpg";
	/* 真 JPEG 头（FF D8 FF）：AG-9 之后宿主会拿魔数与驱动声明的 format 交叉校验 */
	writeFile(pic, std::string("\xff\xd8\xff", 3) + "foobar");
	TempDir elsewhere("cam_h1_elsewhere");

	MemoryReader reader("CREATE TABLE Timer (name String);\n"
		"INSERT INTO Timer (name) VALUES ('t0');\n");
	RobotStruct robot(reader);
	robot.injectLuaDriver("Camera", "cam0");
	robot.active();

	auto shoot = [&](bool fromCli, const std::string& root) {
		AgentToolContext ctx;
		ctx.robot = &robot;
		ctx.camera = robot.registry().find("cam0");
		ctx.cameraSrc = pic.string();
		ctx.cameraSrcFromCli = fromCli;
		ctx.cameraSrcRoot = root;
		AgentToolRegistry tools = makeAgentTools(ctx);
		return tools.execute("capture_image", parseJson("{}"));
	};

	/* ① 配置文件来源 + 无显式根 ⇒ 驱动默认拒绝，且**不得**产出图片
	 *    （这一条就是 H1 的攻击面：修复前它恒真放行） */
	{
		const AgentToolResult res = shoot(/*fromCli=*/false, /*root=*/"");
		TH_CHECK_MSG(res.imageDataUrl.empty(), "配置来源的 src 不该被放行（H1）");
		TH_CHECK_MSG(res.text.find("未放行") != std::string::npos,
			"应给出驱动侧的默认拒绝文案，实际: " + res.text);
	}
	/* ② 同一份 src，命令行来源 ⇒ 以其所在目录为根，照常工作（快速上手路径不破） */
	{
		const AgentToolResult res = shoot(/*fromCli=*/true, /*root=*/"");
		TH_CHECK_MSG(res.text.find("已拍摄照片") != std::string::npos,
			"命令行来源应照常拍照，实际: " + res.text);
		TH_CHECK(res.imageDataUrl.rfind("data:image/jpeg;base64,", 0) == 0);
	}
	/* ③ 显式根指到别处 ⇒ 即使 src 来自命令行也拒绝（显式根优先于推导） */
	{
		const AgentToolResult res = shoot(/*fromCli=*/true, elsewhere.path().string());
		TH_CHECK_MSG(res.imageDataUrl.empty(), "根指到别处时不该放行");
		TH_CHECK_MSG(res.text.find("超出允许目录") != std::string::npos,
			"应说明超出白名单，实际: " + res.text);
	}
	/* ④ 显式根 == src 所在目录 ⇒ 放行（配置文件来源也能用，因为根是命令行给的） */
	{
		const AgentToolResult res = shoot(/*fromCli=*/false, tmp.path().string());
		TH_CHECK_MSG(res.text.find("已拍摄照片") != std::string::npos,
			"显式根覆盖了来源限制，实际: " + res.text);
	}

	robot.deactivate();
}

TH_TEST(agenttools_no_camera_means_no_tool) {
	AgentToolContext ctx;
	ctx.robot = nullptr;
	ctx.allowShell = false;
	ctx.camera = nullptr;
	AgentToolRegistry tools = makeAgentTools(ctx);
	TH_CHECK(!tools.contains("capture_image"));
}
