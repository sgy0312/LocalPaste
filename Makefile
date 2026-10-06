.PHONY: build check clean

build:
	./build.sh

check: build
	"build/本地剪贴板.app/Contents/MacOS/LocalPaste" --self-test

clean:
	rm -rf build/本地剪贴板.app build/module-cache
