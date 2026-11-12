/* agentimage.cpp —— capture_image 的摄像头/图像簇（拆自 agenttools.cpp，
 * 2026-09-25 B3）：图片格式魔数嗅探（与 modules/lib/mjpeg_frame.lua 的
 * SUPPORTED_FORMATS 同集合）、体积两道判据（AG-19）、data URL MIME 交叉校验
 * （AG-9）、模拟图片来源目录解析（H1）与 capture_image 工具本体。摄像头是
 * 宿主里唯一搬运 MiB 级字符串的地方，判据自成一体，独立成 TU 后注释面聚焦；
 * 装配经 agenttools_internal.hpp 的 makeCaptureImageTool 接进 makeAgentTools
 * （能力门控：ctx.camera 非空才注册）。 */

#include "agenttools_internal.hpp"

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <string>
#include <limits>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <unistd.h>

#include "robot.hpp"

namespace bot {
namespace agent {

namespace fs = std::filesystem;

/* H1：把「模拟图片来源」解析成它所在的目录。**只有命令行来源的 src 才走这里**
 * （理由见 makeCaptureImageTool 里的注释与 AgentToolContext）。
 * canonical 展开软链与相对段，与驱动侧 realpath 判据一致；路径尚不存在时退一步
 * weakly_canonical 解析到最深的已存在父目录，好让驱动报「打不开」而不是「未放行」。
 * 两步都解析不出绝对路径时**不回落成 "."**——那等于放行整个当前工作目录，
 * 比本意宽得多；这条判据是边界，宁可拒绝也不猜。 */
std::string simSrcParentDir(const std::string& src) {
	std::error_code ec;
	fs::path real = fs::canonical(src, ec);
	if (ec) { real = fs::weakly_canonical(src, ec); }
	/* parent_path() 只在「有根路径却无根目录」的相对形态上抛 filesystem_error，
	 * 绝对路径不会——所以先判绝对再取父目录。 */
	fs::path parent = real.is_absolute() ? real.parent_path() : fs::path();
	if (ec || !parent.is_absolute()) {
		throw IllegalArgumentException("无法解析模拟图片来源所在目录: " + src);
	}
	return parent.string();
}

/* ---- 图片 data URL 的 MIME（AG-9 单点）----
 * 规则：**以驱动声明的 format 为准**，再用 base64 前几字节做一次自洽交叉校验。
 * 为什么两道：
 *   ① 只信 format → 驱动写错（或第三方驱动硬编码）就会发错标签，正是本缺陷的成因；
 *   ② 只信魔数 → 宿主就得自带一份格式表，与驱动的判据重复且必然漂移。
 * 所以宿主采用驱动的声明，同时对「声明与内容不符」fail-closed——那说明驱动有
 * bug，此时报错比把错标签发出去好（网关的 400 只会说「图片解析错误」）。
 * 支持的四种与 modules/lib/mjpeg_frame.lua 的 SUPPORTED_FORMATS 同集合。 */
std::string sniffImageFormat(const std::string& b64) {
	/* 判据最多需要前 12 字节；**能解多少解多少**——把最小长度写成 16 会把
	 * 合法的小图（9 字节 JPEG 编码后只有 12 个 base64 字符）误判成「不是图片」，
	 * 实测就是这么红的。每条魔数判据自己会检查 head 够不够长。 */
	if (b64.size() < 4) { return ""; }
	/* base64 值表查值：256 查表代替 strchr 逐字符线性扫（判据只解前 16 字节，
	 * 这里图的是写法直接、量级明确，不指望热点收益）。 */
	static constexpr int kVal[256] = {
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 62, -1, -1, -1, 63,
		52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, -1, -1, -1, -1, -1,
		-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
		15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1, -1, -1,
		-1, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
		41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
		-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
	};
	auto val = [](char c) -> int {
		return kVal[static_cast<unsigned char>(c)];
	};
	std::string head;
	const std::size_t limit = std::min<std::size_t>(16, b64.size());
	for (std::size_t i = 0; i + 3 < limit; i += 4) {
		const int a = val(b64[i]), b = val(b64[i + 1]), c = val(b64[i + 2]), d = val(b64[i + 3]);
		if (a < 0 || b < 0 || c < 0 || d < 0) { return ""; }
		head.push_back(static_cast<char>((a << 2) | (b >> 4)));
		head.push_back(static_cast<char>(((b & 0x0f) << 4) | (c >> 2)));
		head.push_back(static_cast<char>(((c & 0x03) << 6) | d));
	}
	const auto startsWith = [&head](const char* pfx, std::size_t n) {
		return head.size() >= n && head.compare(0, n, pfx, n) == 0;
	};
	if (head.size() >= 3 && static_cast<unsigned char>(head[0]) == 0xff
		&& static_cast<unsigned char>(head[1]) == 0xd8
		&& static_cast<unsigned char>(head[2]) == 0xff) {
		return "jpeg";
	}
	if (startsWith("\x89PNG\r\n\x1a\n", 8)) { return "png"; }
	if (startsWith("GIF87a", 6) || startsWith("GIF89a", 6)) { return "gif"; }
	if (startsWith("RIFF", 4) && head.size() >= 12 && head.compare(8, 4, "WEBP") == 0) {
		return "webp";
	}
	return "";
}

/* ---- 图片体积上限的两道判据（2026-09-21 第三轮审计 AG-19）----
 * `capture_image` 是宿主里唯一会搬运 MiB 级字符串的地方，而它此前把
 * 2 MiB 判据放在**拿到 base64 之后**：驱动仿真上限 16 MiB（base64 约 21 MB）
 * 意味着「一张注定被拒的图」要先走完 base64 编码、跨 Json/Lua 边界，
 * 再被拒——实测 10 MiB 的图让进程峰值到 219 MiB（见 .tmp/memaudit/）。
 * 现在按驱动已经给出的原始字节数**先判**，编码/跨界的代价直接省掉。
 *
 * 两道都要留：① 声明是不可信输入（驱动的 `bytes` 可能漏填或算错）；
 * ② 声明对不上时，base64 长度这道兜底必须命中。判据调用点因此**不允许**
 * 用 Json::getValue()——那个访问器按值返回整串，比一次长度就拷贝 2 MiB
 * （原实现 `b64->getValue().size() > kMaxImageBase64Bytes` 正是如此，
 * 同一段代码还另外拷了 5 次）。一律借用 Json 节点自己的 s。 */
std::string checkImageSize(const Json& res, std::size_t b64Bytes) {
	/* ① 原始字节数的声明（base64 = ceil(raw/3)*4 → raw 上限取 3/4 向下取整）*/
	if (const Json* raw = res.find("bytes"); raw != nullptr && raw->isInt()) {
		const long long declared = raw->getInt();
		const long long maxRaw = static_cast<long long>(kMaxImageBase64Bytes / 4) * 3;
		if (declared > maxRaw) {
			return "图像过大：" + std::to_string(declared) + " 字节原始数据，超过上限 "
				+ std::to_string(maxRaw) + " 字节（宿主按 base64 上限 "
				+ std::to_string(kMaxImageBase64Bytes)
				+ " 字节折算，未做 base64 编码即拒绝）；请降低分辨率或换小图"
				  "（大图会击穿会话历史预算）";
		}
	}
	/* ② base64 实际长度（声明缺失/偏低时的兜底；此时已编码，只能事后拒）*/
	if (b64Bytes > kMaxImageBase64Bytes) {
		return "图像过大：base64 " + std::to_string(b64Bytes) + " 字节，超过上限 "
			+ std::to_string(kMaxImageBase64Bytes)
			+ " 字节；请降低分辨率或换小图（大图会击穿会话历史预算）";
	}
	return "";
}

std::string dataUrlMimeFor(const Json& res, const std::string& b64) {
	auto fmt = res.get("format");
	if (!fmt || !fmt->isStr() || fmt->getValue().empty()) {
		throw std::runtime_error("摄像头驱动没有返回 format 字段（无法确定图片 MIME）");
	}
	const std::string declared = fmt->getValue();
	if (declared != "jpeg" && declared != "png" && declared != "gif" && declared != "webp") {
		throw std::runtime_error("摄像头驱动返回了不受支持的图片格式 '" + declared
			+ "'（仅支持 jpeg/png/gif/webp）");
	}
	const std::string actual = sniffImageFormat(b64);
	if (actual.empty()) {
		throw std::runtime_error("图片内容不是受支持的格式（JPEG/PNG/GIF/WebP 魔数都不匹配）");
	}
	if (actual != declared) {
		throw std::runtime_error("图片声明格式 '" + declared + "' 与内容实际格式 '"
			+ actual + "' 不符（驱动 bug；拒绝发出错标签的 data URL）");
	}
	/* 驱动给的是**格式名**（jpeg/png/…），data URL 要的是 **MIME**（image/…）：
	 * 两者在四个受支持格式上恰好一一对应（jpeg 的 MIME 是 image/jpeg，不是
	 * image/jpg），所以直接前缀 image/ 即可，不需要再维护一张映射表。 */
	return "image/" + declared;
}

/* ---- capture_image 辅助函数（阶段 1 拆分）---- */

/* #6（2026-09-25）：模型可请求的采集尺寸界。宿主是界值的**单点**（Lua 驱动只查
 * 「正整数」——界值若在两处各写一份必然漂移）。16 起：更小的请求没有实际意义且
 * 部分 UVC 设备在极小尺寸上行为怪；8192 封顶：MJPEG 设备的常见上限（UVC 规范
 * 最高 4K 一档附近），也让「请求 2^31 把 S_FMT 打穿」在进 V4L2 之前就被拒。 */
constexpr int kCaptureMinDim = 16;
constexpr int kCaptureMaxDim = 8192;

static Json buildCameraParams(const AgentToolContext& ctx, int reqW, int reqH) {
	Json params = JsonObject();
	/* 只在显式配置时才传 path/src：结构脚本若把同名列声明成元数据列，
	 * 再传同名参数会被 rejectReservedKeys 拒掉（结构脚本优先）。 */
	if (!ctx.cameraDevice.empty()) {
		params.put("path", JsonString(ctx.cameraDevice));
	}
	/* width/height 同样只在模型显式请求时传：缺省不传 → 驱动维持既有尺寸，
	 * 「没传」与「请求 640x480」在驱动侧是同一请求，不会白重开一次。 */
	if (reqW > 0) {
		params.put("width", JsonInt(reqW));
		params.put("height", JsonInt(reqH));
	}
	if (!ctx.cameraSrc.empty()) {
		params.put("src", JsonString(ctx.cameraSrc));
		/* H1：src_root（「允许读哪个目录」）与 src **解耦**。
		 * 旧实现无条件用 canonical(src).parent_path() 当根 —— src 的所在
		 * 目录当然包含 src，判据恒真，白名单形同不存在（一份落在 CWD 的
		 * ./mybot.llm.json 写 camera_src=/etc/shadow 即可把它读进模型上下文，
		 * 再经同一份配置可控的 endpoint 外发；allow_camera 缺省为真、
		 * cam0 自动注入，不需要 --agent-shell）。
		 * 现在：① 显式根（--camera-src-dir）优先；② 否则**只有命令行来源**
		 * 的 src 才推导所在目录（操作者自己指的文件，他本就能读，这也保住
		 * 了 --camera-src 的快速上手路径）；③ 配置文件来源不传 src_root，
		 * 交由驱动按 BOT4CJ_CAMERA_SRC_DIR 判定，都没有即「未放行」拒绝。
		 * 目录解析的判据（canonical/weakly_canonical、不回落成 "."）见
		 * simSrcParentDir。 */
		std::string root = ctx.cameraSrcRoot;
		if (root.empty() && ctx.cameraSrcFromCli) {
			root = simSrcParentDir(ctx.cameraSrc);
		}
		if (!root.empty()) { params.put("src_root", JsonString(root)); }
	}
	return params;
}

static void validateImageSize(const Json& res, std::size_t b64Size) {
	/* 体积判据（AG-19）：先用驱动声明的原始字节数判，再做 base64 编码；
	 * 声明对不上时由 base64 长度兜底。拒绝文案由 checkImageSize 单点产出。 */
	if (std::string sizeErr = checkImageSize(res, b64Size); !sizeErr.empty()) {
		throw std::runtime_error(sizeErr);
	}
}

/* 驱动返回的尺寸是 int64（Json）；描述只拼文本。越界值（驱动 bug）钳到 int 界，
 * 显式窄化顺带消掉 clang-tidy 的 bugprone-narrowing-conversions。 */
static int clampDimToInt(std::int64_t v) {
	return v > std::numeric_limits<int>::max() ? std::numeric_limits<int>::max()
		: (v < std::numeric_limits<int>::min() ? std::numeric_limits<int>::min()
			: static_cast<int>(v));
}

static std::string buildImageDescription(const Json& res, int reqW, int reqH) {
	std::string desc = "已拍摄照片";
	const Json* w = res.find("width");
	const Json* h = res.find("height");
	const bool haveActual = w && h && w->isInt() && h->isInt();
	const int actualW = haveActual ? clampDimToInt(w->getInt()) : 0;
	const int actualH = haveActual ? clampDimToInt(h->getInt()) : 0;
	/* 回执如实区分三种（2026-09-25 #6）：报告**实际**尺寸；请求与实际不符时
	 * 说明「设备就近调档」，模型据此知道想缩小画面要多试几档；仿真来源不缩放
	 * 图片，请求的尺寸无效必须明说，否则模型会以为已拿到小图。 */
	if (haveActual) {
		desc += "（" + std::to_string(actualW) + "x" + std::to_string(actualH) + "）";
		if (reqW > 0 && (reqW != actualW || reqH != actualH)) {
			desc += "，请求 " + std::to_string(reqW) + "x" + std::to_string(reqH)
				+ " 被设备就近调档为 " + std::to_string(actualW) + "x"
				+ std::to_string(actualH);
		}
	}
	auto bytes = res.get("bytes");
	if (bytes && bytes->isInt()) {
		desc += "，" + std::to_string(bytes->getInt()) + " 字节";
	}
	auto src = res.get("source");
	if (src && src->isStr() && src->getValue() == "file") {
		desc += "，来源：模拟图片（按文件原始尺寸，不缩放）";
		if (reqW > 0) {
			desc += "；请求的 " + std::to_string(reqW) + "x" + std::to_string(reqH)
				+ " 尺寸对模拟图片无效";
		}
	}
	return desc + "。画面已加入你的上下文。";
}

/* 查询仿真器测距仪（如果可用）。连接 MYBOT_SIM_SENSOR_SOCK，发 "range\n"，
 * 收 "OK <mm>\n" 或 "ERR <reason>\n"。返回空串表示测距仪不可用（仿真器没开或
 * 没设环境变量），调用方据此决定是否附加距离信息。
 *
 * 2026-10-10 评估后判不改（两问）：① 独立 I/O 域但不拆 TU——55 行、单调用方、
 * 文件静态，拆出去要为一个内部函数新增头与 CMake 条目，耦合不降；② 不补
 * quoteUntrusted 定界——输出经 "OK " 前缀 + strtol 全串解析 + %.2f 渲染，
 * 进模型的是严格数值文本，无注入面；desc 的其余输入是驱动返回值（操作者
 * 代码，与 describeHardware 同信任级）与白名单内模拟图（内容走 imageDataUrl
 * 不进文本）。quoteUntrusted 的适用对象是第三方可控数据（文件/网页/命令
 * 输出），这里没有那一层，补定界只给稳定回执加噪音。 */
static std::string querySimRange() {
	const char* envSock = std::getenv("MYBOT_SIM_SENSOR_SOCK");
	if (!envSock || !*envSock) { return ""; }
	std::string sockPath = envSock;

	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) { return ""; }

