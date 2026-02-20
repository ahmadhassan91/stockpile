FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Install system dependencies including Python 3.12 and COLMAP
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        software-properties-common \
        gnupg2 \
        curl \
        git \
        libgl1-mesa-glx \
        libglib2.0-0 && \
    # Add Python 3.12 PPA
    add-apt-repository -y ppa:deadsnakes/ppa && \
    # Add COLMAP PPA
    add-apt-repository -y ppa:colmap/colmap && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.12 \
        python3.12-venv \
        python3.12-dev \
        python3.12-distutils \
        colmap && \
    # Install pip for Python 3.12
    curl -sS https://bootstrap.pypa.io/get-pip.py | python3.12 && \
    # Set python3.12 as default python/python3
    update-alternatives --install /usr/bin/python python /usr/bin/python3.12 1 && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 && \
    # Clean up
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project source
COPY pyproject.toml .
COPY stockpile/ stockpile/
COPY app/ app/

# Install the project package itself
RUN pip install --no-cache-dir -e .

# Create data directory for runtime workspace
RUN mkdir -p /app/data

EXPOSE 8501

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8501/_stcore/health || exit 1

ENTRYPOINT ["streamlit", "run", "app/app.py", \
    "--server.port=8501", \
    "--server.address=0.0.0.0"]
