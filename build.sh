#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
build_dir="$script_dir/build"
app_dir="$build_dir/本地剪贴板.app"
module_cache="$build_dir/module-cache"
source_dir="$script_dir/Sources/LocalPaste"

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
architecture=$(uname -m)
mkdir -p "$app_dir/Contents/MacOS" "$module_cache"
cp "$script_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

CLANG_MODULE_CACHE_PATH="$module_cache" swiftc \
  -swift-version 5 \
  -target "$architecture-apple-macosx13.0" \
  -O \
  -sdk "$sdk_path" \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  "$source_dir"/*.swift \
  -o "$app_dir/Contents/MacOS/LocalPaste"

codesign --force --deep --sign - "$app_dir" >/dev/null
printf '%s\n' "$app_dir"
