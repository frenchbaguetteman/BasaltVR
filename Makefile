SHELL := /bin/zsh
.DEFAULT_GOAL := help

VERSION ?= 0.1.0
REPO_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: help doctor doctor-runtime doctor-dxmt check test build app runtime-build runtime-test dxmt-verify dxmt-test release

help: ## Show the supported contributor commands.
	@awk 'BEGIN {FS = ":.*## "; print "BasaltVR contributor commands:"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## Check the core macOS and Swift development environment.
	@scripts/doctor.zsh --core

doctor-runtime: ## Check prerequisites for cross-building the OpenXR runtime.
	@scripts/doctor.zsh --runtime

doctor-dxmt: ## Check the complete Wine/DXMT development environment.
	@scripts/doctor.zsh --dxmt

check: ## Run the same repository and Swift checks used by CI.
	@scripts/check.zsh

test: ## Run all deterministic Swift tests.
	@swift test --package-path streamer

build: ## Build all native executables for Apple Silicon.
	@swift build -c release --arch arm64 --package-path streamer

app: build ## Run the management app from source.
	@swift run --package-path streamer BasaltVR

runtime-build: ## Cross-build the Windows OpenXR runtime without running Wine.
	@cmake -S runtime -B runtime/build \
		-DCMAKE_TOOLCHAIN_FILE="$(REPO_DIR)/runtime/cmake/toolchains/mingw-x86_64.cmake" \
		-DCMAKE_BUILD_TYPE=Release
	@cmake --build runtime/build --parallel

runtime-test: ## Run the Wine loader and ABI smoke suite.
	@runtime/scripts/test-wine.zsh

dxmt-verify: ## Inspect built DXMT artifacts without requiring physical Metal access.
	@runtime/scripts/verify-dxmt-artifacts.zsh

dxmt-test: ## Run the complete pinned Wine/DXMT graphics suite.
	@runtime/scripts/test-dxmt.zsh

release: ## Build a local preview archive; pass VERSION=X.Y.Z.
	@packaging/build-release.zsh "$(VERSION)"
