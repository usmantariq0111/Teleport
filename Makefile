.PHONY: build-daemon run-daemon build-ui run-ui

# Daemon commands (requires cargo)
build-daemon:
	cd daemon && cargo build

run-daemon:
	cd daemon && cargo run

# UI commands (requires swift/xcodebuild)
build-ui:
	cd ui && swift build

run-ui:
	cd ui && swift run

# Helper to run both (simplified)
run:
	@echo "Starting Teleport POC..."
	@make -j 2 run-daemon run-ui
