#!/bin/bash
# 构建 + 安装 Lull
#   ./build.sh            构建并安装到 ~/Applications 然后启动
#   ./build.sh --build    只构建到 build/，不安装不启动
#   ./build.sh --tools    编译辅助工具到 build/tools/
#   ./build.sh --verify   跑回归断言（会短暂操作 TextEdit 当靶子）
#   ./build.sh --check    零警告编译检查 + 回归断言（提交前跑这个）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Lull"
BUILD_DIR="build"
# 构建暂存放在临时目录：项目目录里的 .app 会被 Spotlight 索引并被 LaunchServices 注册，
# Launchpad 里就会多出第二个 Lull.app
STAGE_ROOT="${TMPDIR:-/tmp}/idle-desktop-stage"
APP="$STAGE_ROOT/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# 本机默认 SDK 可能是坏的（MacOSX27.0.sdk 的 .tbd 里有当前链接器不认的 arm64e.x1-macos 架构），
# 所以逐个试哪个能真链接，而不是直接信 xcrun 的默认值。
pick_sdk() {
  local cands=()
  cands+=("$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)")
  for v in 26.5 26 26.4 15.4 15; do
    cands+=("/Library/Developer/CommandLineTools/SDKs/MacOSX$v.sdk")
  done
  cands+=("$(xcrun --show-sdk-path 2>/dev/null || true)")
  local sdk test=/tmp/idledesk_sdk_test.$$.c
  for sdk in "${cands[@]}"; do
    [ -n "$sdk" ] && [ -d "$sdk" ] || continue
    printf '#include <CoreFoundation/CoreFoundation.h>\nint main(void){return (int)CFEqual(0,0);}\n' > "$test"
    if clang -isysroot "$sdk" -framework CoreFoundation -o "${test}.bin" "$test" >/dev/null 2>&1; then
      rm -f "$test" "${test}.bin"
      echo "$sdk"
      return 0
    fi
    rm -f "$test" "${test}.bin"
  done
  echo ""
  return 1
}

SDK=$(pick_sdk) || true
if [ -z "${SDK:-}" ]; then
  echo "找不到可链接的 macOS SDK。试试：xcode-select --install 或把 CLT 降到与编译器匹配的 SDK" >&2
  exit 1
fi
echo "→ 使用 SDK: $SDK"

# 辅助工具也走同一套 SDK 探测：手工敲 clang 会撞上本机坏掉的默认 SDK
if [ "${1:-}" = "--tools" ]; then
  mkdir -p build/tools
  echo "→ 编译辅助工具"
  base=( -fobjc-arc -mmacosx-version-min=13.0 -isysroot "$SDK" -Wall -Wno-deprecated-declarations -I. )
  clang "${base[@]}" -framework AppKit \
        -o build/tools/render_icons tools/render_icons.m icons.m
  clang "${base[@]}" -framework AppKit -framework Carbon -framework UniformTypeIdentifiers \
        -o build/tools/hotkey_lifecycle tools/hotkey_lifecycle_test.m hotkeys.m
  clang "${base[@]}" -framework AppKit \
        -o build/tools/audit tools/audit_leftovers.m
  echo "→ 产物：build/tools/{render_icons,hotkey_lifecycle,audit}"
  exit 0
fi

# 回归验证 / 完整检查：零警告 + 断言全绿
if [ "${1:-}" = "--verify" ] || [ "${1:-}" = "--check" ]; then
  echo "→ 严格编译检查（-Wall -Werror，警告即失败）"
  clang -fsyntax-only -fobjc-arc -Wall -Werror -Wno-deprecated-declarations -I. \
        main.m hotkeys.m icons.m showdesktop.m probes.m
  echo "→ 编译回归验证工具"
  mkdir -p build/tools
  clang -fobjc-arc -mmacosx-version-min=13.0 -isysroot "$SDK" -Wall -Wno-deprecated-declarations -I. \
        -framework AppKit -framework Carbon -framework UniformTypeIdentifiers -framework IOKit \
        -o build/tools/verify tools/verify.m hotkeys.m probes.m
  echo "→ 运行断言"
  build/tools/verify "$(pwd -P)"
  exit $?
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ 编译"
clang -fobjc-arc -mmacosx-version-min=13.0 -isysroot "$SDK" \
      -Wall -Wno-deprecated-declarations -I. \
      -framework AppKit -framework CoreGraphics -framework IOKit -framework ServiceManagement \
      -framework Carbon -framework UniformTypeIdentifiers \
      -o "$APP/Contents/MacOS/Lull" main.m icons.m hotkeys.m showdesktop.m probes.m

