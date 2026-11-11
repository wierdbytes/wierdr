# Wierdr build helpers. See docs/BUILD.md.
SIM_NAME ?= Wierdr iPad Pro 13 (M4)
IPHONE_SIM ?= Wierdr iPhone 13 Pro Max
DERIVED  := build/DerivedData
XCB      := xcodebuild -project Wierdr.xcodeproj -scheme Wierdr -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation
BUNDLE_ID := pw.xff.wierdr

.PHONY: project test sim sim-build sim-iphone device install install-iphone ipa clean

project:
	xcodegen generate

test:
	cd Packages/WierdrKit && swift test

sim-build: project
	$(XCB) -configuration Debug -destination 'platform=iOS Simulator,name=$(SIM_NAME)' build | grep -E "error:|BUILD" | cut -c1-300

sim: sim-build
	xcrun simctl boot "$(SIM_NAME)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIM_NAME)" $(DERIVED)/Build/Products/Debug-iphonesimulator/Wierdr.app
	xcrun simctl launch "$(SIM_NAME)" $(BUNDLE_ID)

# The iPhone simulator (created on first use), demo mode. Drive it: scripts/iphone-sim.sh.
sim-iphone: project
	SIM_NAME="$(IPHONE_SIM)" ./scripts/iphone-sim.sh boot >/dev/null
	SIM_NAME="$(IPHONE_SIM)" ./scripts/iphone-sim.sh install
	SIM_NAME="$(IPHONE_SIM)" ./scripts/iphone-sim.sh launch -demo YES

# Release by default: SwiftTerm parses output ~7x faster than in Debug.
CONFIG ?= Release

device: project
	$(XCB) -configuration $(CONFIG) -destination 'generic/platform=iOS' -allowProvisioningUpdates build | grep -E "error:|BUILD" | cut -c1-300

# Installs on the first connected iPad (or DEVICE=<udid|name>).
install: device
	./scripts/install-device.sh $(DERIVED)/Build/Products/$(CONFIG)-iphoneos/Wierdr.app $(DEVICE)

# Installs on the first connected iPhone.
install-iphone: device
	./scripts/install-device.sh $(DERIVED)/Build/Products/$(CONFIG)-iphoneos/Wierdr.app iphone

ipa: project
	./scripts/make-ipa.sh

clean:
	rm -rf build
