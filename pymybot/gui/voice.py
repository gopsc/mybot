"""Speech output for the GUI: read assistant replies aloud with Qt TTS.

The engine is created lazily and degrades gracefully — on hosts without a
QtTextToSpeech backend (speechd, SAPI, AVSpeechSynthesizer) ``available`` is
False and the window disables the 朗读 toggle instead of failing. Text is
stripped of Markdown fences/images and bounded before it reaches the engine;
speaking is sequential and stoppable, never blocking the UI thread.
"""
from __future__ import annotations

import re

MAX_SPEAK_CHARS = 6000

_NOISE = (
    (re.compile(r"```[a-zA-Z0-9_-]*\n(.*?)```", re.DOTALL), r"\1"),
    (re.compile(r"!\[[^\]]*\]\([^)]*\)"), " 图 "),
    (re.compile(r"\[([^\]]*)\]\([^)]*\)"), r"\1"),
    (re.compile(r"[#*_>`~|]+"), " "),
    (re.compile(r"\n{2,}"), "\n"),
)


def speakable_text(markdown):
    """Reduce an assistant Markdown message to something readable aloud."""
    text = str(markdown or "")
    for pattern, replacement in _NOISE:
        text = pattern.sub(replacement, text)
    text = re.sub(r"[ \t]{2,}", " ", text).strip()
    if len(text) > MAX_SPEAK_CHARS:
        text = text[:MAX_SPEAK_CHARS - 1] + "…"
    return text


class Speaker:
    """Thin, lazy QTextToSpeech wrapper; safe to construct offscreen."""

    def __init__(self):
        self._engine = None
        self._failed = False

    @property
    def available(self):
        if self._failed:
            return False
        if self._engine is None:
            try:
                from PySide6.QtTextToSpeech import QTextToSpeech
                engine = QTextToSpeech()
                # A backend without voices cannot speak; treat it as absent.
                if not engine.voices():
                    engine.deleteLater()
                    self._failed = True
                    return False
                engine.setRate(-0.05)
                self._engine = engine
            except Exception:
                self._failed = True
                return False
        return True

    def say(self, text):
        """Queue one message; returns False when speech is unavailable."""
        spoken = speakable_text(text)
        if not spoken or not self.available:
            return False
        from PySide6.QtTextToSpeech import QTextToSpeech
        try:
            self._engine.stop()
            self._engine.say(spoken)
            return self._engine.state() != QTextToSpeech.State.Error
        except Exception:
            self._failed = True
            return False

    def stop(self):
        try:
            if self._engine is not None:
                self._engine.stop()
        except Exception:
            pass

    def shutdown(self):
        self.stop()
        self._engine = None