# 优先用钥匙串里已有的开发者身份签名。ad-hoc 签名的指定要求是 cdhash，每次重新编译都变，
# 辅助功能授权就会跟着失效；用真身份签名后 DR 变成 identifier+证书，授权可跨编译保持。
pick_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)"$/\1/p' | head -1
}

SIGN_ID="${SIGN_IDENTITY:-$(pick_identity)}"
if [ -n "$SIGN_ID" ]; then
  echo "→ 签名身份：$SIGN_ID"
else
  echo "→ 没找到可用的代码签名身份，退回 ad-hoc（每次重新编译后辅助功能授权需重新勾选）"
fi

sign_bundle() {   # $1 = bundle 路径
  if [ -n "$SIGN_ID" ] && codesign --force --sign "$SIGN_ID" --timestamp=none "$1" >/dev/null 2>&1; then
    return 0
  fi
  [ -n "$SIGN_ID" ] && echo "  （真身份签名失败，退回 ad-hoc）"
  codesign --force --sign - --timestamp=none "$1" >/dev/null 2>&1 || codesign --force --sign - "$1"
}

# 图标：代码绘制 → iconset → icns（ICON_DESIGN=0 壁纸 / 1 带玻璃窗 / 2 石墨线稿+进度环）
echo "→ 生成 App 图标（设计 ${ICON_DESIGN:-2}）"
mkdir -p build
clang -fobjc-arc -mmacosx-version-min=13.0 -isysroot "$SDK" -Wall -Wno-deprecated-declarations \
      -framework AppKit -o build/make_icon tools/make_icon.m
build/make_icon --write "${ICON_DESIGN:-2}" build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
[ -s "$APP/Contents/Resources/AppIcon.icns" ] || { echo "图标生成失败" >&2; exit 1; }

echo "→ 签名"
sign_bundle "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2
echo "→ 指定要求（含 cdhash 就说明授权无法跨编译保持）：$(codesign -d -r- "$APP" 2>&1 | grep designated | head -1)"

if [ "${1:-}" = "--build" ]; then
  # 产物放进 build/ 时禁止被 Spotlight 索引，并从 LaunchServices 注销 ——
  # 否则 Launchpad 会把它当成第二个 Lull.app
  rm -rf "$BUILD_DIR/$APP_NAME.app"
  mkdir -p "$BUILD_DIR"
  touch "$BUILD_DIR/.metadata_never_index"
  cp -R "$APP" "$BUILD_DIR/"
  "$LSREGISTER" -u "$BUILD_DIR/$APP_NAME.app" 2>/dev/null || true
  echo "→ 只构建模式，产物：$BUILD_DIR/$APP_NAME.app（已禁止索引，不会出现在 Launchpad）"
  exit 0
fi

echo "→ 安装到 $INSTALL_DIR"
# 清掉历史遗留的重复 bundle（构建产物曾被 LaunchServices 注册，导致 Launchpad 出现两个）
if [ -d "$BUILD_DIR/$APP_NAME.app" ]; then
  "$LSREGISTER" -u "$BUILD_DIR/$APP_NAME.app" 2>/dev/null || true
  rm -rf "$BUILD_DIR/$APP_NAME.app"
  echo "  已清理 $BUILD_DIR/$APP_NAME.app（构建产物不该被注册）"
fi
touch "$BUILD_DIR/.metadata_never_index" 2>/dev/null || true
mkdir -p "$INSTALL_DIR"
pkill -x Lull 2>/dev/null || true
sleep 0.4
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"
sign_bundle "$INSTALL_DIR/$APP_NAME.app"
touch "$INSTALL_DIR/$APP_NAME.app"        # 让 Finder/图标缓存重新读取 bundle
"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

open "$INSTALL_DIR/$APP_NAME.app"
sleep 1.5
if pgrep -x Lull >/dev/null; then
  echo "→ 已运行，pid=$(pgrep -x Lull)  日志：~/Library/Logs/Lull.log"
  DUPES=$(find "$HOME" -maxdepth 6 -name "$APP_NAME.app" -prune 2>/dev/null | grep -v "^$INSTALL_DIR/" | grep -v "^$STAGE_ROOT/" || true)
  [ -n "$DUPES" ] && echo "  ⚠ 家目录里还有别的同名 bundle，会让 Launchpad 多出条目：$DUPES"
else
  echo "→ 启动失败，请查看：log show --predicate 'process == \"Lull\"' --last 2m" >&2
  exit 1
fi
