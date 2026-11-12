-- SpiProbe —— SPI 回环/诊断探针（把 value 发一个字节，读回一个字节）
--
-- 结构 SQL：
--   CREATE TABLE SPI (name String, path String);
--   INSERT INTO SPI (name, path) VALUES ('spi0', 'ftdi://ftdi:232h/1?cs=0');
--   CREATE TABLE SpiProbe (name String, SPI String);
--   INSERT INTO SpiProbe (name, SPI) VALUES ('probe0', '$spi0');
--
-- MT：
--   @Action
--   probe0.value;
--             42;
--   @
--
-- MOSI 与 MISO 短接时可验证收发链路；接真实器件时可作为最小读写探针。

local mpath = (__mpath or dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules"):match("[^:]+") .. "/lib/mpath.lua"))
dofile(mpath.resolve("lib/HAL.lua"))
dofile(mpath.resolve("lib/drv_common.lua"))

local fd = -1

function build(data)
	local ok, ek = arg_table(data)
	if not ok then return ek end
	local opened = tonumber(data.fd)
	if opened == nil or opened < 0 then
		return err("Invalid Arguments: fd (open the SPI bus first)")
	end
	fd = opened
	return { result = "OK", fd = fd }
end

function call(data)
	local ok, ek = arg_table(data)
	if not ok then return ek end
	if fd < 0 then return err("SPI not opened (build first)") end
	local value = tonumber(data.value)
	if value == nil then value = 0 end
	local out = spi_xfer_full(fd, { value }, 0)
	if out == nil or #out ~= 1 then
		return err("SPI transfer failed")
	end
	return { result = "OK", rx = out[1] }
end

function destroy(data)
	local ok, ek = arg_table(data)
	if not ok then return ek end
	fd = -1
	return { result = "OK" }
end
