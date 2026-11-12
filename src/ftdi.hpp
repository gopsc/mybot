#pragma once
/* ftdi.hpp —— FTDI USB 适配器上的 I2C/SPI（libftdi1 MPSSE GPIO 位操作）
 *
 * URL 形态与 pyftdi 对齐：
 *   ftdi://<device>/<interface>             I2C
 *   ftdi://<device>/<interface>?cs=0..4     SPI
 * <device> 可以是 ftdi:232h / ftdi:ft232r / 0x0403:0x6014 / 序列号。
 */

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace bot {

struct FtdiUrl {
	int vendor = 0x0403;
	int product = 0;
	std::string serial;
	int interface = 1;
	int cs = 0;
};

/* 解析并校验 URL；spi=true 时允许 ?cs=。不打开设备，便于单测。 */
FtdiUrl parseFtdiUrl(const std::string& url, bool spi);

class FtdiBus {
public:
	/* 打开设备并切换到 MPSSE；失败抛 std::runtime_error。 */
	explicit FtdiBus(const std::string& url, bool spi);
	~FtdiBus();
	FtdiBus(const FtdiBus&) = delete;
	FtdiBus& operator=(const FtdiBus&) = delete;

	const FtdiUrl& url() const;

	/* I2C：write 非空先写；readCount > 0 时读；失败抛异常（NACK/传输）。 */
	void i2cTransfer(int address, const std::vector<std::uint8_t>& write,
		int readCount, std::vector<std::uint8_t>& out);

	/* SPI：只支持 8 位字；mode 0..3。 */
	void spiSetup(int mode, int bits, int speed);
	void spiTransfer(const std::vector<std::uint8_t>& data,
		std::vector<std::uint8_t>& out, int delayUs);

private:
	struct Impl;
	std::unique_ptr<Impl> impl_;
};

} // namespace bot
