#include "ftdi.hpp"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>

#include <libftdi1/ftdi.h>

#include "util_except.hpp"
#include <unistd.h>

namespace bot {
namespace {

std::string lower(std::string text) {
	std::transform(text.begin(), text.end(), text.begin(),
		[](unsigned char c) { return static_cast<char>(std::tolower(c)); });
	return text;
}

int parseNumber(const std::string& text) {
	try {
		std::size_t used = 0;
		const int value = static_cast<int>(std::stoul(text, &used, 0));
		if (used != text.size()) { throw std::invalid_argument("trailing"); }
		return value;
	} catch (...) {
		throw IllegalArgumentException("invalid FTDI vendor/product number: " + text);
	}
}

int productAlias(const std::string& name) {
	const std::string key = lower(name);
	if (key == "232h" || key == "ft232h") { return 0x6014; }
	if (key == "232r" || key == "ft232r") { return 0x6001; }
	if (key == "2232h" || key == "ft2232h") { return 0x6010; }
	if (key == "4232h" || key == "ft4232h") { return 0x6011; }
	if (key == "230x" || key == "ft230x") { return 0x6015; }
	if (key == "231x" || key == "ft231x") { return 0x6015; }
	return -1;
}

} // namespace

FtdiUrl parseFtdiUrl(const std::string& url, bool spi) {
	const std::string prefix = "ftdi://";
	if (url.rfind(prefix, 0) != 0) {
		throw IllegalArgumentException("FTDI URL must start with ftdi://");
	}
	std::string rest = url.substr(prefix.size());
	std::string query;
	const std::size_t question = rest.find('?');
	if (question != std::string::npos) {
		query = rest.substr(question + 1);
		rest = rest.substr(0, question);
	}
	const std::size_t slash = rest.rfind('/');
	if (slash == std::string::npos || slash == 0) {
		throw IllegalArgumentException("FTDI URL requires ftdi://<device>/<interface 1..4>");
	}
	const std::string netloc = rest.substr(0, slash);
	const std::string interfaceText = rest.substr(slash + 1);
	if (interfaceText.size() != 1 || interfaceText[0] < '1' || interfaceText[0] > '4') {
		throw IllegalArgumentException("FTDI interface must be 1..4");
	}
	FtdiUrl parsed;
	parsed.interface = interfaceText[0] - '0';

	const std::size_t colon = netloc.find(':');
	if (colon == std::string::npos) {
		if (netloc.empty()) { throw IllegalArgumentException("FTDI URL requires a device or serial"); }
		parsed.serial = netloc;
	} else {
		const std::string vendorText = netloc.substr(0, colon);
		const std::string productText = netloc.substr(colon + 1);
		if (lower(vendorText) == "ftdi") { parsed.vendor = 0x0403; }
		else { parsed.vendor = parseNumber(vendorText); }
		const int alias = productAlias(productText);
		parsed.product = alias >= 0 ? alias : parseNumber(productText);
	}

	if (!query.empty()) {
		if (!spi) {
			throw IllegalArgumentException("FTDI I2C URL does not accept query parameters");
		}
		if (query.rfind("cs=", 0) != 0) {
			throw IllegalArgumentException("FTDI SPI only supports ?cs=0..4");
		}
		const std::string csText = query.substr(3);
		if (csText.size() != 1 || csText[0] < '0' || csText[0] > '4') {
			throw IllegalArgumentException("FTDI SPI cs must be 0..4");
		}
		parsed.cs = csText[0] - '0';
	}
	return parsed;
}

struct FtdiBus::Impl {
	ftdi_context* ctx = nullptr;
	FtdiUrl url;
	bool spi = false;
	int mode = 0;
	int bits = 8;
	int speed = 1000000;
	std::mutex lock;

	/* I2C pin state：AD0=SCL、AD1=SDA。 */
	bool scl = true;
	bool sda = true;
	bool sdaOutput = true;

	static constexpr std::uint8_t kScl = 0x01;
	static constexpr std::uint8_t kSda = 0x02;

	/* SPI pin state：AD0=SCK、AD1=MOSI、AD2=MISO、AD3..AD7=CS。 */
	static constexpr std::uint8_t kSck = 0x01;
	static constexpr std::uint8_t kMosi = 0x02;
	static constexpr std::uint8_t kMiso = 0x04;
	static constexpr std::uint8_t kCsMask = 0xF8;

	void writeRaw(const std::vector<std::uint8_t>& data) {
		std::size_t sent = 0;
		while (sent < data.size()) {
			const int written = ftdi_write_data(ctx, data.data() + sent,
				static_cast<int>(data.size() - sent));
			if (written < 0) {
				throw std::runtime_error(std::string("FTDI write failed: ")
					+ ftdi_get_error_string(ctx));
			}
			if (written == 0) {
				throw std::runtime_error("FTDI write made no progress");
			}
			sent += static_cast<std::size_t>(written);
		}
	}

