"""Tkinter GUI, the default entry point of pymybot.

``python -m pymybot`` opens this window; ``pymybot --no-gui ...`` keeps the
command-line interface. The window is agent-centric: it drives one long-lived
``pymybot serve`` child and asks the operator to approve each tool call.
"""
from .app import App, GuiUnavailable, run_gui

__all__ = ["App", "GuiUnavailable", "run_gui"]
