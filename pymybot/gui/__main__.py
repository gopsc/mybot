"""``python -m pymybot.gui`` behaves like ``pymybot gui``."""
import sys

from pymybot.cli import main as cli_main


def main(argv=None):
    return cli_main(["gui", *(sys.argv[1:] if argv is None else argv)])


if __name__ == "__main__":
    raise SystemExit(main())
