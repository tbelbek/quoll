.PHONY: build release test app clean

build:
	cd macos && swift build

release:
	cd macos && swift build -c release

test:
	cd macos && swift run quoll-selftest

app:
	./scripts/build-app.sh

clean:
	rm -rf macos/.build .build
