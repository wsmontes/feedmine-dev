# Feedmine — Zero-intervention build, install, launch, test

SHELL          := /bin/bash
.SHELLFLAGS    := -o pipefail -ec

DEVICE_14PLUS := 00008110-00067D861486201E
DEVICE_15    := 00008120-000260903ED1A01E
DEVICE       ?= $(DEVICE_14PLUS)
SIM_NAME     := iPhone 14 Plus
PROJECT      := feedmine.xcodeproj
SCHEME       := feedmine

DERIVED_DATA   := .build-device
SIM_DERIVED    := .build-dd
APP_PATH       := $(DERIVED_DATA)/Build/Products/Debug-iphoneos/feedmine.app
RELEASE_APP    := $(DERIVED_DATA)/Build/Products/Release-iphoneos/feedmine.app

.PHONY: all build install launch audit-images \
        test test-device test-device-only \
        test-ui test-ui-device test-ui-sim \
        ui-matrix \
        test-sim test-sim-only \
        analyze build-release archive \
        device-info sim-info clean clean-all

# ── Log directory ────────────────────────────────────────
# Recipes that tee xcodebuild output need this directory to exist first:
# .build/ is gitignored and absent in a fresh checkout.
.build:
	@mkdir -p $@

# ── Device Info ──────────────────────────────────────────
device-info:
	@echo "📱 Connected devices:"
	@xcrun devicectl list devices 2>&1 | head -20
	@echo ""
	@echo "🎯 Target DEVICE: $(DEVICE)"

sim-info:
	@echo "📱 Simulators:"
	@xcrun simctl list devices | grep "$(SIM_NAME)"

# ── Content Diagnostics ──────────────────────────────────
audit-images:
	@test -n "$(IMAGE_AUDIT_DB)" || (echo "Set IMAGE_AUDIT_DB to a copied app SQLite database" && exit 1)
	.venv_feeds/bin/python scripts/diagnose_image_failures.py "$(IMAGE_AUDIT_DB)"

# ── Full Cycle ───────────────────────────────────────────
all: build install launch

# ── Build (Device) ───────────────────────────────────────
build: | .build
	@echo "🔨 Building Feedmine for device..."
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-allowProvisioningUpdates \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration Debug 2>&1 | tee .build/build.log | tail -5

# ── Install ──────────────────────────────────────────────
install:
	@echo "📲 Installing to device..."
	xcrun devicectl device install app --device $(DEVICE) "$(APP_PATH)"

# ── Launch ───────────────────────────────────────────────
launch:
	@echo "🚀 Launching..."
	xcrun devicectl device process launch --device $(DEVICE) com.feedmine.app

# ── Test: Convenience (simulator) ─────────────────────────
test: test-sim
	@true

test-ui: test-ui-sim
	@true

# ── Test: Device ─────────────────────────────────────────
test-device: | .build
	@echo "🧪 [Device] Unit tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-allowProvisioningUpdates \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration Debug \
		-only-testing:feedmineTests 2>&1 | tee .build/test-device.log | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)"

test-device-only: | .build
	@echo "🧪 [Device] Unit tests (no rebuild)..."
	xcodebuild test-without-building -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:feedmineTests 2>&1 | tee .build/test-device.log | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)"

test-ui-device: | .build
	@echo "🧪 [Device] UI tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-allowProvisioningUpdates \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration Debug \
		-only-testing:feedmineUITests 2>&1 | tee .build/test-ui-device.log | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)"

# ── Test: Simulator ──────────────────────────────────────
test-sim: | .build
	@echo "🧪 [Simulator] Unit tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(SIM_NAME)" \
		-derivedDataPath $(SIM_DERIVED) \
		-configuration Debug \
		-only-testing:feedmineTests 2>&1 | tee .build/test-sim.log | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing|error:)"

test-sim-only: | .build
	@echo "🧪 [Simulator] Unit tests (no rebuild)..."
	xcodebuild test-without-building -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(SIM_NAME)" \
		-derivedDataPath $(SIM_DERIVED) \
		-only-testing:feedmineTests 2>&1 | tee .build/test-sim.log | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)"

test-ui-sim: | .build
	@echo "🧪 [Simulator] UI tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(SIM_NAME)" \
		-derivedDataPath $(SIM_DERIVED) \
		-configuration Debug \
		-only-testing:feedmineUITests 2>&1 | tee .build/test-ui-sim.log | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)"

# Journeys + every filter axis on the shared simulator, with the app's own log captured beside the results.
# Serialized through /tmp/feedmine-lane.lock (the device is shared); writes its report under Artifacts/Validation.
ui-matrix:
	@bash scripts/validation/run_ui_matrix.sh

# ── Release ──────────────────────────────────────────────
analyze: | .build
	@echo "🔍 Running static analysis..."
	xcodebuild analyze -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(SIM_NAME)" \
		-derivedDataPath $(SIM_DERIVED) \
		-configuration Release 2>&1 | tee .build/analyze.log | tail -20

build-release: | .build
	@echo "📦 Building Release for device..."
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-allowProvisioningUpdates \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration Release 2>&1 | tee .build/build-release.log | tail -5

archive: test-sim | .build
	@echo "🏷️  Build metadata..."
	@bash scripts/generate_build_info.sh
	@VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" feedmine/Info.plist); \
	BUILD=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" feedmine/Info.plist); \
	GIT_SHA=$$(git rev-parse --short HEAD); \
	GIT_TAG="ios/$$VERSION-build.$$BUILD-$$GIT_SHA"; \
	echo "   Version: $$VERSION ($$BUILD)"; \
	echo "   SHA:     $$GIT_SHA"; \
	echo "   Tag:     $$GIT_TAG"; \
	echo ""
	@echo "🗄️  Archiving..."
	xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-allowProvisioningUpdates \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration Release \
		-archivePath .build/feedmine.xcarchive 2>&1 | tee .build/archive.log | tail -10
	@echo ""
	@echo "✅ Archive complete. To tag this build:"
	@VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" feedmine/Info.plist); \
	BUILD=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" feedmine/Info.plist); \
	GIT_SHA=$$(git rev-parse --short HEAD); \
	echo "   git tag -a ios/$$VERSION-build.$$BUILD-$$GIT_SHA $$GIT_SHA -m \"Release $$VERSION ($$BUILD) [$$GIT_SHA]\""
	@echo "   git push origin ios/$$VERSION-build.$$BUILD-$$GIT_SHA"

# ── Disk / Clean ─────────────────────────────────────────
clean:
	@echo "🧹 Cleaning derived data..."
	rm -rf "$(DERIVED_DATA)" "$(SIM_DERIVED)"
	xcodebuild -project $(PROJECT) clean 2>/dev/null

clean-all: clean
	@echo "🧹 Deep cleaning..."
	rm -rf build .build-* ~/Library/Developer/Xcode/DerivedData/feedmine-*
	@df -h / | tail -1 | awk '{print "   Disk: " $$4 " free (" $$5 " used)"}'
