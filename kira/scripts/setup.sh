#!/bin/bash
set -e

echo "========================================"
echo "Kira Setup Script"
echo "========================================"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Check for Python
echo "Checking Python..."
if ! command -v python3 &> /dev/null; then
    echo "Error: Python 3 is required but not installed."
    echo "Install with: brew install python3"
    exit 1
fi
PYTHON_VERSION=$(python3 --version | cut -d' ' -f2)
echo "  Found Python $PYTHON_VERSION"

# Check for Ruby
echo "Checking Ruby..."
if ! command -v ruby &> /dev/null; then
    echo "Error: Ruby is required but not installed."
    echo "Install with: brew install ruby"
    exit 1
fi
RUBY_VERSION=$(ruby --version | cut -d' ' -f2)
echo "  Found Ruby $RUBY_VERSION"

# Check for Bundler
echo "Checking Bundler..."
if ! command -v bundle &> /dev/null; then
    echo "Installing Bundler..."
    gem install bundler
fi
echo "  Found Bundler $(bundle --version | cut -d' ' -f3)"

# Setup Python environment
echo ""
echo "Setting up Python environment..."
cd "$PROJECT_DIR/perception"

if [ ! -d "venv" ]; then
    python3 -m venv venv
    echo "  Created virtual environment"
fi

./venv/bin/pip install --upgrade pip -q
./venv/bin/pip install -r requirements.txt -q
echo "  Installed Python dependencies"

# Setup Ruby environment
echo ""
echo "Setting up Ruby environment..."
cd "$PROJECT_DIR/core"

bundle install --quiet
echo "  Installed Ruby dependencies"

# Check camera access
echo ""
echo "Checking camera access..."
cd "$PROJECT_DIR"
python3 -c "
import cv2
cap = cv2.VideoCapture(0)
if cap.isOpened():
    ret, _ = cap.read()
    cap.release()
    if ret:
        print('  Camera accessible')
    else:
        print('  Warning: Camera opened but cannot read frames')
else:
    print('  Warning: Cannot access camera. Grant permission in System Preferences.')
" 2>/dev/null || echo "  Warning: Cannot check camera (cv2 not available globally)"

# Check for YOLO models (they'll be downloaded on first run)
echo ""
echo "Note: YOLO models will be downloaded on first run (~50MB)"

echo ""
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "To start Kira:"
echo "  cd $(basename "$PROJECT_DIR")"
echo "  make start"
echo ""
echo "Or with a specific profile:"
echo "  make start PROFILE=therapy"
echo "  make start PROFILE=fitness"
echo ""
echo "For help:"
echo "  make help"
