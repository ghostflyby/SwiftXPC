#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"

swift build --package-path "${DEMO_DIR}" -c "${BUILD_CONFIGURATION}"
BIN_DIR="$(swift build --package-path "${DEMO_DIR}" -c "${BUILD_CONFIGURATION}" --show-bin-path)"

APP_BUNDLE="${DEMO_DIR}/.build/demo/DistributedXPCDemo.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
SERVICE_CONTENTS="${APP_CONTENTS}/XPCServices/DemoService.xpc/Contents"

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_CONTENTS}/MacOS"
mkdir -p "${SERVICE_CONTENTS}/MacOS"

cp "${BIN_DIR}/DemoApp" "${APP_CONTENTS}/MacOS/DemoApp"
cp "${BIN_DIR}/DemoService" "${SERVICE_CONTENTS}/MacOS/DemoService"
cp "${DEMO_DIR}/Resources/DemoApp-Info.plist" "${APP_CONTENTS}/Info.plist"
cp "${DEMO_DIR}/Resources/DemoService-Info.plist" "${SERVICE_CONTENTS}/Info.plist"

if [[ "${SKIP_CODESIGN:-0}" != "1" ]] && command -v codesign >/dev/null 2>&1; then
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
  codesign --force --sign "${CODESIGN_IDENTITY}" "${APP_CONTENTS}/XPCServices/DemoService.xpc"
  codesign --force --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}"
fi

echo "${APP_BUNDLE}"