	std::vector<std::uint8_t> readRaw(std::size_t count) {
		std::vector<std::uint8_t> out;
		out.reserve(count);
		const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
		std::uint8_t buffer[256];
		while (out.size() < count) {
			const int got = ftdi_read_data(ctx, buffer,
				static_cast<int>(std::min<std::size_t>(count - out.size(), sizeof(buffer))));
			if (got < 0) {
				throw std::runtime_error(std::string("FTDI read failed: ")
					+ ftdi_get_error_string(ctx));
			}
			if (got > 0) {
				out.insert(out.end(), buffer, buffer + got);
				continue;
			}
			if (std::chrono::steady_clock::now() >= deadline) {
				throw std::runtime_error("FTDI read timed out");
			}
			std::this_thread::sleep_for(std::chrono::milliseconds(1));
		}
		return out;
	}

	void setPins(std::uint8_t value, std::uint8_t direction) {
		writeRaw({0x80, value, direction});
	}

	std::uint8_t getPins() {
		writeRaw({0x81});
		return readRaw(1)[0];
	}

	/* ---- I2C bit-bang ---- */
	void i2cDrive(bool sclValue, bool sdaValue, bool sdaIsOutput) {
		const std::uint8_t value = static_cast<std::uint8_t>(
			(sclValue ? kScl : 0) | (sdaValue ? kSda : 0));
		const std::uint8_t direction = static_cast<std::uint8_t>(
			kScl | (sdaIsOutput ? kSda : 0));
		setPins(value, direction);
		scl = sclValue;
		sda = sdaValue;
		sdaOutput = sdaIsOutput;
	}

	void i2cStart() {
		i2cDrive(true, true, true);
		i2cDrive(true, false, true);
		i2cDrive(false, false, true);
	}

	void i2cStop() {
		i2cDrive(false, false, true);
		i2cDrive(true, false, true);
		i2cDrive(true, true, true);
	}

	bool i2cWriteByte(std::uint8_t byte) {
		for (int bit = 7; bit >= 0; --bit) {
			const bool value = ((byte >> bit) & 1) != 0;
			i2cDrive(false, value, true);
			i2cDrive(true, value, true);
			i2cDrive(false, value, true);
		}
		i2cDrive(false, true, false);
		i2cDrive(true, true, false);
		const std::uint8_t pins = getPins();
		i2cDrive(false, true, false);
		i2cDrive(false, true, true);
		return (pins & kSda) == 0;	/* ACK = SDA low */
	}

	std::uint8_t i2cReadByte(bool ack) {
		std::uint8_t value = 0;
		for (int bit = 0; bit < 8; ++bit) {
			i2cDrive(false, true, false);
			i2cDrive(true, true, false);
			const std::uint8_t pins = getPins();
			value = static_cast<std::uint8_t>((value << 1) | ((pins & kSda) ? 1 : 0));
			i2cDrive(false, true, false);
		}
		i2cDrive(false, ack ? false : true, true);
		i2cDrive(true, ack ? false : true, true);
		i2cDrive(false, ack ? false : true, true);
		i2cDrive(false, true, true);
		return value;
	}

	/* ---- SPI bit-bang ---- */
	void spiDrive(bool sck, bool mosi, bool csActive) {
		std::uint8_t value = static_cast<std::uint8_t>(
			(sck ? kSck : 0) | (mosi ? kMosi : 0) | kCsMask);
		if (csActive) {
			value = static_cast<std::uint8_t>(value & ~(0x08u << url.cs));
		}
		const std::uint8_t direction = static_cast<std::uint8_t>(kSck | kMosi | kCsMask);
		setPins(value, direction);
	}

	std::uint8_t spiReadMiso() {
		return static_cast<std::uint8_t>((getPins() & kMiso) != 0 ? 1 : 0);
	}

