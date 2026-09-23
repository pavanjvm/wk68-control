#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR="$ROOT_DIR/dist/WK68 Control.app"

mkdir -p "$APP_DIR/Contents/MacOS"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

clang -fobjc-arc -Wall -Wextra \
  -framework Cocoa \
  -framework IOKit \
  "$ROOT_DIR/main.m" \
  -o "$APP_DIR/Contents/MacOS/WK68 Control"

codesign --force --deep --sign - \
  --requirements '=designated => identifier "local.codex.wk68-control"' \
  "$APP_DIR"

echo "Built: $APP_DIR"

