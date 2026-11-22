.PHONY: test lint format app check-app run clean

# version baked into the app bundle; releases pass the tag (VERSION=1.2.3)
VERSION ?= 0.0.0

# Command Line Tools ship the Swift Testing macro plugin in a subdirectory that the default
# build backend doesn't search; point the compiler at it, but only when the active developer dir
# is CLT (Xcode finds the plugin on its own).
ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
TESTING_PLUGINS := $(wildcard $(dir $(shell xcrun --find swift 2>/dev/null))../lib/swift/host/plugins/testing)
endif
TEST_FLAGS := $(if $(TESTING_PLUGINS),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

test:
	swift test $(TEST_FLAGS)

lint:
	swift format lint --strict -r Package.swift Sources Tests

format:
	swift format format -i -r Package.swift Sources Tests

app:
	scripts/make-app.sh $(VERSION)

check-app:
	scripts/check-app.sh

run:
	swift run DiskSift

clean:
	swift package clean
	rm -rf build
