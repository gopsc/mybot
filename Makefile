PYTHON ?= python
VENV ?= .venv
PIP := $(VENV)/bin/pip
PY := $(VENV)/bin/python

.PHONY: help venv install test lint check wheel clean

help:
	@printf '%s\n' \
	  'make install   create .venv and install test dependencies' \
	  'make test      run the full pytest suite' \
	  'make lint      run the narrow CI lint gate' \
	  'make check     static-check the demo robot' \
	  'make wheel     build sdist/wheel and verify in a clean venv' \
	  'make clean     remove build/cache artifacts'

venv:
	$(PYTHON) -m venv $(VENV)

install: venv
	$(PIP) install --upgrade pip
	$(PIP) install -e ".[test]"

test:
	$(PY) -m pytest -q

lint:
	$(PY) -m ruff check pymybot tests tools build_support.py

check:
	$(PY) -m pymybot check --robot skills/hardware-controller/assets/robots/relay-test.sql --input skills/hardware-controller/assets/scripts/relay-test.mt

wheel:
	$(PY) -I tools/ci_smoke.py wheel

clean:
	rm -rf build dist .pytest_cache .ruff_cache
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
