#!/bin/bash
set -e

# Clean up any stale Xvfb lock files
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99

# Start Xvfb (X virtual framebuffer) for headless Qt applications
Xvfb :99 -screen 0 1024x768x24 -ac +extension GLX +render -noreset &
XVFB_PID=$!

# Give Xvfb time to start
sleep 2

# Export display variable
export DISPLAY=:99

# Function to cleanup on exit
cleanup() {
    echo "Shutting down Xvfb..."
    kill $XVFB_PID 2>/dev/null || true
    rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
}
trap cleanup EXIT

# Run Streamlit with headless mode to skip email prompt
exec streamlit run app/app.py \
    --server.port=8501 \
    --server.address=0.0.0.0 \
    --server.headless=true \
    --browser.gatherUsageStats=false
