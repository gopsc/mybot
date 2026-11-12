/* wsproto.cpp —— RFC 6455 WebSocket 服务端协议层实现（见 wsproto.hpp 契约） */

#include "wsproto.hpp"

#include <cstdio>
#include <cstring>

namespace bot {
namespace ws {

/* ================= SHA1（RFC 3174） ================= */
namespace {

inline uint32_t rotl(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

} /* namespace */

std::string sha1(const std::string& data) {
	/* 补位：0x80 + 0* 到长度 ≡ 56 mod 64，再补 64 位大端比特长度 */
	std::string m = data;
	uint64_t bitLen = (uint64_t)data.size() * 8;
	m += '\x80';
	while (m.size() % 64 != 56) m += '\0';
	for (int i = 7; i >= 0; --i) m += (char)((bitLen >> (i * 8)) & 0xFF);

	uint32_t h[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
	for (size_t off = 0; off < m.size(); off += 64) {
		uint32_t w[80];
		for (int i = 0; i < 16; ++i) {
			w[i] = ((uint8_t)m[off + i * 4] << 24) | ((uint8_t)m[off + i * 4 + 1] << 16) |
			       ((uint8_t)m[off + i * 4 + 2] << 8) | (uint8_t)m[off + i * 4 + 3];
		}
		for (int i = 16; i < 80; ++i) w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);

		uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
		for (int i = 0; i < 80; ++i) {
			uint32_t f, k;
			if (i < 20)       { f = (b & c) | (~b & d);       k = 0x5A827999; }
			else if (i < 40)  { f = b ^ c ^ d;                k = 0x6ED9EBA1; }
			else if (i < 60)  { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
			else              { f = b ^ c ^ d;                k = 0xCA62C1D6; }
			uint32_t tmp = rotl(a, 5) + f + e + k + w[i];
			e = d; d = c; c = rotl(b, 30); b = a; a = tmp;
		}
		h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
	}

	std::string out(20, '\0');
	for (int i = 0; i < 5; ++i) {
		out[i * 4] = (char)((h[i] >> 24) & 0xFF);
		out[i * 4 + 1] = (char)((h[i] >> 16) & 0xFF);
		out[i * 4 + 2] = (char)((h[i] >> 8) & 0xFF);
		out[i * 4 + 3] = (char)(h[i] & 0xFF);
	}
	return out;
}

/* ================= Base64（RFC 4648） ================= */
std::string base64Encode(const std::string& data) {
	static const char* tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	std::string out;
	out.reserve((data.size() + 2) / 3 * 4);
	for (size_t i = 0; i < data.size(); i += 3) {
		uint32_t v = (uint8_t)data[i] << 16;
		if (i + 1 < data.size()) v |= (uint8_t)data[i + 1] << 8;
		if (i + 2 < data.size()) v |= (uint8_t)data[i + 2];
		out += tbl[(v >> 18) & 63];
		out += tbl[(v >> 12) & 63];
		out += (i + 1 < data.size()) ? tbl[(v >> 6) & 63] : '=';
		out += (i + 2 < data.size()) ? tbl[v & 63] : '=';
	}
	return out;
}

/* ================= 握手 ================= */
std::string handshakeAccept(const std::string& clientKey) {
	return base64Encode(sha1(clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
}

/* ================= 帧解码 ================= */
DecodeError Decoder::feed(const uint8_t* data, size_t n) {
	msgs_.clear();
	buf_.append((const char*)data, n);
	consumed_ = 0;

	/* 帧处理主体包在 lambda 里：任何 return 之后统一把已消费字节从 buf_
	 * 头部移除（否则 buf_ 只增不减、且下次 feed 会重新解析旧字节——分片
	 * 状态机将因「重复帧」误报 BadOpcode，实测复现 Segfault）。 */
	DecodeError result = [&]() -> DecodeError {
	while (true) {
		if (inHeader_) {
			if (buf_.size() - consumed_ < 2) return DecodeError::NeedMore;
			uint8_t b0 = (uint8_t)buf_[consumed_];
			uint8_t b1 = (uint8_t)buf_[consumed_ + 1];
			bool fin = (b0 & 0x80) != 0;
			uint8_t rsv = (b0 >> 4) & 0x7;
			uint8_t op = b0 & 0x0F;
			bool masked = (b1 & 0x80) != 0;
			uint64_t len = b1 & 0x7F;

			if (rsv != 0) return DecodeError::BadReserved;
			switch (op) {
				case OP_CONT: case OP_TEXT: case OP_BINARY:
				case OP_CLOSE: case OP_PING: case OP_PONG:
					break;
				default:
					return DecodeError::BadOpcode;
			}
			bool isCtrl = (op & 0x08) != 0;
			if (isCtrl && !fin) return DecodeError::FragmentedControl;
			if (isCtrl && len > 125) return DecodeError::ControlTooBig;
			if (!masked) return DecodeError::NotMasked;

			size_t pos = consumed_ + 2;
			if (len == 126) {
				if (buf_.size() - pos < 2) return DecodeError::NeedMore;
				len = ((uint8_t)buf_[pos] << 8) | (uint8_t)buf_[pos + 1];
				pos += 2;
			} else if (len == 127) {
				if (buf_.size() - pos < 8) return DecodeError::NeedMore;
				len = 0;
				for (int i = 0; i < 8; ++i) len = (len << 8) | (uint8_t)buf_[pos + i];
				pos += 8;
				if (len & (1ULL << 63)) return DecodeError::TooLong;	/* MSB 必须为 0（§5.2） */
			}
			if (buf_.size() - pos < 4) return DecodeError::NeedMore;
			uint8_t maskKey[4];
			memcpy(maskKey, buf_.data() + pos, 4);
			pos += 4;

			/* 消息累积上限（分片各片合并计算，含本帧） */
			uint64_t budget = frag_.size() + len;
			if (budget > kMaxMessageBytes) return DecodeError::TooLong;

			if (buf_.size() - pos < len) return DecodeError::NeedMore;
			std::string payload(buf_.data() + pos, len);
			for (uint64_t i = 0; i < len; ++i) payload[i] ^= maskKey[i & 3];

			consumed_ = pos + len;
			inHeader_ = true;

			if (op == OP_CONT) {
				if (fragOpcode_ < 0) return DecodeError::UnexpectedCont;
				frag_ += payload;
				if (fin) {
					Frame f; f.fin = true; f.opcode = (uint8_t)fragOpcode_; f.payload.swap(frag_);
					msgs_.push_back(f);
					fragOpcode_ = -1;
				}
			} else if (isCtrl) {
				Frame f; f.fin = fin; f.opcode = op; f.payload = std::move(payload);
				msgs_.push_back(f);
			} else {
				if (fin) {
					Frame f; f.fin = true; f.opcode = op; f.payload = std::move(payload);
					msgs_.push_back(f);
				} else {
					if (fragOpcode_ >= 0) return DecodeError::BadOpcode;	/* 数据帧中再开分片 */
					fragOpcode_ = op;
					frag_ = std::move(payload);
				}
			}
			continue;
		}
		/* 非帧头状态不可能出现（状态机仅「读帧头 → 读完整帧」一条直连路径），
		 * 防御性返回 NeedMore（与「输入不完整」同语义，不会误报协议错误）。 */
		return DecodeError::NeedMore;
	}
	}();
	buf_.erase(0, consumed_);
	consumed_ = 0;
	/* 语义收口（wsproto.hpp 已承诺「有产出 → None，等待输入 → NeedMore」）：
	 * 本 feed 产出了完整消息而输入恰好消费完，按 None 上报；只有既无产出
	 * 又无更多输入时才报 NeedMore。否则多帧单 feed 会被误报为等待输入。 */
	if (result == DecodeError::NeedMore && !msgs_.empty()) return DecodeError::None;
	return result;
}

/* ================= 帧编码（服务端 → 客户端，不掩码） ================= */
std::string encodeFrame(uint8_t opcode, const std::string& payload, bool fin) {
	std::string out;
	out.reserve(payload.size() + 10);
	out += (char)((fin ? 0x80 : 0x00) | (opcode & 0x0F));
	size_t n = payload.size();
	if (n < 126) {
		out += (char)n;
	} else if (n <= 0xFFFF) {
		out += (char)126;
		out += (char)((n >> 8) & 0xFF);
		out += (char)(n & 0xFF);
	} else {
		out += (char)127;
		for (int i = 7; i >= 0; --i) out += (char)(((uint64_t)n >> (i * 8)) & 0xFF);
	}
	out += payload;
	return out;
}

/* ================= HTTP Upgrade 握手解析 ================= */
HandshakeResult parseHandshake(const std::string& request) {
	HandshakeResult r;
	/* 请求行 + 头：以 \r\n 分行；空行结束 */
	size_t headEnd = request.find("\r\n\r\n");
	if (headEnd == std::string::npos) { r.reason = "incomplete headers"; return r; }
	std::string head = request.substr(0, headEnd);

	std::vector<std::string> lines;
	size_t pos = 0;
	while (pos < head.size()) {
		size_t e = head.find("\r\n", pos);
		if (e == std::string::npos) e = head.size();
		lines.push_back(head.substr(pos, e - pos));
		pos = e + 2;
	}
	if (lines.empty()) { r.reason = "empty request"; return r; }

	/* 请求行：GET <path> HTTP/1.1 */
	std::string reqLine = lines[0];
	size_t sp1 = reqLine.find(' ');
	if (sp1 == std::string::npos) { r.reason = "bad request line"; return r; }
	size_t sp2 = reqLine.find(' ', sp1 + 1);
	if (sp2 == std::string::npos) { r.reason = "bad request line"; return r; }
	if (reqLine.compare(0, 4, "GET ") != 0 && reqLine.compare(0, 3, "GET\t") != 0) {
		r.reason = "method not GET";
		return r;
	}
	r.path = reqLine.substr(sp1 + 1, sp2 - sp1 - 1);
	/* query 里的 token：?token=...（原样保留，未做百分比解码，token 为安全字符集） */
	size_t q = r.path.find('?');
	if (q != std::string::npos) {
		std::string query = r.path.substr(q + 1);
		r.path = r.path.substr(0, q);
		if (query.compare(0, 6, "token=") == 0) r.token = query.substr(6);
	}

	bool upg = false, connUpgrade = false, version13 = false;
	std::string key;
	for (size_t i = 1; i < lines.size(); ++i) {
		const std::string& ln = lines[i];
		size_t c = ln.find(':');
		if (c == std::string::npos) continue;
		std::string name = ln.substr(0, c);
		std::string value = ln.substr(c + 1);
		/* 去首尾空白 */
		size_t b = value.find_first_not_of(" \t");
		if (b == std::string::npos) value.clear(); else value = value.substr(b);
		size_t e2 = value.find_last_not_of(" \t");
		if (e2 != std::string::npos) value = value.substr(0, e2 + 1);

		auto ciEq = [](const std::string& a, const char* b) {
			for (size_t i = 0; i < a.size(); ++i) {
				if (!b[i]) return false;
				if (tolower((unsigned char)a[i]) != tolower((unsigned char)b[i])) return false;
			}
			return b[a.size()] == '\0';
		};
		auto hasToken = [&](const std::string& v, const char* tok) {
			size_t p = 0;
			while (p <= v.size()) {
				size_t e = v.find(',', p);
				if (e == std::string::npos) e = v.size();
				std::string t = v.substr(p, e - p);
				size_t tb = t.find_first_not_of(" \t");
				size_t te = t.find_last_not_of(" \t");
				if (tb != std::string::npos && te != std::string::npos) {
					t = t.substr(tb, te - tb + 1);
					if (ciEq(t, tok)) return true;
				}
				p = e + 1;
			}
			return false;
		};

		if (ciEq(name, "upgrade")) upg = hasToken(value, "websocket");
		else if (ciEq(name, "connection")) connUpgrade = hasToken(value, "upgrade");
		else if (ciEq(name, "sec-websocket-version")) version13 = ciEq(value, "13");
		else if (ciEq(name, "sec-websocket-key")) key = value;
	}

	if (!upg || !connUpgrade) { r.reason = "not a websocket upgrade"; return r; }
	if (!version13) { r.reason = "unsupported websocket version"; return r; }
	if (key.size() < 1 || key.find(' ') != std::string::npos) { r.reason = "bad sec-websocket-key"; return r; }
	r.ok = true;
	r.reason = key;	/* 复用字段回传 key 给上层（upgradeResponse 需要） */
	return r;
}

std::string upgradeResponse(const std::string& clientKey) {
	std::string body = "HTTP/1.1 101 Switching Protocols\r\n"
	                   "Upgrade: websocket\r\n"
	                   "Connection: Upgrade\r\n"
	                   "Sec-WebSocket-Accept: " + handshakeAccept(clientKey) + "\r\n"
	                   "\r\n";
	return body;
}

} /* namespace ws */
} /* namespace bot */
