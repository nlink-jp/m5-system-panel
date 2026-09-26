APP_NAME    := M5SystemPanel
NAME        := m5-system-panel
BUNDLE_ID   := jp.nlink.m5-system-panel
VERSION     := $(shell git describe --tags --always --dirty 2>/dev/null || echo "0.1.0")
BUILD_DIR   := .build/release
DIST_DIR    := dist
APP_BUNDLE  := $(DIST_DIR)/$(APP_NAME).app

# macOS Developer ID signing / notarization (see nlink-jp/.github CONVENTIONS.md
# §Code Signing → GUI apps). Pure SwiftUI/AppKit needs no JIT entitlements —
# Hardened Runtime alone suffices. The only OS permission the app asks for is
# local network access (Info.plist: NSLocalNetworkUsageDescription).
CODESIGN_IDENTITY ?= Developer ID Application
NOTARY_PROFILE    ?= nlink-jp-notary
CODESIGN_SCRIPT := scripts/codesign-darwin-app.sh
NOTARIZE_SCRIPT := scripts/notarize-darwin-app.sh

# macOS records the SDK an app was linked against in LC_BUILD_VERSION, and the
# system reads that field to decide which generation of window chrome to draw.
# Since the Xcode 27 / Swift 6.4 toolchain, `swift build` stamps it with the
# deployment target instead of the SDK actually used; passing -platform_version
# explicitly restores it (measured in net-meter). MACOS_MIN is read from
# Package.swift so there is one deployment target, not two.
MACOS_MIN := $(shell sed -n -e 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1.0/p' \
                            -e 's/.*\.macOS("\([0-9][0-9.]*\)").*/\1/p' Package.swift | head -1)
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-version)
SDK_LINK_FLAGS := -Xlinker -platform_version -Xlinker macos -Xlinker $(MACOS_MIN) -Xlinker $(MACOS_SDK)

# --- firmware (M5Stack BASIC v2.7) -------------------------------------------
# Built with arduino-cli against pinned versions; `firmware-deps` refuses a build
# against anything else, because the board definition and M5Unified change
# behaviour between releases.
FQBN              := esp32:esp32:m5stack_core
# BASIC v2.7 has 16 MB flash (esptool flash-id). huge_app gives the app 3 MB and
# no OTA slot; OTA is out of scope, and the Phase 0 probe alone used 88 % of the
# default 1.25 MB partition (ADR-0001).
FW_BOARD_OPTIONS  := FlashSize=16M,PartitionScheme=huge_app
FW_CORE           := esp32:esp32
FW_CORE_VERSION   := 3.3.8
FW_LIBS           := M5Unified=0.2.14 M5GFX=0.2.27
SKETCH_DIR        := firmware/m5-system-panel
# The build directory itself is the artifact directory. --output-dir / -e would
# trigger the core's export hook, which copies binaries (with this machine's
# absolute paths in .map and build.options.json) into $(SKETCH_DIR)/build —
# inside the source tree (knowledge: embedded.md).
FW_BUILD_DIR      := $(abspath $(DIST_DIR)/firmware)
# The core's default upload speed (1500000) fails on BASIC v2.7's CH9102F from
# macOS; 230400 was measured to work (knowledge: embedded.md).
FW_UPLOAD_SPEED   := 230400

.PHONY: build build-app package verify-release test run clean \
        firmware firmware-deps firmware-upload spike-firmware spike-upload spike-app \
        protocol-test protocol-test-upload firmware-package

## build: build the companion's release binary
build:
	@mkdir -p $(DIST_DIR)
	@test -n "$(MACOS_MIN)" || { echo "Makefile: no macOS deployment target found in Package.swift"; exit 1; }
	@test -n "$(MACOS_SDK)" || { echo "Makefile: xcrun could not report the macOS SDK version"; exit 1; }
	swift build -c release $(SDK_LINK_FLAGS)

## build-app: assemble the signed .app bundle
build-app: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@sed 's/$${VERSION}/$(VERSION)/g; s/$${BUNDLE_ID}/$(BUNDLE_ID)/g; s/$${APP_NAME}/$(APP_NAME)/g' \
		Info.plist > $(APP_BUNDLE)/Contents/Info.plist
	@printf 'APPL????' > $(APP_BUNDLE)/Contents/PkgInfo
	@$(CODESIGN_SCRIPT) $(APP_BUNDLE) "$(CODESIGN_IDENTITY)"
	@echo "Built $(APP_BUNDLE) ($(VERSION))"

