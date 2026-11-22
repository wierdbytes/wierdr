# Wierdr build helpers. See docs/BUILD.md.
# Simulators run the newest installed iOS runtime (created there on first use): scripts/iphone-sim.sh.
SIM_NAME ?= Wierdr iPad Pro 13 (M4)
SIM_TYPE ?= com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-16GB
IPHONE_SIM ?= Wierdr iPhone 13 Pro Max
SIM      := SIM_NAME="$(SIM_NAME)" SIM_TYPE="$(SIM_TYPE)" ./scripts/iphone-sim.sh
DERIVED  := build/DerivedData
XCB      := xcodebuild -project Wierdr.xcodeproj -scheme Wierdr -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation
BUNDLE_ID := pw.xff.wierdr

.PHONY: project test sim sim-build sim-iphone device install install-iphone ipa testflight clean

project:
	xcodegen generate

test:
	cd Packages/WierdrKit && swift test

sim-build: project
	$(XCB) -configuration Debug -destination 'platform=iOS Simulator,name=$(SIM_NAME),OS=latest' build | grep -E "error:|BUILD" | cut -c1-300

# The iPad simulator.
sim: project
	$(SIM) boot >/dev/null
	$(SIM) install
	$(SIM) launch

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

# Archive and upload to App Store Connect (TestFlight); docs/BUILD.md.
testflight:
	./scripts/testflight.sh

clean:
	rm -rf build
