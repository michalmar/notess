.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh release

run: app
	open build/Notess.app

clean:
	swift package clean
	rm -rf build