## package: build-app, notarize + staple the .app, then zip for release
package: build-app
	@$(NOTARIZE_SCRIPT) $(APP_BUNDLE) "$(NOTARY_PROFILE)"
	@cd $(DIST_DIR) && /usr/bin/ditto -c -k --keepParent $(APP_NAME).app $(NAME)-$(VERSION)-darwin-arm64.zip
	@ls -la $(DIST_DIR)/$(NAME)-$(VERSION)-darwin-arm64.zip

## verify-release: refuse to release an un-notarized build (marker + staple gate)
verify-release:
	@test -f "$(APP_BUNDLE).notarized" || { \
		echo "verify-release: FAIL — $(APP_BUNDLE) has no notarization marker."; \
		echo "  make package must end with '[notarize-app] ...: Accepted and stapled'. Do not upload."; \
		exit 1; }
	@xcrun stapler validate $(APP_BUNDLE)
	@test -f "$(DIST_DIR)/$(NAME)-$(VERSION)-darwin-arm64.zip" || { \
		echo "verify-release: FAIL — release zip missing: $(DIST_DIR)/$(NAME)-$(VERSION)-darwin-arm64.zip"; exit 1; }
	@sdk=$$(otool -l "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" | awk '/LC_BUILD_VERSION/{f=1} f && /^ *sdk /{print $$2; exit}'); \
		test "$$sdk" = "$(MACOS_SDK)" || { \
			echo "verify-release: FAIL — linked SDK is $$sdk, expected $(MACOS_SDK)."; exit 1; }
	@# spctl can fail on its very first run on a machine; run verify-release again before concluding.
	@spctl --assess --type execute -vv $(APP_BUNDLE) 2>&1 | grep -q "source=Notarized Developer ID" || { \
		echo "verify-release: FAIL — Gatekeeper does not accept $(APP_BUNDLE) as Notarized Developer ID."; exit 1; }
	@test -f "$(DIST_DIR)/$(FW_ARCHIVE)" || { \
		echo "verify-release: FAIL — firmware archive missing: $(DIST_DIR)/$(FW_ARCHIVE) (make firmware-package)"; exit 1; }
	@unzip -l "$(DIST_DIR)/$(FW_ARCHIVE)" | grep -q "m5-system-panel.bin" || { \
		echo "verify-release: FAIL — the firmware archive has no application image."; exit 1; }
	@unzip -p "$(DIST_DIR)/$(FW_ARCHIVE)" m5-system-panel.bin | strings | grep -qxF "m5-system-panel $(VERSION)" || { \
		echo "verify-release: FAIL — the firmware in the archive is not $(VERSION)."; exit 1; }
	@echo "verify-release: OK ($(VERSION) — marker present, ticket stapled, Gatekeeper accepts, SDK $(MACOS_SDK), firmware $(FW_ARCHIVE))"

## test: companion unit tests (they also check the firmware's shared constants)
test:
	swift test

## run: build and run the companion (debug; no bundle, so no local network prompt)
run:
	swift run

## firmware-deps: refuse to build against unpinned core or library versions
firmware-deps:
	@arduino-cli core list --json | python3 -c 'import json,sys; \
want="$(FW_CORE_VERSION)"; \
got=[p.get("installed_version") for p in json.load(sys.stdin).get("platforms",[]) if p.get("id")=="$(FW_CORE)"]; \
sys.exit(0) if got==[want] else sys.exit("firmware-deps: $(FW_CORE) is %s, need %s (arduino-cli core install $(FW_CORE)@%s)" % (got or "not installed", want, want))'
	@arduino-cli lib list --json | python3 -c 'import json,sys; \
want=dict(x.split("=") for x in "$(FW_LIBS)".split()); \
got={e["library"]["name"]:e["library"].get("version") for e in json.load(sys.stdin).get("installed_libraries",[])}; \
bad=["%s is %s, need %s" % (n, got.get(n,"not installed"), v) for n,v in want.items() if got.get(n)!=v]; \
sys.exit("firmware-deps: " + "; ".join(bad)) if bad else sys.exit(0)'

