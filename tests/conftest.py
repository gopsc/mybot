from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    # pytest enables faulthandler for the whole session. On Windows every Lua error()
    # surfaces as SEH exception 0xE24C4A02; faulthandler treats it as fatal and walks
    # all thread stacks mid-unwind, which segfaults daemon tests intermittently. See
    # pymybot.cli.disable_windows_faulthandler. Other platforms keep faulthandler.
    if sys.platform == "win32":
        import faulthandler
        faulthandler.disable()


@pytest.fixture(autouse=True)
def no_session_logs(monkeypatch):
    """Tests must never append to the operator's real ~/.mybot/sessions."""
    monkeypatch.setenv("MYBOT_SESSION_LOG", "0")


def usable_symlink(link, target):
    """Create a symlink and report whether the result is actually usable.

    Windows has two failure modes: ``OSError`` when the account lacks
    SeCreateSymbolicLinkPrivilege (Developer Mode off), and a silent no-op that
    leaves an entry which neither ``is_symlink()`` nor ``exists()`` can resolve.
    Both mean the platform cannot express the fixture, so callers skip instead
    of asserting on a link that was never created.
    """
    try:
        link.symlink_to(target, target_is_directory=target.is_dir())
    except (OSError, NotImplementedError):
        return False
    return link.is_symlink() and link.exists()

PRELUDE = '''
dofile(__mpath.resolve("lib/drv_common.lua"))
local function sample(count, tag, data)
    if data.fail_call == "yes" then return err("synthetic sample failure") end
    if data.reply == "scalar" then return 42 end
    if data.reply == "empty" then return {} end
    if data.reply == "status" then return {result="UNKNOWN"} end
    return {result="OK", COUNT=count, VALUE=count / 4, TAG=tag, WORD="synthetic",
            CRC_OK=data.reply == "crc" and 0 or 1}
end
local function built(ctx, data)
    ctx.state.fd = ctx.fd
    ctx.state.direct = data.proto == "virt"
    if data.fail_build == "yes" then return err("synthetic build failure") end
    return {result="OK"}
end
local function cleanup(ctx, data)
    if ctx.state.direct then
        local close = ({i2c=i2c_close, spi=spi_close, uart=uart_close})[ctx.name]
        close(ctx.state.fd)
    end
    if data.fail_destroy == "yes" then error("synthetic destroy failure") end
    return {result="OK"}
end
'''

I2C_DRIVER = '''
SyntheticI2C_VIRT = {BUS="i2c"}
function SyntheticI2C_VIRT.new(options)
    options = options or {}
    local base = options.count or 40961
    local dev = {registers={}, pointer=0, nack=false, read_nack=false}
    function dev:virt_tick(n)
        local count = base + n
        self.registers[0] = math.floor(count / 256) % 256
        self.registers[1] = count % 256
    end
    function dev.write(bytes)
        if dev.nack then return false end
        dev.pointer = bytes[1]
        for i=2,#bytes do dev.registers[dev.pointer + i - 2] = bytes[i] end
        return true
    end
    function dev.read(n)
        if dev.nack or dev.read_nack then return nil end
        local bytes = {}
        for i=1,n do bytes[i] = dev.registers[dev.pointer + i - 1] or 0 end
        dev.pointer = dev.pointer + n
        return bytes
    end
    dev:virt_tick(0)
    return dev
end
require_driver("i2c", {
    name="i2c",
    build=function(ctx, data)
        if not i2c_write_reg(ctx.fd, 4, tonumber(data.tag) or 7) then
            return err("synthetic I2C write NACK")
        end
        return built(ctx, data)
    end,
    call=function(ctx, data)
        local count = i2c_read_multi(ctx.fd, 0, 2)
        local tag = i2c_read_reg(ctx.fd, 4)
        if count < 0 or tag < 0 then return err("synthetic I2C read NACK") end
        return sample(count, tag, data)
    end,
    destroy=cleanup,
})
'''

SPI_DRIVER = '''
SyntheticSPI_VIRT = {BUS="spi"}
function SyntheticSPI_VIRT.new()
    local dev = {count=40961, tag=0, fail=false}
    function dev:virt_tick(n) self.count = 40961 + n end
    function dev.xfer(tx)
        if dev.fail then return nil end
        if tx[1] == 1 and #tx == 2 then
            dev.tag = tx[2]
            return {0, dev.tag}
        end
        if tx[1] == 2 and #tx == 4 then
            return {0, math.floor(dev.count / 256) % 256, dev.count % 256, dev.tag}
        end
        return false
    end
    return dev
end
require_driver("spi", {
    name="spi",
    build=function(ctx, data)
        if data.proto == "virt" then
            __BOT4CJ_VIRTBUS.attach_spi("synthetic", data.path, SyntheticSPI_VIRT.new())
        end
        if spi_write_multi(ctx.fd, {1, tonumber(data.tag) or 7}) ~= 0 then
            return err("synthetic SPI write failed")
        end
        return built(ctx, data)
    end,
    call=function(ctx, data)
        local bytes = spi_xfer_full(ctx.fd, {2, 0, 0, 0})
        if not bytes then return err("synthetic SPI transfer failed") end
        return sample(bytes[2] * 256 + bytes[3], bytes[4], data)
    end,
    destroy=cleanup,
})
'''

UART_DRIVER = '''
SyntheticUART_VIRT = {}
function SyntheticUART_VIRT.new()
    local dev = {BUS="uart", count=40961, tag=0, fail=false, silent=false}
    function dev:virt_tick(n) self.count = 40961 + n end
    function dev.on_write(bytes)
        if dev.fail then return false end
        if bytes[1] == 1 and #bytes == 2 then
            dev.tag = bytes[2]
        elseif bytes[1] == 2 and #bytes == 1 then
            if dev.silent then return nil end
            return {math.floor(dev.count / 256) % 256, dev.count % 256, dev.tag}
        else
            return false
        end
    end
    return dev
end
require_driver("uart", {
    name="uart",
    build=function(ctx, data)
        if uart_write(ctx.fd, {1, tonumber(data.tag) or 7}) ~= 2 then
            return err("synthetic UART write failed")
        end
        return built(ctx, data)
    end,
    call=function(ctx, data)
        if uart_write(ctx.fd, {2}) ~= 1 then return err("synthetic UART write failed") end
        local first = uart_read(ctx.fd, 1, 0)
        local rest = uart_read(ctx.fd, 2, 0)
        if not first or not rest then return err("synthetic UART read failed") end
        if #first ~= 1 or #rest ~= 2 then return err("synthetic UART timeout") end
        return sample(first[1] * 256 + rest[1], rest[2], data)
    end,
    destroy=cleanup,
})
'''


@pytest.fixture
def synthetic_modules(tmp_path):
    for name, source in (("SyntheticI2C", I2C_DRIVER), ("SyntheticSPI", SPI_DRIVER),
                         ("SyntheticUART", UART_DRIVER)):
        (tmp_path / (name + ".lua")).write_text(PRELUDE + source, encoding="utf-8")
    return [tmp_path, ROOT / "modules"]


@pytest.fixture
def single_consumer_modules(synthetic_modules):
    path = synthetic_modules[0] / "SyntheticI2C.lua"
    path.write_text('SINGLE_CONSUMER = "synthetic request stream"\n' + PRELUDE + I2C_DRIVER,
                    encoding="utf-8")
    return synthetic_modules
