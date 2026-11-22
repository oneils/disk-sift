.PHONY: test lint format run clean

# Command Line Tools ship the Swift Testing macro plugin in a subdirectory that the default
# build backend doesn't search; point the compiler at it when it exists (harmless under Xcode).
TESTING_PLUGINS := $(wildcard $(dir $(shell xcrun --find swift 2>/dev/null))../lib/swift/host/plugins/testing)
TEST_FLAGS := $(if $(TESTING_PLUGINS),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

test:
	swift test $(TEST_FLAGS)

lint:
	swift format lint --strict -r Package.swift Sources Tests

format:
	swift format format -i -r Package.swift Sources Tests

run:
	swift run DiskSift

clean:
	swift package clean
	rm -rf build
