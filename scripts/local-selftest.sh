#!/usr/bin/env bash
# shellcheck disable=SC2015
# 本地自测:不需要证书,覆盖 adhoc / dmg / dry-run / 失败路径。
# 用法:bash scripts/local-selftest.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(uname -s)" = "Darwin" ] || { echo "只能在 macOS 上跑"; exit 1; }

pass=0
fail=0
ok() { printf '  ✅ %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  ❌ %s\n' "$*"; fail=$((fail + 1)); }

make_app() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp /bin/echo "$app/Contents/MacOS/Hello"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.easyindie.hello</string>
  <key>CFBundleName</key><string>Hello</string>
  <key>CFBundleExecutable</key><string>Hello</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
}

run_action() {
  local out="$1"
  shift
  env \
    GITHUB_OUTPUT="$out" \
    GITHUB_WORKSPACE="$TMP" \
    RUNNER_TEMP="$TMP" \
    EASYRELEASE_OUTPUT_DIR="$TMP/easyrelease-$(basename "$out" .txt)" \
    "$@" \
    bash "$ROOT/apple/scripts/main.sh"
}

echo "== adhoc .app =="
APP="$TMP/Hello.app"
make_app "$APP"
OUT="$TMP/adhoc.txt"
if run_action "$OUT" EASYRELEASE_ARTIFACT="$APP" EASYRELEASE_MODE=adhoc >/dev/null; then
  grep -qx 'verified=true' "$OUT" && ok "verified=true" || bad "verified"
  M="$(sed -n 's/^manifest_path=//p' "$OUT")"
  python3 -m json.tool "$M" >/dev/null && ok "manifest 是合法 JSON" || bad "manifest JSON"
  plutil -extract platform raw -o - "$M" | grep -qx apple && ok "platform=apple" || bad "platform"
  plutil -extract signed raw -o - "$M" | grep -qx true && ok "signed=true" || bad "signed"
  codesign --verify --deep --strict "$APP" && ok "codesign 校验" || bad "codesign"
else
  bad "adhoc 执行失败"
fi

echo "== adhoc .dmg =="
DMG="$TMP/Hello.dmg"
hdiutil create -quiet -volname Hello -srcfolder "$APP" -ov -format UDZO "$DMG"
OUT2="$TMP/dmg.txt"
if run_action "$OUT2" EASYRELEASE_ARTIFACT="$DMG" EASYRELEASE_MODE=adhoc >/dev/null; then
  M2="$(sed -n 's/^manifest_path=//p' "$OUT2")"
  plutil -extract artifact_kind raw -o - "$M2" | grep -qx dmg && ok "artifact_kind=dmg" || bad "dmg kind"
  grep -qx 'verified=true' "$OUT2" && ok "dmg verified=true" || bad "dmg verified"
else
  bad "dmg 执行失败"
fi

echo "== dry-run(developer-id,无证书)=="
OUT3="$TMP/dry.txt"
if run_action "$OUT3" \
  EASYRELEASE_ARTIFACT="$APP" \
  EASYRELEASE_MODE=developer-id \
  EASYRELEASE_NOTARIZE=true \
  EASYRELEASE_DRY_RUN=true >/dev/null; then
  M3="$(sed -n 's/^manifest_path=//p' "$OUT3")"
  plutil -extract dry_run raw -o - "$M3" | grep -qx true && ok "dry_run=true" || bad "dry_run"
  plutil -extract signed raw -o - "$M3" | grep -qx false && ok "signed=false" || bad "dry signed"
  grep -qx 'verified=false' "$OUT3" && ok "verified=false" || bad "dry verified"
else
  bad "dry-run 执行失败"
fi

echo "== 失败路径 =="
if run_action "$TMP/missing.txt" EASYRELEASE_ARTIFACT="$TMP/nope.app" EASYRELEASE_MODE=adhoc >/dev/null 2>&1; then
  bad "缺产物应失败"
else
  ok "缺产物按预期失败"
fi

if run_action "$TMP/bad-combo.txt" EASYRELEASE_ARTIFACT="$APP" EASYRELEASE_MODE=adhoc EASYRELEASE_NOTARIZE=true >/dev/null 2>&1; then
  bad "adhoc+notarize 应失败"
else
  ok "adhoc+notarize 按预期失败"
fi

if run_action "$TMP/no-cert.txt" EASYRELEASE_ARTIFACT="$APP" EASYRELEASE_MODE=developer-id >/dev/null 2>&1; then
  bad "developer-id 缺证书应失败"
else
  ok "developer-id 缺证书按预期失败"
fi

echo ""
echo "通过 $pass 项,失败 $fail 项"
[ "$fail" -eq 0 ]
