/* test_wsproto.cpp —— RFC 6455 协议层单测（#24 Web SSH MVP） */

#include "harness.hpp"

#include <string>
#include <vector>

#include "wsproto.hpp"

using bot::ws::Decoder;
using bot::ws::DecodeError;
using bot::ws::Frame;
using bot::ws::base64Encode;
using bot::ws::encodeFrame;
using bot::ws::handshakeAccept;
using bot::ws::parseHandshake;
using bot::ws::upgradeResponse;
using bot::ws::sha1;

static std::string hex(const std::string& s) {
	static const char* d = "0123456789abcdef";
	std::string h;
	for (unsigned char c : s) { h += d[c >> 4]; h += d[c & 15]; }
	return h;
}

TH_TEST(ws_sha1_rfc3174_abc_vector) {
	TH_CHECK(hex(sha1("abc")) == "a9993e364706816aba3e25717850c26c9cd0d89d");
}

TH_TEST(ws_sha1_empty_vector) {
	TH_CHECK(hex(sha1("")) == "da39a3ee5e6b4b0d3255bfef95601890afd80709");
}

TH_TEST(ws_base64_vectors) {
	TH_CHECK(base64Encode("") == "");
	TH_CHECK(base64Encode("f") == "Zg==");
	TH_CHECK(base64Encode("fo") == "Zm8=");
	TH_CHECK(base64Encode("foo") == "Zm9v");
	TH_CHECK(base64Encode("foob") == "Zm9vYg==");
	TH_CHECK(base64Encode("fooba") == "Zm9vYmE=");
	TH_CHECK(base64Encode("foobar") == "Zm9vYmFy");
}

