#pragma once
/* wsproto.hpp —— RFC 6455 WebSocket **服务端**最小协议层（Web SSH 用，#24）
 *
 * 为什么自研：项目明示零第三方 C++ 依赖（同 jsonparse/sqlparse 的取舍），
 * WebSocket 服务端只需「HTTP Upgrade 握手 + 帧编解码」两块，RFC 6455 全文
 * 可对照实现，且协议面小、可离线单测（与解析器同惯例）。
 *
 * 安全契约（服务端视角，全部拒绝而非容错）：
 *   1) 握手只接受 GET + Upgrade: websocket + 合法 Sec-WebSocket-Key；
 *   2) 客户端帧**必须掩码**（RFC 6455 §5.1），未掩码直接 1002 关闭；
 *   3) RSV 非零 / 非法 opcode / 控制帧(close/ping/pong)载荷 >125 /
 *      消息累积超上限(64 KiB) 一律协议错误关闭；
 *   4) 分片：text/binary 支持 continuation 状态机，但单条消息累积上限
 *      64 KiB（拒绝而非截断，同 jsonparse 的字节上限取向）；控制帧不可分片；
 *   5) 未 UTF-8 校验（MVP 透传字节；UTF-8 校验属应用层，由终端会话按需做）。
 *
 * 帧格式（§5.2）：
 *   byte0 = FIN(7) RSV1-3(6..4) opcode(3..0)
 *   byte1 = MASK(7) len(6..0)   [len=126 → +2B 扩展；len=127 → +8B 扩展]
 *   [mask key 4B]  payload（客户端帧逐字节异或 mask key）
 *   opcode: 0=cont 1=text 2=binary 8=close 9=ping 10=pong
 *
 * 握手应答（§4.2.2）：
 *   Sec-WebSocket-Accept = Base64( SHA1( key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) )
 */

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace bot {
namespace ws {

/* ---------- SHA1（RFC 3174）---------- */
std::string sha1(const std::string& data);

/* ---------- Base64（RFC 4648 §4，标准字母表，含 padding）---------- */
std::string base64Encode(const std::string& data);

/* 握手接受值：输入客户端 Sec-WebSocket-Key（16 字节 base64 原文）。
 * 不校验 key 格式（长度 16 字节 base64 由握手解析侧负责）。 */
std::string handshakeAccept(const std::string& clientKey);

/* ---------- 帧 ---------- */
enum Opcode : uint8_t {
	OP_CONT = 0x0,
	OP_TEXT = 0x1,
	OP_BINARY = 0x2,
	OP_CLOSE = 0x8,
	OP_PING = 0x9,
	OP_PONG = 0xA,
};

struct Frame {
	bool fin = true;
	uint8_t opcode = OP_TEXT;
	std::string payload;
};

/* 解码错误码（§7.4.1 语义） */
enum class DecodeError {
	None,			/* 无错误 */
	NeedMore,		/* 输入不完整，等待后续字节（不是错误） */
	NotMasked,		/* 客户端帧未掩码（§5.1） */
	BadReserved,	/* RSV 非零 */
	BadOpcode,		/* 非法 opcode */
	ControlTooBig,	/* 控制帧载荷 >125（§5.5） */
	TooLong,		/* 单条消息累积 > 上限 */
	FragmentedControl,	/* 控制帧带 FIN=0 */
	UnexpectedCont,		/* 未在分片中的 continuation 帧 */
};

constexpr size_t kMaxMessageBytes = 64 * 1024;	/* 单条消息上限（拒绝而非截断） */

/* 服务端解码状态机：喂入从 socket 读到的字节，产出完整消息。
 * 用法：一次调 decode() 可产出 0..n 条消息（循环取 messages()）。 */
class Decoder {
public:
	/* 返回 None（有产出）或 NeedMore（等待输入）。错误码见 DecodeError。 */
	DecodeError feed(const uint8_t* data, size_t n);
	/* 上一次 feed 产出的消息（按序消费，每次 feed 后重置） */
	const std::vector<Frame>& messages() const { return msgs_; }
	/* 分片状态机内已累积的字节数（供上层观察上限行为） */
	size_t bufferedBytes() const { return frag_.size(); }

private:
	bool expect_(uint8_t byte, size_t& need);
	std::vector<Frame> msgs_;
	std::string frag_;		/* 分片累积 */
	int fragOpcode_ = -1;	/* -1 = 不在分片中 */
	bool inHeader_ = true;
	size_t need_ = 0;		/* 还差多少字节 */
	std::string buf_;		/* 输入缓冲 */
	size_t consumed_ = 0;
};

/* 服务端 → 客户端帧编码（不掩码，§5.1 仅客户端须掩码） */
std::string encodeFrame(uint8_t opcode, const std::string& payload, bool fin = true);

/* ---------- HTTP Upgrade 握手（服务端） ---------- */
struct HandshakeResult {
	bool ok = false;
	std::string reason;		/* 失败原因（写入 HTTP 400 响应体） */
	std::string path;		/* 请求路径 */
	std::string token;		/* query 里的 token（?token=...，未解码百分比） */
};

/* 解析一个完整 HTTP 请求头（以 \r\n\r\n 结束）。
 * 成功返回 ok=true（协议语义：方法/头齐全且 Upgrade 合法）。
 * 其余情况返回 reason（调用方回 400 文本）。 */
HandshakeResult parseHandshake(const std::string& request);
/* 生成 101 响应（含 Sec-WebSocket-Accept） */
std::string upgradeResponse(const std::string& clientKey);

} /* namespace ws */
} /* namespace bot */