## firmware: compile the M5 firmware into dist/firmware
firmware: firmware-deps
	@mkdir -p $(FW_BUILD_DIR)
	arduino-cli compile --fqbn $(FQBN) --board-options $(FW_BOARD_OPTIONS) --build-path $(FW_BUILD_DIR) \
		--libraries $(abspath firmware/libraries) \
		--build-property "compiler.cpp.extra_flags='-DFW_VERSION=\"$(VERSION)\"'" \
		$(SKETCH_DIR)
	@test ! -e $(SKETCH_DIR)/build || { echo "firmware: $(SKETCH_DIR)/build was created — build artifacts must stay in dist/"; exit 1; }
	@# The whole line "m5-system-panel <version>": the linker merges the standalone
	@# version literal into its tail, and a bare substring match would let
	@# "<version>-dirty" pass for "<version>".
	@strings $(FW_BUILD_DIR)/$(notdir $(SKETCH_DIR)).ino.bin | grep -qxF "m5-system-panel $(VERSION)" || { \
		echo "firmware: version $(VERSION) is not embedded in the binary"; exit 1; }
	@echo "Built $(FW_BUILD_DIR)/$(notdir $(SKETCH_DIR)).ino.bin ($(VERSION))"

## firmware-upload: flash the built firmware; PORT is required (e.g. PORT=/dev/cu.usbserial-XXXX)
firmware-upload:
	@test -n "$(PORT)" || { echo "firmware-upload: set PORT (ls /dev/cu.usbserial-*)"; exit 1; }
	@test -f $(FW_BUILD_DIR)/$(notdir $(SKETCH_DIR)).ino.bin || { echo "firmware-upload: run make firmware first"; exit 1; }
	arduino-cli upload --fqbn $(FQBN) --board-options $(FW_BOARD_OPTIONS),UploadSpeed=$(FW_UPLOAD_SPEED) \
		--input-dir $(FW_BUILD_DIR) -p $(PORT) $(SKETCH_DIR)

# --- Phase 0 probes (spikes/; not shipped) -----------------------------------
SPIKE_FW_DIR   := spikes/firmware/phase0
SPIKE_FW_BUILD := $(abspath $(DIST_DIR)/spike/firmware)
SPIKE_APP      := $(DIST_DIR)/spike/Phase0Probe.app

## spike-firmware: compile the Phase 0 probe firmware (needs spikes/firmware/phase0/wifi_local.h)
spike-firmware: firmware-deps
	@test -f $(SPIKE_FW_DIR)/wifi_local.h || { echo "spike-firmware: copy $(SPIKE_FW_DIR)/wifi_local.h.example to wifi_local.h and fill it in"; exit 1; }
	@mkdir -p $(SPIKE_FW_BUILD)
	arduino-cli compile --fqbn $(FQBN) --board-options $(FW_BOARD_OPTIONS) --build-path $(SPIKE_FW_BUILD) $(SPIKE_FW_DIR)
	@test ! -e $(SPIKE_FW_DIR)/build || { echo "spike-firmware: $(SPIKE_FW_DIR)/build was created"; exit 1; }

## spike-upload: flash the probe firmware; PORT is required
spike-upload:
	@test -n "$(PORT)" || { echo "spike-upload: set PORT (ls /dev/cu.usbserial-*)"; exit 1; }
	arduino-cli upload --fqbn $(FQBN) --board-options $(FW_BOARD_OPTIONS),UploadSpeed=$(FW_UPLOAD_SPEED) \
		--input-dir $(SPIKE_FW_BUILD) -p $(PORT) $(SPIKE_FW_DIR)

## spike-app: build the signed Phase 0 probe app (same bundle id as the companion)
spike-app:
	@rm -rf $(SPIKE_APP)
	@mkdir -p $(SPIKE_APP)/Contents/MacOS
	xcrun swiftc -O -swift-version 5 -target arm64-apple-macos$(MACOS_MIN) \
		-o $(SPIKE_APP)/Contents/MacOS/Phase0Probe spikes/mac/Phase0Probe.swift
	@cp spikes/mac/Info.plist $(SPIKE_APP)/Contents/Info.plist
	@$(CODESIGN_SCRIPT) $(SPIKE_APP) "$(CODESIGN_IDENTITY)"