	struct sockaddr_un addr{};
	addr.sun_family = AF_UNIX;
	if (sockPath.size() >= sizeof(addr.sun_path)) {
		close(fd);
		return "";
	}
	std::copy(sockPath.begin(), sockPath.end(), addr.sun_path);
	addr.sun_path[sockPath.size()] = '\0';

	if (connect(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
		close(fd);
		return "";
	}

	const char* req = "range\n";
	if (send(fd, req, std::strlen(req), MSG_NOSIGNAL) < 0) {
		close(fd);
		return "";
	}

	/* 收一行（3 秒超时） */
	char buf[256];
	std::string line;
	struct pollfd pfd{};
	pfd.fd = fd;
	pfd.events = POLLIN;
	while (line.find('\n') == std::string::npos && line.size() < sizeof(buf) - 1) {
		int pr = poll(&pfd, 1, 3000);
		if (pr <= 0) { break; }
		ssize_t n = recv(fd, buf, 1, 0);
		if (n <= 0) { break; }
		if (buf[0] == '\n') { break; }
		line += buf[0];
	}
	close(fd);

	if (line.size() < 3 || line.substr(0, 3) != "OK ") { return ""; }
	std::string mmStr = line.substr(3);
	char* end = nullptr;
	long mm = std::strtol(mmStr.c_str(), &end, 10);
	if (!end || *end != '\0' || mm < 0) { return ""; }
	double meters = mm / 1000.0;
	char tmp[64];
	std::snprintf(tmp, sizeof(tmp), "%.2f", meters);
	return tmp;
}

AgentTool makeCaptureImageTool(const AgentToolContext& ctx) {
	return AgentTool{
		"capture_image",
		"拍摄一张机器人当前环境的照片，同时查询前方障碍物距离（如果测距仪可用）。"
		"图片会直接进入你的上下文，你能看到画面内容；测距数据会附加在描述里。"
		"任务涉及观察环境、寻找物体、判断前方是否有障碍时，先调用它再做结论。"
		"可选的 width/height（像素，须同时给出，" + std::to_string(kCaptureMinDim)
			+ ".." + std::to_string(kCaptureMaxDim)
			+ "）指定采集尺寸，缺省 640x480；换尺寸会重开设备，代价高于同尺寸连拍，"
			"故只在确实需要时给。模拟图片来源不缩放。",
		toolSchema({{"width", intParam("采集宽度（像素，"
				    + std::to_string(kCaptureMinDim) + ".."
				    + std::to_string(kCaptureMaxDim) + "，与 height 同时给出）")},
				{"height", intParam("采集高度（像素，"
				    + std::to_string(kCaptureMinDim) + ".."
				    + std::to_string(kCaptureMaxDim) + "，与 width 同时给出）")}},
			{}),
		[ctx](const Json& args) -> AgentToolResult {
			/* ---- 尺寸参数：全部校验在触碰硬件之前（错即 paramError）----
			 * fallback 取 -1 当「未给」哨兵：0 是**合法输入**（要被范围校验拒掉），
			 * 不能用 0 兼任哨兵，否则 width=0 会被误报成「必须同时给出」。
			 * 负数同理只可能是哨兵（optionalInt 已按 int 界收口）——给一半、
			 * 给 0、给越界分别走下面三条，互不掩盖。 */
			int reqW = optionalInt(args, "width", -1);
			int reqH = optionalInt(args, "height", -1);
			if ((reqW < 0) != (reqH < 0)) {
				throw IllegalArgumentException("参数 width 与 height 必须同时给出");
			}
			if (reqW >= 0 && (reqW < kCaptureMinDim || reqW > kCaptureMaxDim
					|| reqH < kCaptureMinDim || reqH > kCaptureMaxDim)) {
				throw IllegalArgumentException("参数 width/height 须在 "
					+ std::to_string(kCaptureMinDim) + ".."
					+ std::to_string(kCaptureMaxDim) + " 之间，实际 "
					+ std::to_string(reqW) + "x" + std::to_string(reqH));
			}

			Json params = buildCameraParams(ctx, reqW, reqH);
			Json res = ctx.camera->playQuiet(params);	/* ERR 契约在此抛出 */

			/* 借用而非拷贝（AG-19）：Json::getValue() 按值返回，一次拍照原本要
			 * 为同一串 base64 拷 6 次（本函数 5 处 + 体积判据 1 处）。拼完 data URL
			 * 后把节点里的 base64 挪走：回执只带 url，留着 b64 等于再占一份等大缓冲。 */
			Json* b64Node = res.getPtr("b64");
			if (b64Node == nullptr || !b64Node->isStr() || b64Node->s.empty()) {
				throw std::runtime_error("摄像头驱动没有返回图像数据（b64 为空）");
			}

			validateImageSize(res, b64Node->s.size());

			std::string desc = buildImageDescription(res, reqW, reqH);

			/* MIME 取自**驱动返回的格式**（2026-09-21 审计 AG-9），不再硬编码
			 * image/jpeg：仿真来源可以是 PNG/GIF/WebP，硬编码会把「JPEG 标签 +
			 * PNG 字节」发给网关，严格解析器直接 400。驱动侧已按魔数判定并对
			 * 不认识的格式响亮拒绝，这里只需原样采用并做一次自洽交叉校验。 */
			std::string mime = dataUrlMimeFor(res, b64Node->s);
			/* 单次 reserve 构造 data URL：链式 `+` 每步都分配新串并拷贝已有内容，
			 * 2MB base64 会产生三次分配、约 4MB 拷贝。reserve 一次到位后 append
			 * 只做一次 memcpy（前缀小、b64 是连续块）。拼完即清空节点，避免
			 * res 析构前与 url 同时持有同一份画面。 */
			const std::string prefix = "data:" + mime + ";base64,";
			std::string url;
			url.reserve(prefix.size() + b64Node->s.size());
			url.append(prefix);
			url.append(std::move(b64Node->s));
			b64Node->s.clear();

			/* 同时查询测距仪（仿真环境）。如果可用，把距离信息附加到描述里 */
			std::string range = querySimRange();
			if (!range.empty()) {
				desc += "\n\n【测距仪】前方障碍物距离：" + range + " 米";
			}

			return {desc, std::move(url)};
		}};
}

} // namespace agent
} // namespace bot
