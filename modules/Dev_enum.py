"""Cross-platform I2C / SPI / UART device enumeration driver.

Queries the operating system for available bus adapters and device nodes.
Passive by default — no bus transactions, no port opening.  Useful as a
diagnostic first step before writing structure SQL.

The implementation lives in the trusted ``pymybot.dev_enum`` package module so
the read-only ``discover`` command never has to execute this writable asset
copy. This file only forwards the driver contract to that implementation.

SQL example::

    CREATE TABLE Dev_enum (name String);
    INSERT INTO Dev_enum (name) VALUES ('enum0');

MT example::

    @Action
    enum0.go;
       1  ;
    @

Optional action parameter ``buses`` selects which buses to enumerate
(comma-separated, default ``all``).  Accepted tokens: ``i2c``, ``spi``,
``uart``, ``all``.
"""

from __future__ import annotations

# Re-exported for the driver contract and for tests that load this asset
# directly and exercise the bus-token parser.
from pymybot.dev_enum import Driver, _parse_buses

__all__ = ["Driver"]
