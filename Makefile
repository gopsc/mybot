PYTHON ?= python
VENV ?= .venv
PIP := $(VENV)/bin/pip
PY := $(VENV)/bin/python

.PHONY: help venv install test lint check wheel package clean

help:
	@printf '%s\n' \
	  'make install   create .venv and install test dependencies' \
	  'make test      run the full pytest suite' \
	  'make lint      run the narrow CI lint gate' \
	  'make check     static-check the demo robot' \
	  'make wheel     build sdist/wheel and verify in a clean venv' \
	  'make package   build the PyInstaller bundle' \
	  'make clean     remove build/cache artifacts'

venv:
	$(PYTHON) -m venv $(VENV)

install: venv
	$(PIP) install --upgrade pip
	$(PIP) install -e ".[test]"

test:
	$(PY) -m pytest -q

lint:
	$(PY) -m ruff check pymybot tests tools build_support.py --select E9,F63,F7,F82

check:
	$(PY) -m pymybot check --robot robots/relay-test.sql --input scripts/relay-test.mt

wheel:
	$(PY) -I tools/ci_smoke.py wheel

package:
	$(PIP) install -e ".[package]"
	$(PY) -m PyInstaller --noconfirm --clean tools/mybot.spec

clean:
	rm -rf build dist .pytest_cache .ruff_cache
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
