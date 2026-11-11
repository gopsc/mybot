# Headless pymybot image: the controller CLI only.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY pyproject.toml README.md LICENSE MANIFEST.in build_support.py ./
COPY pymybot ./pymybot
COPY skills ./skills

RUN pip install .

ENTRYPOINT ["pymybot"]
CMD ["doctor"]