TH_TEST(ws_handshake_accept_rfc6455_example) {
	/* RFC 6455 §1.3 握手示例 */
	TH_CHECK(handshakeAccept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}

TH_TEST(ws_encode_small_text_frame) {
	std::string f = encodeFrame(bot::ws::OP_TEXT, "hello");
	TH_CHECK((uint8_t)f[0] == 0x81);	/* FIN + text */
	TH_CHECK((uint8_t)f[1] == 5);
	TH_CHECK(f.substr(2) == "hello");
}

TH_TEST(ws_encode_126_length_uses_16bit) {
	std::string payload(200, 'x');
	std::string f = encodeFrame(bot::ws::OP_BINARY, payload);
	TH_CHECK((uint8_t)f[0] == 0x82);
	TH_CHECK((uint8_t)f[1] == 126);
	TH_CHECK(((uint8_t)f[2] << 8 | (uint8_t)f[3]) == 200);
	TH_CHECK(f.size() == 4 + 200);
}

TH_TEST(ws_decode_masked_text_frame) {
	/* 客户端帧：FIN+text(0x81)，MASK=1 len=5，mask=0x37fa213d，
	 * payload "hello" ^ mask 逐字节 */
	std::string wire;
	wire += (char)0x81; wire += (char)0x85;
	wire += (char)0x37; wire += (char)0xfa; wire += (char)0x21; wire += (char)0x3d;
	wire += (char)('h' ^ 0x37); wire += (char)('e' ^ 0xfa); wire += (char)('l' ^ 0x21);
	wire += (char)('l' ^ 0x3d); wire += (char)('o' ^ 0x37);
	Decoder d;
	DecodeError e = d.feed((const uint8_t*)wire.data(), wire.size());
	TH_CHECK(e == DecodeError::None);
	TH_CHECK(d.messages().size() == 1);
	TH_CHECK(d.messages()[0].opcode == bot::ws::OP_TEXT);
	TH_CHECK(d.messages()[0].payload == "hello");
}

TH_TEST(ws_decode_rejects_unmasked_client_frame) {
	std::string wire;
	wire += (char)0x81; wire += (char)0x02; wire += 'a'; wire += 'b';
	Decoder d;
	TH_CHECK(d.feed((const uint8_t*)wire.data(), wire.size()) == DecodeError::NotMasked);
}

TH_TEST(ws_decode_rejects_bad_opcode) {
	std::string wire;
	wire += (char)0x83; wire += (char)0x80;		/* opcode 3 非法 */
	wire += (char)0; wire += (char)0; wire += (char)0; wire += (char)0;	/* mask */
	Decoder d;
	TH_CHECK(d.feed((const uint8_t*)wire.data(), wire.size()) == DecodeError::BadOpcode);
}

TH_TEST(ws_decode_rejects_rsv_bits) {
	std::string wire;
	wire += (char)0xC1; wire += (char)0x80;		/* RSV1 置位 */
	wire += (char)0; wire += (char)0; wire += (char)0; wire += (char)0;
	Decoder d;
	TH_CHECK(d.feed((const uint8_t*)wire.data(), wire.size()) == DecodeError::BadReserved);
}

TH_TEST(ws_decode_rejects_control_frame_too_big) {
	/* ping(len=126) —— 控制帧载荷必须 ≤125 */
	std::string wire;
	wire += (char)0x89; wire += (char)0xFE;		/* ping + len=126 */
	wire += (char)0x00; wire += (char)0x7E;
	wire += (char)0; wire += (char)0; wire += (char)0; wire += (char)0;
	Decoder d;
	TH_CHECK(d.feed((const uint8_t*)wire.data(), wire.size()) == DecodeError::ControlTooBig);
}

TH_TEST(ws_decode_rejects_fragmented_control) {
	std::string wire;
	wire += (char)0x09; wire += (char)0x80;		/* ping FIN=0 */
	wire += (char)0; wire += (char)0; wire += (char)0; wire += (char)0;
	Decoder d;
	TH_CHECK(d.feed((const uint8_t*)wire.data(), wire.size()) == DecodeError::FragmentedControl);
}

TH_TEST(ws_decode_fragmented_text_reassembles) {
	std::string w1;
	w1 += (char)0x01; w1 += (char)0x82;		/* text FIN=0 len=2 */
	w1 += (char)1; w1 += (char)2; w1 += (char)3; w1 += (char)4;
	w1 += (char)('h' ^ 1); w1 += (char)('e' ^ 2);
	std::string w2;
	w2 += (char)0x80; w2 += (char)0x83;		/* cont FIN=1 len=3 */
	w2 += (char)5; w2 += (char)6; w2 += (char)7; w2 += (char)8;
	w2 += (char)('l' ^ 5); w2 += (char)('l' ^ 6); w2 += (char)('o' ^ 7);
	Decoder d;
	/* 分片首帧：完整处理但无产出（分片未完成）→ 按「等待输入」上报 NeedMore；
	 * 不能断言 None——None 只承诺「有产出」（见 wsproto.hpp 的语义注释） */
	TH_CHECK(d.feed((const uint8_t*)w1.data(), w1.size()) == DecodeError::NeedMore);
	TH_CHECK(d.messages().empty());			/* 分片未完成无产出 */
	TH_CHECK(d.feed((const uint8_t*)w2.data(), w2.size()) == DecodeError::None);
	TH_CHECK(d.messages().size() == 1);
	TH_CHECK(d.messages()[0].payload == "hello");
}

TH_TEST(ws_decode_rejects_orphan_continuation) {
	std::string wire;
	wire += (char)0x80; wire += (char)0x80;		/* cont FIN=1 len=0 */
	wire += (char)0; wire += (char)0; wire += (char)0; wire += (char)0;
	Decoder d;
	TH_CHECK(d.feed((const uint8_t*)wire.data(), wire.size()) == DecodeError::UnexpectedCont);
}

TH_TEST(ws_decode_rejects_message_over_64k) {
	/* 单帧 65537 字节 > 64KiB 上限：len=127 */
	std::string wire;
	wire += (char)0x81; wire += (char)0xFF;		/* FIN+text, MASK+len=127 */
	uint64_t big = bot::ws::kMaxMessageBytes + 1;
	for (int i = 7; i >= 0; --i) wire += (char)((big >> (i * 8)) & 0xFF);
	wire += (char)0; wire += (char)0; wire += (char)0; wire += (char)0;	/* mask */
	Decoder d;
	TH_CHECK(d.feed((const uint8_t*)wire.data(), wire.size()) == DecodeError::TooLong);
}

TH_TEST(ws_decode_multiple_frames_in_one_feed) {
	std::string wire;
	wire += encodeFrame(bot::ws::OP_PING, "pi");	/* 服务端编码（未掩码）——直接构造客户端等价帧 */
	/* 手搓两个掩码 text 帧 */
	std::string f1;
	f1 += (char)0x81; f1 += (char)0x81; f1 += (char)1; f1 += (char)1; f1 += (char)1; f1 += (char)1;
	f1 += (char)('a' ^ 1);
	std::string f2;
	f2 += (char)0x81; f2 += (char)0x81; f2 += (char)2; f2 += (char)2; f2 += (char)2; f2 += (char)2;
	f2 += (char)('b' ^ 2);
	Decoder d;
	TH_CHECK(d.feed((const uint8_t*)f1.data(), f1.size()) == DecodeError::None);
	TH_CHECK(d.messages().size() == 1 && d.messages()[0].payload == "a");
	TH_CHECK(d.feed((const uint8_t*)f2.data(), f2.size()) == DecodeError::None);
	TH_CHECK(d.messages().size() == 1 && d.messages()[0].payload == "b");
}

TH_TEST(ws_handshake_accepts_valid_upgrade) {
	std::string req =
		"GET /ws/term?token=secret HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Upgrade: websocket\r\n"
		"Connection: keep-alive, Upgrade\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"\r\n";
	auto r = parseHandshake(req);
	TH_CHECK(r.ok);
	TH_CHECK(r.path == "/ws/term");
	TH_CHECK(r.token == "secret");
	/* 完整 101 响应含 RFC 示例 accept */
	TH_CHECK(upgradeResponse(r.reason).find("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != std::string::npos);
}

TH_TEST(ws_handshake_rejects_non_get) {
	std::string req =
		"POST /ws/term HTTP/1.1\r\n"
		"Upgrade: websocket\r\n"
		"Connection: Upgrade\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"\r\n";
	auto r = parseHandshake(req);
	TH_CHECK(!r.ok);
	TH_CHECK(r.reason == "method not GET");
}

TH_TEST(ws_handshake_rejects_missing_upgrade_headers) {
	std::string req =
		"GET /ws/term HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n";
	auto r = parseHandshake(req);
	TH_CHECK(!r.ok);
	TH_CHECK(r.reason == "not a websocket upgrade");
}

TH_TEST(ws_handshake_case_insensitive_headers) {
	std::string req =
		"GET / HTTP/1.1\r\n"
		"UPGRADE: WebSocket\r\n"
		"CoNnEcTiOn: UpGrAdE\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"\r\n";
	auto r = parseHandshake(req);
	TH_CHECK(r.ok);
}

TH_TEST(ws_handshake_rejects_old_version) {
	std::string req =
		"GET / HTTP/1.1\r\n"
		"Upgrade: websocket\r\n"
		"Connection: Upgrade\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Sec-WebSocket-Version: 8\r\n"
		"\r\n";
	auto r = parseHandshake(req);
	TH_CHECK(!r.ok);
	TH_CHECK(r.reason == "unsupported websocket version");
}

TH_TEST(ws_handshake_incomplete_headers) {
	auto r = parseHandshake("GET / HTTP/1.1\r\nUpgrade: websocket");
	TH_CHECK(!r.ok);
	TH_CHECK(r.reason == "incomplete headers");
}