# --- protocol test (on-device check of firmware/libraries/PanelProtocol) -----
PT_DIR     := firmware/protocol-test
PT_BUILD   := $(abspath $(DIST_DIR)/protocol-test)
FW_LIBS_DIR := $(abspath firmware/libraries)

## protocol-test: generate vectors.h from testdata and compile the test sketch
protocol-test: firmware-deps
	python3 scripts/gen-firmware-vectors.py testdata/protocol-v1.json $(PT_DIR)/vectors.h
	@mkdir -p $(PT_BUILD)
	arduino-cli compile --fqbn $(FQBN) --board-options $(FW_BOARD_OPTIONS) --libraries $(FW_LIBS_DIR) \
		--build-path $(PT_BUILD) $(PT_DIR)
	@test ! -e $(PT_DIR)/build || { echo "protocol-test: $(PT_DIR)/build was created"; exit 1; }

## protocol-test-upload: flash the test sketch; PORT is required
protocol-test-upload:
	@test -n "$(PORT)" || { echo "protocol-test-upload: set PORT (ls /dev/cu.usbserial-*)"; exit 1; }
	arduino-cli upload --fqbn $(FQBN) --board-options $(FW_BOARD_OPTIONS),UploadSpeed=$(FW_UPLOAD_SPEED) \
		--input-dir $(PT_BUILD) -p $(PORT) $(PT_DIR)

## firmware-package: the release archive of the firmware (four images + instructions)
# The four images are the ones `arduino-cli upload` writes, at the same offsets
# (0x1000 bootloader, 0x8000 partitions, 0xe000 boot_app0, 0x10000 app). The
# 16 MB merged image is not shipped: it takes ~12 minutes at 230400 baud and
# would overwrite the settings (NVS) on every update.
FW_ARCHIVE    := $(NAME)-firmware-$(VERSION)-m5stack-basic.zip
FW_BOOT_APP0  := $(firstword $(wildcard $(HOME)/Library/Arduino15/packages/esp32/hardware/esp32/$(FW_CORE_VERSION)/tools/partitions/boot_app0.bin))
firmware-package: firmware
	@test -n "$(FW_BOOT_APP0)" || { echo "firmware-package: boot_app0.bin of esp32 core $(FW_CORE_VERSION) not found"; exit 1; }
	@rm -rf $(DIST_DIR)/fw-stage && mkdir -p $(DIST_DIR)/fw-stage
	@cp $(FW_BUILD_DIR)/$(notdir $(SKETCH_DIR)).ino.bootloader.bin $(DIST_DIR)/fw-stage/bootloader.bin
	@cp $(FW_BUILD_DIR)/$(notdir $(SKETCH_DIR)).ino.partitions.bin $(DIST_DIR)/fw-stage/partitions.bin
	@cp $(FW_BOOT_APP0) $(DIST_DIR)/fw-stage/boot_app0.bin
	@cp $(FW_BUILD_DIR)/$(notdir $(SKETCH_DIR)).ino.bin $(DIST_DIR)/fw-stage/m5-system-panel.bin
	@cp README.md README.ja.md LICENSE $(DIST_DIR)/fw-stage/
	@rm -f $(DIST_DIR)/$(FW_ARCHIVE)
	@cd $(DIST_DIR)/fw-stage && COPYFILE_DISABLE=1 /usr/bin/zip -X -q ../$(FW_ARCHIVE) *
	@rm -rf $(DIST_DIR)/fw-stage
	@ls -la $(DIST_DIR)/$(FW_ARCHIVE)

## clean: remove build artifacts
clean:
	rm -rf $(DIST_DIR) .build

# Homebrew tap generation (see scripts/release-brew.mk). After `make package`,
# `make brew` generates the cask from the built darwin-arm64 zip into the local
# nlink-jp/homebrew-tap checkout. The zip is named after $(NAME); the .app inside
# is $(APP_NAME).app.
BREW_KIND := cask
BREW_DESC := Menu-bar companion that shows CPU, GPU, memory and network on an M5Stack panel
BREW_NAME := $(NAME)
BREW_APP := $(APP_NAME).app
BREW_BUNDLE_ID := $(BUNDLE_ID)
# macOS 26 is :tahoe in Homebrew's RELEASES table (Package.swift targets 26).
BREW_MACOS_FLOOR := :tahoe
include scripts/release-brew.mk
