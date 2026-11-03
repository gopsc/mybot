#!/bin/sh
# Read-only I2C address prober wrapper.
#
# Usage:
#   i2c_probe.sh /dev/i2c-1                      # full scan 0x08-0x77
#   i2c_probe.sh 1 --range 0x40-0x4f --json
#   i2c_probe.sh i2c-1 --addr 0x48 --repeat 3
#   i2c_probe.sh --list-buses
#
# The first argument may be the bus (1, i2c-1, /dev/i2c-1) or any option.
# Everything else is forwarded unchanged to i2c_probe.py.
#
# Env: I2C_PROBE_PYTHON  interpreter to use (default: first python3 on PATH)
#
# This script only reads. It never calls i2cdetect -q / quick-write, and it
# refuses to widen the 0x08-0x77 range for you.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROBE="$SCRIPT_DIR/i2c_probe.py"

die() {
    printf '%s\n' "i2c_probe: $*" >&2
    exit 3
}

# ---- locate the prober -------------------------------------------------------
if [ ! -f "$PROBE" ]; then
    die "missing $PROBE (keep scripts/ next to this wrapper)"
fi

# ---- locate a python3 --------------------------------------------------------
PY=${I2C_PROBE_PYTHON:-}
if [ -z "$PY" ]; then
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then
            PY=$candidate
            break
        fi
    done
fi
if [ -z "$PY" ]; then
    die "no python3 found; set I2C_PROBE_PYTHON or install python3"
fi
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' 2>/dev/null; then
    die "$PY is not Python >= 3.6"
fi

# ---- normalise an optional leading bus argument ------------------------------
if [ "$#" -gt 0 ]; then
    case "$1" in
        -*) : ;;
        *)
            BUS=$1
            shift
            case "$BUS" in
                /dev/i2c-*) BUS_PATH=$BUS ;;
                i2c-*)      BUS_PATH=/dev/$BUS ;;
                [0-9]*)     BUS_PATH=/dev/i2c-$BUS ;;
                *)          die "unrecognised bus argument: $BUS (use 1, i2c-1 or /dev/i2c-1)" ;;
            esac

            if [ ! -e "$BUS_PATH" ]; then
                die "no such bus node: $BUS_PATH (check 'ls /dev/i2c-*' and whether the adapter/overlay is loaded)"
            fi
            if [ ! -r "$BUS_PATH" ] || [ ! -w "$BUS_PATH" ]; then
                die "permission denied on $BUS_PATH; i2c-dev opens O_RDWR, so it needs root or the 'i2c' group. Not chmod-ing anything on your behalf."
            fi

            set -- --bus "$BUS_PATH" "$@"
            ;;
    esac
fi

exec "$PY" "$PROBE" "$@"
