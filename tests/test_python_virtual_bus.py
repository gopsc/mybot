from pymybot.hal import HALManager


def test_python_virtual_i2c_combined_transfer_and_borrowed_close():
    hal = HALManager()
    bus_owner, consumer = object(), object()
    try:
        fd = hal.call("i2c_open", "virt-contract", owner=bus_owner)
        assert fd >= 0
        state = {"pointer": 0, "registers": {0: 0x12, 1: 0x34}}

        def write(data):
            state["pointer"] = data[0]
            for index, value in enumerate(data[1:]):
                state["registers"][state["pointer"] + index] = value

        def read(count):
            start = state["pointer"]
            return [state["registers"].get(start + index, 0) for index in range(count)]

        assert hal.call("virt_attach", fd, "i2c", 0x31,
                        {"write": write, "read": read}, owner=consumer) == 0
        assert hal.call("i2c_transfer", fd, 0x31, [0], 2, owner=consumer) == [0x12, 0x34]
        assert hal.call("i2c_transfer", fd, 0x31, [4, 0x56], 0, owner=consumer) == []
        assert hal.call("i2c_transfer", fd, 0x32, [0], 1, owner=consumer) is None

        # A consumer releases only its model; the Python bus row retains ownership.
        assert hal.call("close_handle", fd, owner=consumer) == 0
        assert fd in hal._handles
        assert hal.call("close_handle", fd, owner=bus_owner) == 0
        assert fd not in hal._handles
    finally:
        hal.close()


def test_python_virtual_spi_transfer_isolated_by_runtime_owner():
    hal = HALManager()
    bus_owner, first, second = object(), object(), object()
    try:
        fd = hal.call("spi_open", "virt-contract", owner=bus_owner)
        assert fd >= 0
        assert hal.call("spi_setup", fd, 0, 8, 1000000, owner=bus_owner) == 0
        assert hal.call("virt_attach", fd, "spi", "virt-contract",
                        {"xfer": lambda data: [11] * len(data)}, owner=first) == 0
        assert hal.call("virt_attach", fd, "spi", "virt-contract",
                        {"xfer": lambda data: [29] * len(data)}, owner=second) == 0
        assert hal.call("spi_transfer", fd, [2, 0, 0], owner=first) == [11, 11, 11]
        assert hal.call("spi_transfer", fd, [2, 0, 0], owner=second) == [29, 29, 29]
    finally:
        hal.close()


def test_python_virtual_uart_stream_flush_and_owner_cleanup():
    hal = HALManager()
    bus_owner, consumer = object(), object()
    try:
        fd = hal.call("uart_open", "virt-contract", 9600, owner=bus_owner)
        assert fd >= 0
        assert hal.call("virt_attach", fd, "uart", "virt-contract",
                        {"on_write": lambda data: [0xA0, *data]}, owner=consumer) == 0
        assert hal.call("uart_write", fd, [0x12, 0x34], owner=consumer) == 2
        assert hal.call("uart_read", fd, 2, 0, owner=consumer) == [0xA0, 0x12]
        assert hal.call("uart_read", fd, 2, 0, owner=consumer) == [0x34]

        hal.call("uart_write", fd, [0x56], owner=consumer)
        assert hal.call("uart_flush", fd, owner=consumer) == 0
        assert hal.call("uart_read", fd, 1, 0, owner=consumer) == []
        hal.release_owner(consumer)
        assert fd in hal._handles
        assert hal.call("uart_read", fd, 1, 0, owner=consumer) == []
    finally:
        hal.close()


def test_python_virtual_faults_return_failure():
    hal = HALManager()
    bus_owner, consumer = object(), object()
    try:
        i2c = hal.call("i2c_open", "virt-faults", owner=bus_owner)
        assert hal.call("virt_attach", i2c, "i2c", 0x31,
                        {"write": lambda data: False, "read": lambda n: [0]},
                        owner=consumer) == 0
        assert hal.call("i2c_transfer", i2c, 0x31, [0], 1, owner=consumer) is None

        spi = hal.call("spi_open", "virt-faults", owner=bus_owner)
        assert hal.call("virt_attach", spi, "spi", "virt-faults",
                        {"xfer": lambda data: None}, owner=consumer) == 0
        assert hal.call("spi_transfer", spi, [1, 2], owner=consumer) is None

        uart = hal.call("uart_open", "virt-faults", 9600, owner=bus_owner)
        assert hal.call("virt_attach", uart, "uart", "virt-faults",
                        {"on_write": lambda data: False}, owner=consumer) == 0
        assert hal.call("uart_write", uart, [1], owner=consumer) == -1
    finally:
        hal.close()
