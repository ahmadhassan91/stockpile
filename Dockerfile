# Use Python slim image as base (much smaller than Ubuntu)
FROM python:3.10-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    QT_QPA_PLATFORM=offscreen \
    DISPLAY=:99 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install only essential system dependencies
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

WORKDIR /app

# Copy and install Python dependencies first (for better layer caching)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    find /usr/local/lib/python3.10/site-packages -type f -name '*.pyc' -delete && \
    find /usr/local/lib/python3.10/site-packages -type d -name '__pycache__' -delete

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Copy Streamlit config to prevent email prompt
COPY .streamlit/ .streamlit/

# Copy project source
COPY pyproject.toml .
COPY stockpile/ stockpile/
COPY app/ app/

# Install the project package itself
RUN pip install --no-cache-dir -e . && \
    find /usr/local/lib/python3.10/site-packages -type f -name '*.pyc' -delete && \
    find /usr/local/lib/python3.10/site-packages -type d -name '__pycache__' -delete

# Create data directory for runtime workspace
RUN mkdir -p /app/data

EXPOSE 8501

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8501/_stcore/health || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
