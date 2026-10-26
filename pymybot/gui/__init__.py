"""Native Qt front end, loaded only when the GUI is requested."""


class GuiUnavailable(RuntimeError):
    """The optional GUI dependency or a usable display is unavailable."""


def run_gui(args):
    """Open the native window without making Qt a CLI import dependency."""
    try:
        from .app import run_gui as launch
    except ImportError as exc:
        raise GuiUnavailable(
            'The GUI requires PySide6. Install it with pip install "pymybot[gui]", '
            f"or use --no-gui. Qt import failed: {exc}"
        ) from exc
    return launch(args)


__all__ = ["GuiUnavailable", "run_gui"]
