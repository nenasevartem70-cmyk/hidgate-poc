.PHONY: all build ipa clean

all: ipa

build:
	./build.sh

ipa: build

clean:
	rm -rf build
