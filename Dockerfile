# =========================
# Builder Stage
# =========================
FROM python:3.10-slim AS builder

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Only build dependencies here
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
        curl \
        ca-certificates \
        libgl1 \
        libglib2.0-0 \
        libgomp1 && \
    rm -rf /var/lib/apt/lists/*

# Copy dependency files first for layer caching
COPY requirements.txt pyproject.toml ./

# Install Python dependencies into a separate location
RUN python -m pip install --upgrade pip && \
    pip install --prefix=/install -r requirements.txt

# Copy source code
COPY stockpile/*.py stockpile/
COPY app/ app/
COPY .streamlit/ .streamlit/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Install project package
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    pip install --prefix=/install -e .

# =========================
# Runtime Stage
# =========================
FROM python:3.10-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    QT_QPA_PLATFORM=offscreen \
    DISPLAY=:99 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH="/usr/local/bin:$PATH"

WORKDIR /app

# Only runtime system packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
        xvfb \
        colmap \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy installed Python packages from builder
COPY --from=builder /install /usr/local

# Copy app source
COPY stockpile/*.py stockpile/
COPY app/ app/
COPY pyproject.toml .
COPY .streamlit/ .streamlit/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Create runtime directories
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    mkdir -p /app/data

EXPOSE 8501

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:8501/_stcore/health || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