	void spiTransfer(const std::vector<std::uint8_t>& data,
			std::vector<std::uint8_t>& out, int delayUs, std::mutex& guard) {
		std::lock_guard<std::mutex> held(guard);
		const bool idle = (mode & 2) != 0;	/* CPOL */
		const bool phase = (mode & 1) != 0;	/* CPHA */
		spiDrive(idle, false, false);
		spiDrive(idle, false, true);	/* assert CS */
		out.assign(data.size(), 0);
		for (std::size_t index = 0; index < data.size(); ++index) {
			std::uint8_t value = 0;
			for (int bit = 7; bit >= 0; --bit) {
				const bool mosi = ((data[index] >> bit) & 1) != 0;
				std::uint8_t sampled = 0;
				if (!phase) {
					spiDrive(idle, mosi, true);
					spiDrive(!idle, mosi, true);
					sampled = spiReadMiso();
					spiDrive(idle, mosi, true);
				} else {
					spiDrive(idle, mosi, true);
					spiDrive(!idle, mosi, true);
					spiDrive(idle, mosi, true);
					sampled = spiReadMiso();
				}
				value = static_cast<std::uint8_t>((value << 1) | sampled);
			}
			out[index] = value;
		}
		spiDrive(idle, false, false);	/* release CS */
		if (delayUs > 0) { ::usleep(static_cast<useconds_t>(delayUs)); }
	}
};

FtdiBus::FtdiBus(const std::string& urlText, bool spi)
	: impl_(std::make_unique<Impl>()) {
	impl_->url = parseFtdiUrl(urlText, spi);
	impl_->spi = spi;
	impl_->ctx = ftdi_new();
	if (impl_->ctx == nullptr) {
		throw std::runtime_error("FTDI: cannot allocate libftdi context");
	}
	const char* serial = impl_->url.serial.empty() ? nullptr : impl_->url.serial.c_str();
	const int rc = ftdi_usb_open_desc(impl_->ctx, impl_->url.vendor, impl_->url.product,
		nullptr, serial);
	if (rc < 0) {
		const std::string message = std::string("FTDI open failed: ")
			+ ftdi_get_error_string(impl_->ctx);
		ftdi_free(impl_->ctx);
		impl_->ctx = nullptr;
		throw std::runtime_error(message);
	}
	if (ftdi_set_interface(impl_->ctx,
			static_cast<ftdi_interface>(impl_->url.interface)) < 0
			|| ftdi_set_bitmode(impl_->ctx, 0, BITMODE_MPSSE) < 0
			|| ftdi_set_latency_timer(impl_->ctx, 16) < 0) {
		const std::string message = std::string("FTDI MPSSE setup failed: ")
			+ ftdi_get_error_string(impl_->ctx);
		ftdi_usb_close(impl_->ctx);
		ftdi_free(impl_->ctx);
		impl_->ctx = nullptr;
		throw std::runtime_error(message);
	}
	ftdi_usb_purge_buffers(impl_->ctx);
	/* MPSSE 基础序列：关闭 5 分频/自适应时钟/三相位时钟，并设一个保守的时钟分频。
	 * GPIO 位操作不依赖时钟分频，但初始化序列让适配器进入确定状态。 */
	impl_->writeRaw({0x8A, 0x97, 0x8D, 0x86, 0x1D, 0x00});
	if (spi) {
		impl_->spiDrive(0, false, false);
	} else {
		impl_->i2cDrive(true, true, true);
	}
}

FtdiBus::~FtdiBus() {
	if (impl_ != nullptr && impl_->ctx != nullptr) {
		ftdi_usb_close(impl_->ctx);
		ftdi_free(impl_->ctx);
		impl_->ctx = nullptr;
	}
}

const FtdiUrl& FtdiBus::url() const { return impl_->url; }

void FtdiBus::i2cTransfer(int address, const std::vector<std::uint8_t>& write,
		int readCount, std::vector<std::uint8_t>& out) {
	std::lock_guard<std::mutex> held(impl_->lock);
	if (address < 0 || address > 0x7F) {
		throw std::runtime_error("FTDI I2C address must be 0..127");
	}
	if (write.empty() && readCount == 0) {
		throw std::runtime_error("FTDI I2C empty transaction");
	}
	auto fail = [&](const char* message) {
		try { impl_->i2cStop(); } catch (...) {}
		throw std::runtime_error(message);
	};
	impl_->i2cStart();
	if (!write.empty()) {
		if (!impl_->i2cWriteByte(static_cast<std::uint8_t>((address << 1) | 0))) {
			fail("FTDI I2C NACK on address write");
		}
		for (std::uint8_t byte : write) {
			if (!impl_->i2cWriteByte(byte)) { fail("FTDI I2C NACK on data write"); }
		}
	}
	if (readCount > 0) {
		if (!write.empty()) { impl_->i2cStart(); }
		if (!impl_->i2cWriteByte(static_cast<std::uint8_t>((address << 1) | 1))) {
			fail("FTDI I2C NACK on address read");
		}
		out.clear();
		out.reserve(static_cast<std::size_t>(readCount));
		for (int index = 0; index < readCount; ++index) {
			out.push_back(impl_->i2cReadByte(index + 1 < readCount));
		}
	}
	impl_->i2cStop();
}

void FtdiBus::spiSetup(int mode, int bits, int speed) {
	std::lock_guard<std::mutex> held(impl_->lock);
	if (mode < 0 || mode > 3) { throw std::runtime_error("FTDI SPI mode must be 0..3"); }
	if (bits != 8) { throw std::runtime_error("FTDI SPI supports 8-bit words only"); }
	if (speed < 1) { throw std::runtime_error("FTDI SPI speed must be positive"); }
	impl_->mode = mode;
	impl_->bits = bits;
	impl_->speed = speed;
}

void FtdiBus::spiTransfer(const std::vector<std::uint8_t>& data,
		std::vector<std::uint8_t>& out, int delayUs) {
	if (!impl_->spi) { throw std::runtime_error("FTDI bus is not SPI"); }
	impl_->spiTransfer(data, out, delayUs, impl_->lock);
}

} // namespace bot
