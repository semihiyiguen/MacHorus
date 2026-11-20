# MacHorus build entry points. Command Line Tools only, no Xcode needed.
#   make build    debug build
#   make test     unit tests (Swift Testing)
#   make sanitize unit tests under Thread and Address Sanitizer
#   make test-scripts  install scripts with stubbed system commands
#   make lint     strict swift-format check (.swift-format) + localization check
#   make format   apply swift-format in place
#   make check    lint + build + test + test-scripts + sanitize (what CI runs)
#   make app      universal release build (Apple Silicon + Intel) + signed build/MacHorus.app
#                 (ad-hoc signed until scripts/setup-signing.sh created a local identity)
#   make run      build and launch the app
#   make release  app + dist/MacHorus-<version>.pkg (installer package)
#   make pkginfo  dist/MacHorus-<version>.pkginfo (for a Munki repository)
#   make clean    remove build output

CLT := /Library/Developer/CommandLineTools
export SDKROOT := $(CLT)/SDKs/MacOSX26.sdk

SWIFT_FLAGS := -Xswiftc -warnings-as-errors
TEST_FLAGS := $(SWIFT_FLAGS) -Xswiftc -plugin-path -Xswiftc $(CLT)/usr/lib/swift/host/plugins/testing

.PHONY: build test test-scripts sanitize lint format check app run release pkginfo clean check-sdk

FORMAT_PATHS := Package.swift Sources Tests scripts

check-sdk:
	@test -d "$(SDKROOT)" || { echo "SDK missing: $(SDKROOT). Install the Command Line Tools: xcode-select --install"; exit 1; }

# Some diagnostics stay warnings despite -warnings-as-errors; fail on any of
# them (linker search-path notes from the Command Line Tools excepted).
# pipefail keeps a failing build failing despite the tee.
build: check-sdk
	@mkdir -p .build
	@bash -o pipefail -c 'swift build $(SWIFT_FLAGS) 2>&1 | tee .build/last-build.log'
	@if grep -E 'warning:' .build/last-build.log | grep -qv 'search path'; then \
		echo "Build has warnings (see above)."; exit 1; fi

test: check-sdk
	swift test $(TEST_FLAGS)

test-scripts:
	scripts/test-postinstall.sh

# Separate scratch paths keep instrumented builds from invalidating the normal one.
sanitize: check-sdk
	swift test --sanitize=thread --scratch-path .build/tsan $(TEST_FLAGS)
	swift test --sanitize=address --scratch-path .build/asan $(TEST_FLAGS)

lint:
	swift format lint --strict --recursive $(FORMAT_PATHS)
	python3 -I scripts/check-localization.py

format:
	swift format format --in-place --recursive $(FORMAT_PATHS)

check: lint build test test-scripts sanitize

# One binary for Apple Silicon and Intel (macOS 14 to 26 still run on Intel
# Macs). Its own scratch path keeps the debug and test builds untouched.
UNIVERSAL := --arch arm64 --arch x86_64 --scratch-path .build/universal

app: check-sdk
	swift build -c release $(SWIFT_FLAGS) $(UNIVERSAL)
	MACHORUS_BINARY="$$(swift build -c release $(UNIVERSAL) --show-bin-path)/MacHorus" scripts/bundle-app.sh

run: app
	-osascript -e 'tell application id "app.machorus.MacHorus" to quit' >/dev/null 2>&1
	open build/MacHorus.app

release: app
	scripts/make-pkg.sh

pkginfo:
	scripts/make-pkginfo.sh

clean:
	rm -rf .build build dist
