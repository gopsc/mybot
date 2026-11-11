"""Run the self-contained hardware-controller project."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pymybot.cli import main  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main())
