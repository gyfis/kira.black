.PHONY: setup setup-python setup-ruby start start-perception start-core test test-ruby test-python clean help

SOCKET_PATH := /tmp/kira.sock
PROFILE := base
OUTPUT := log

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
NC := \033[0m

help:
	@echo "Kira - Real-time Perception Pipeline"
	@echo ""
	@echo "Usage:"
	@echo "  make setup           - Install all dependencies"
	@echo "  make start           - Start both perception and core services"
	@echo "  make start-perception - Start only the Python perception service"
	@echo "  make start-core      - Start only the Ruby core service"
	@echo "  make test            - Run all tests"
	@echo "  make clean           - Clean up build artifacts"
	@echo ""
	@echo "Options (use with start commands):"
	@echo "  PROFILE=therapy      - Use therapy profile (default: base)"
	@echo "  OUTPUT=json          - Output mode: log, json, verbose, stream"
	@echo ""
	@echo "Examples:"
	@echo "  make start PROFILE=fitness OUTPUT=verbose"
	@echo "  make start-core PROFILE=therapy OUTPUT=json"

setup: setup-python setup-ruby
	@echo "$(GREEN)Setup complete!$(NC)"
	@echo ""
	@echo "To start Kira:"
	@echo "  make start"
	@echo ""
	@echo "First time? The perception service will download YOLO models (~50MB)"

setup-python:
	@echo "$(YELLOW)Setting up Python environment...$(NC)"
	cd perception && python3 -m venv venv
	cd perception && ./venv/bin/pip install --upgrade pip
	cd perception && ./venv/bin/pip install -r requirements.txt
	@echo "$(GREEN)Python setup complete$(NC)"

setup-ruby:
	@echo "$(YELLOW)Setting up Ruby environment...$(NC)"
	cd core && bundle install
	@echo "$(GREEN)Ruby setup complete$(NC)"

start: check-camera
	@echo "$(GREEN)Starting Kira...$(NC)"
	@echo "Profile: $(PROFILE)"
	@echo "Output: $(OUTPUT)"
	@echo ""
	@echo "Starting perception service in background..."
	@rm -f $(SOCKET_PATH)
	@cd perception && ./venv/bin/python -m perception --socket $(SOCKET_PATH) &
	@sleep 3
	@echo "Starting core service..."
	@cd core && bundle exec bin/kira --profile $(PROFILE) --socket $(SOCKET_PATH) --output $(OUTPUT)

start-perception:
	@echo "$(GREEN)Starting perception service...$(NC)"
	@rm -f $(SOCKET_PATH)
	cd perception && ./venv/bin/python -m perception --socket $(SOCKET_PATH)

start-core:
	@echo "$(GREEN)Starting core service...$(NC)"
	cd core && bundle exec bin/kira --profile $(PROFILE) --socket $(SOCKET_PATH) --output $(OUTPUT)

test: test-ruby test-python
	@echo "$(GREEN)All tests passed!$(NC)"

test-ruby:
	@echo "$(YELLOW)Running Ruby tests...$(NC)"
	cd core && bundle exec rspec

test-python:
	@echo "$(YELLOW)Running Python tests...$(NC)"
	cd perception && ./venv/bin/pytest

check-camera:
	@echo "Checking camera access..."
	@python3 -c "import cv2; c=cv2.VideoCapture(0); ret,_=c.read(); c.release(); exit(0 if ret else 1)" 2>/dev/null || \
		(echo "$(YELLOW)Warning: Camera not accessible. Grant camera permissions.$(NC)" && exit 0)

clean:
	@echo "Cleaning up..."
	rm -f $(SOCKET_PATH)
	rm -rf perception/venv
	rm -rf perception/__pycache__
	rm -rf perception/perception/__pycache__
	rm -rf core/.bundle
	find . -name "*.pyc" -delete
	find . -name ".pytest_cache" -type d -exec rm -rf {} +
	@echo "$(GREEN)Clean complete$(NC)"

# Development helpers
dev-perception:
	@echo "Starting perception in development mode..."
	cd perception && ./venv/bin/python -m perception --socket $(SOCKET_PATH) --fps 15

dev-core:
	@echo "Starting core in verbose mode..."
	cd core && bundle exec bin/kira --profile $(PROFILE) --socket $(SOCKET_PATH) -v

# Record perception data for tests
record-fixture:
	@echo "Recording perception fixture..."
	@mkdir -p core/spec/fixtures/perception_sequences
	cd perception && ./venv/bin/python -c "from perception.capture import CameraCapture; from perception.inference import PerceptionModels; import msgpack; import time; c=CameraCapture(); m=PerceptionModels(); c.open(); m.load(); frames=[]; start=time.time(); \
	[frames.append({'frame_id':i,'timestamp_ms':int((time.time()-start)*1000),'detections':m.to_dict(m.process(c.read().image))['detections'],'poses':[]}) for i in range(300) if c.read()]; \
	c.release(); open('../core/spec/fixtures/perception_sequences/test_$(shell date +%s).msgpack','wb').write(msgpack.packb(frames)); print(f'Recorded {len(frames)} frames')"
