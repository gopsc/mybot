# Headless pymybot image. GUI/Tk is intentionally not installed.
# Build with agent support: docker build --build-arg EXTRAS=agent -t pymybot:agent .
FROM python:3.12-slim

ARG EXTRAS=""
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY pyproject.toml README.md LICENSE MANIFEST.in build_support.py ./
COPY pymybot ./pymybot
COPY modules ./modules
COPY robots ./robots
COPY scripts ./scripts
COPY skills ./skills

RUN if [ -n "$EXTRAS" ]; then pip install ".[$EXTRAS]"; else pip install .; fi

# The CLI is the container entry point; GUI entry is not meaningful here.
ENTRYPOINT ["pymybot", "--no-gui"]
CMD ["doctor"]
