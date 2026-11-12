/* test_ftdi.cpp —— FTDI URL 解析（不打开设备） */

#include <string>

#include "ftdi.hpp"
#include "harness.hpp"
#include "util_except.hpp"

TH_TEST(ftdi_url_parses_named_adapter) {
	bot::FtdiUrl url = bot::parseFtdiUrl("ftdi://ftdi:232h/1", false);
	TH_CHECK(url.vendor == 0x0403);
	TH_CHECK(url.product == 0x6014);
	TH_CHECK(url.interface == 1);
	TH_CHECK(url.serial.empty());
}

TH_TEST(ftdi_url_parses_hex_ids_and_serial) {
	bot::FtdiUrl hex = bot::parseFtdiUrl("ftdi://0x0403:0x6010/2", false);
	TH_CHECK(hex.vendor == 0x0403 && hex.product == 0x6010 && hex.interface == 2);
	bot::FtdiUrl serial = bot::parseFtdiUrl("ftdi://ABC123/3", false);
	TH_CHECK(serial.serial == "ABC123" && serial.interface == 3);
}

TH_TEST(ftdi_url_parses_spi_chip_select) {
	bot::FtdiUrl url = bot::parseFtdiUrl("ftdi://ftdi:232h/4?cs=2", true);
	TH_CHECK(url.cs == 2);
	TH_CHECK(url.interface == 4);
}

TH_TEST(ftdi_url_rejects_invalid_forms) {
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "ftdi://",
		bot::parseFtdiUrl("usb://ftdi:232h/1", false));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "interface",
		bot::parseFtdiUrl("ftdi://ftdi:232h/5", false));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "query",
		bot::parseFtdiUrl("ftdi://ftdi:232h/1?cs=1", false));
	TH_CHECK_THROWS_MSG(bot::IllegalArgumentException, "cs",
		bot::parseFtdiUrl("ftdi://ftdi:232h/1?cs=9", true));
}
