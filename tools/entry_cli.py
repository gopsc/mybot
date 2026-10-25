"""PyInstaller entry point; no command opens the GUI, like the installed script."""
from pymybot.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
