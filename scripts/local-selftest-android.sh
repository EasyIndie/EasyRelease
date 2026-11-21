#!/usr/bin/env bash
# shellcheck disable=SC2015,SC1091
# 本地自测:不需要真实发布证书,用临时 keystore + 现场造的 fixture APK/AAB,
# 覆盖正例、禁词、指纹不符、debuggable、缺 ABI、dry-run、密钥还原与失败路径。
#
# 用法:
#   ANDROID_HOME=/opt/android-sdk bash scripts/local-selftest-android.sh
#
# 依赖:JDK 17+ 与 Android SDK 的 build-tools(与线上 runner 一致)。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../android/scripts/resolve-tools.sh
source "$ROOT/android/scripts/resolve-tools.sh"

# 注意:lib/common.sh 里也有 ok(),所以计数器版本必须**在 source 之后**定义。
pass=0
fail=0
ok() { printf '  ✅ %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  ❌ %s\n' "$*"; fail=$((fail + 1)); }
easyrelease_resolve_tools "" >/dev/null
BT="$EASYRELEASE_BUILD_TOOLS"
echo "build-tools: $BT"

AAPT2="$BT/aapt2"
APKSIGNER="$BT/apksigner"
SDK_ROOT="$(dirname "$(dirname "$BT")")"
ANDROID_JAR=""
for jar in "$SDK_ROOT"/platforms/*/android.jar; do
  [ -f "$jar" ] && ANDROID_JAR="$jar"
done
[ -n "$ANDROID_JAR" ] || { echo "找不到 platforms/*/android.jar,无法造 fixture"; exit 1; }

# ---- fixture:临时 keystore ------------------------------------------------
KS="$TMP/fixture.jks"
STORE_PASS=fixture-store
# PKCS12 的 key 密码跟随 store 密码(keytool 对 .jks/PKCS12 忽略 -keypass),
# 这里保持一致,免得 fixture 自己造出一个与现实不符的密码组合。
KEY_PASS="$STORE_PASS"
"$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KS" -storepass "$STORE_PASS" \
  -keypass "$KEY_PASS" -alias fixture -keyalg RSA -keysize 2048 -validity 30 \
  -dname "CN=EasyRelease Fixture" >/dev/null 2>&1
ok "临时 keystore 已生成"

# ---- fixture:APK ----------------------------------------------------------
make_manifest() { # $1=debuggable(true/false) $2=版本名 $3=版本号
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.easyindie.fixture" android:versionCode="$3" android:versionName="$2">
  <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="34" />
  <application android:label="Fixture" android:debuggable="$1" />
</manifest>
XML
}

make_apk() { # $1=输出 $2=debuggable $3=带 arm64 lib
  local out="$1" debuggable="$2" with_lib="$3"
  local dir; dir="$(mktemp -d "$TMP/apk.XXXXXX")"
  make_manifest "$debuggable" 1.2.3 42 > "$dir/AndroidManifest.xml"
  "$AAPT2" link -o "$dir/base.apk" --manifest "$dir/AndroidManifest.xml" \
    -I "$ANDROID_JAR" >/dev/null 2>&1
  python3 - "$dir/base.apk" "$out" "$with_lib" <<'PY'
import sys, zipfile
src, dst, with_lib = sys.argv[1], sys.argv[2], sys.argv[3] == "yes"
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zo:
    for it in zi.infolist():
        zo.writestr(it, zi.read(it.filename))
    zo.writestr("classes.dex", b"FIXTURE_DEX_PAYLOAD")
    if with_lib:
        zo.writestr("lib/arm64-v8a/libfixture.so", b"fake")
PY
  "$APKSIGNER" sign --ks "$KS" --ks-pass "pass:$STORE_PASS" --key-pass "pass:$KEY_PASS" \
    --ks-key-alias fixture --out "$out.signed" "$out" >/dev/null 2>&1
  mv "$out.signed" "$out"
}

APK="$TMP/fixture.apk"
make_apk "$APK" false yes
ok "fixture APK 已生成并签名"

UNSIGNED_APK="$TMP/fixture-unsigned.apk"
make_unsigned_apk() { # $1=输出
  local dir; dir="$(mktemp -d "$TMP/raw.XXXXXX")"
  make_manifest false 1.2.3 42 > "$dir/AndroidManifest.xml"
  "$AAPT2" link -o "$1" --manifest "$dir/AndroidManifest.xml" -I "$ANDROID_JAR" >/dev/null 2>&1
  python3 - "$1" <<'PY'
import sys, zipfile
p = sys.argv[1]
with zipfile.ZipFile(p, "a", zipfile.ZIP_DEFLATED) as z:
    z.writestr("classes.dex", b"FIXTURE_DEX_PAYLOAD")
    z.writestr("lib/arm64-v8a/libfixture.so", b"fake")
PY
}
make_unsigned_apk "$UNSIGNED_APK"
ok "未签名 fixture APK 已生成"

FINGERPRINT="$("$APKSIGNER" verify --print-certs "$APK" \
  | awk -F': ' '/SHA-256 digest/ { print tolower($NF); exit }')"
[ -n "$FINGERPRINT" ] && ok "fixture 指纹:${FINGERPRINT:0:16}…" || bad "取不到 fixture 指纹"

# ---- fixture:AAB ----------------------------------------------------------
AAB="$TMP/fixture.aab"
python3 - "$AAB" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("BundleConfig.pb", b"fixture")
    z.writestr("base/manifest/AndroidManifest.xml", b"fixture")
    z.writestr("base/dex/classes.dex", b"FIXTURE_DEX_PAYLOAD")
    z.writestr("base/lib/arm64-v8a/libfixture.so", b"fake")
PY
"$EASYRELEASE_TOOL_JARSIGNER" -keystore "$KS" -storepass "$STORE_PASS" \
  -keypass "$KEY_PASS" -sigalg SHA256withRSA -digestalg SHA-256 "$AAB" fixture >/dev/null 2>&1
ok "fixture AAB 已生成并签名"

# ---- 跑 action ------------------------------------------------------------
run_action() { # $1=输出文件,其余为 EASYRELEASE_* 赋值
  local out="$1"
  shift
  env GITHUB_OUTPUT="$out" GITHUB_WORKSPACE="$TMP" RUNNER_TEMP="$TMP" \
    EASYRELEASE_OUTPUT_DIR="$TMP/out-$(basename "$out" .txt)" \
    EASYRELEASE_BUILD_TOOLS="$BT" "$@" \
    bash "$ROOT/android/scripts/main.sh"
}

expect_fail() { # $1=名字,其余同 run_action
  local name="$1"
  shift
  if run_action "$@" >/dev/null 2>&1; then
    bad "$name 应该失败"
  else
    ok "$name 按预期失败"
  fi
}

echo ""
echo "== 正例:APK + AAB =="
OUT="$TMP/ok.txt"
if run_action "$OUT" \
  EASYRELEASE_APK="$APK" EASYRELEASE_AAB="$AAB" \
  EASYRELEASE_EXPECTED_PACKAGE=com.easyindie.fixture \
  EASYRELEASE_EXPECTED_VERSION_NAME=1.2.3 \
  EASYRELEASE_EXPECTED_VERSION_CODE=42 \
  EASYRELEASE_MIN_TARGET_SDK=34 \
  EASYRELEASE_EXPECTED_SHA256="$FINGERPRINT" >/dev/null; then
  M="$(sed -n 's/^manifest_path=//p' "$OUT")"
  python3 -m json.tool "$M" >/dev/null && ok "manifest 是合法 JSON" || bad "manifest JSON"
  python3 - "$M" "$FINGERPRINT" <<'PY' && ok "manifest 字段正确(platform/version/fingerprint/verified)" || bad "manifest 字段"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["platform"] == "android", m
assert m["bundle_id"] == "com.easyindie.fixture", m
assert m["version"] == "1.2.3" and m["build"] == "42", m
assert m["certificate_sha256"] == sys.argv[2], m
assert m["verified"] is True and m["apk_verified"] and m["aab_verified"], m
PY
  grep -qx 'verified=true' "$OUT" && ok "outputs verified=true" || bad "outputs verified"
else
  bad "正例执行失败"
fi

echo "== 禁词命中 =="
expect_fail "禁词命中" "$TMP/forbidden.txt" \
  EASYRELEASE_APK="$APK" EASYRELEASE_FORBIDDEN_STRINGS=FIXTURE_DEX_PAYLOAD

echo "== 指纹不符 =="
expect_fail "指纹不符" "$TMP/fp.txt" \
  EASYRELEASE_APK="$APK" \
  EASYRELEASE_EXPECTED_SHA256=0000000000000000000000000000000000000000000000000000000000000000

echo "== debuggable =="
DEBUG_APK="$TMP/fixture-debuggable.apk"
make_apk "$DEBUG_APK" true yes
expect_fail "debuggable 包" "$TMP/dbg.txt" EASYRELEASE_APK="$DEBUG_APK"

echo "== 缺 ABI =="
NO_LIB_APK="$TMP/fixture-nolib.apk"
make_apk "$NO_LIB_APK" false no
expect_fail "缺 arm64-v8a" "$TMP/abi.txt" EASYRELEASE_APK="$NO_LIB_APK"

echo "== versionCode 不符 =="
expect_fail "versionCode 不符" "$TMP/ver.txt" \
  EASYRELEASE_APK="$APK" EASYRELEASE_EXPECTED_VERSION_CODE=43

echo "== dry-run:失败项不中断 =="
OUT_D="$TMP/dry.txt"
if run_action "$OUT_D" EASYRELEASE_APK="$DEBUG_APK" EASYRELEASE_DRY_RUN=true >/dev/null 2>&1; then
  M_D="$(sed -n 's/^manifest_path=//p' "$OUT_D")"
  python3 - "$M_D" <<'PY' && ok "dry_run 状态正确" || bad "dry-run 状态"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "dry-run", m
assert m["verified"] is False, m
PY
else
  bad "dry-run 执行失败"
fi

echo "== 只给 AAB =="
OUT_A="$TMP/aab-only.txt"
if run_action "$OUT_A" EASYRELEASE_AAB="$AAB" EASYRELEASE_EXPECTED_SHA256="$FINGERPRINT" >/dev/null; then
  grep -qx 'aab=.*fixture.aab' "$OUT_A" && ok "只给 AAB 也能通过" || bad "AAB outputs"
else
  bad "只给 AAB 执行失败"
fi

echo "== mode=sign:未签名 APK 补签 =="
OUT_S="$TMP/sign-apk.txt"
if run_action "$OUT_S" \
  EASYRELEASE_MODE=sign \
  EASYRELEASE_APK="$UNSIGNED_APK" \
  EASYRELEASE_KEYSTORE_BASE64="$(base64 < "$KS" | tr -d '\n')" \
  EASYRELEASE_STORE_PASSWORD="$STORE_PASS" \
  EASYRELEASE_KEY_PASSWORD="$KEY_PASS" \
  EASYRELEASE_KEY_ALIAS=fixture \
  EASYRELEASE_EXPECTED_SHA256="$FINGERPRINT" >/dev/null; then
  SIGNED="$(sed -n 's/^apk=//p' "$OUT_S")"
  grep -qx 'signed=true' "$OUT_S" && ok "signed=true" || bad "signed output"
  case "$SIGNED" in *-signed.apk) ok "输出名带 -signed" ;; *) bad "输出名:$SIGNED" ;; esac
  "$APKSIGNER" verify "$SIGNED" >/dev/null 2>&1 && ok "补签后的 APK 校验通过" || bad "补签 APK 校验"
  M_S="$(sed -n 's/^manifest_path=//p' "$OUT_S")"
  python3 - "$M_S" "$FINGERPRINT" <<'PY' && ok "manifest 记录 mode/signed/指纹" || bad "sign manifest"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["mode"] == "sign" and m["signed"] is True, m
assert m["certificate_sha256"] == sys.argv[2], m
assert m["verified"] is True, m
PY
else
  bad "mode=sign(APK)执行失败"
fi

echo "== mode=sign:未签名 AAB 补签 =="
UNSIGNED_AAB="$TMP/fixture-unsigned.aab"
python3 - "$UNSIGNED_AAB" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("BundleConfig.pb", b"fixture")
    z.writestr("base/manifest/AndroidManifest.xml", b"fixture")
    z.writestr("base/dex/classes.dex", b"FIXTURE_DEX_PAYLOAD")
    z.writestr("base/lib/arm64-v8a/libfixture.so", b"fake")
PY
OUT_SA="$TMP/sign-aab.txt"
if run_action "$OUT_SA" \
  EASYRELEASE_MODE=sign \
  EASYRELEASE_AAB="$UNSIGNED_AAB" \
  EASYRELEASE_KEYSTORE_BASE64="$(base64 < "$KS" | tr -d '\n')" \
  EASYRELEASE_STORE_PASSWORD="$STORE_PASS" \
  EASYRELEASE_KEY_PASSWORD="$KEY_PASS" \
  EASYRELEASE_KEY_ALIAS=fixture \
  EASYRELEASE_EXPECTED_SHA256="$FINGERPRINT" >/dev/null; then
  SIGNED_AAB="$(sed -n 's/^aab=//p' "$OUT_SA")"
  "$EASYRELEASE_TOOL_JARSIGNER" -verify "$SIGNED_AAB" >/dev/null 2>&1 \
    && ok "补签后的 AAB 校验通过" || bad "补签 AAB 校验"
else
  bad "mode=sign(AAB)执行失败"
fi

echo "== mode=sign 缺凭据 =="
expect_fail "sign 缺 keystore" "$TMP/sign-nokey.txt" \
  EASYRELEASE_MODE=sign EASYRELEASE_APK="$UNSIGNED_APK"

echo "== 非法 mode =="
expect_fail "非法 mode" "$TMP/badmode.txt" \
  EASYRELEASE_MODE=signing EASYRELEASE_APK="$APK"

echo "== 失败路径 =="
if run_action "$TMP/none.txt" >/dev/null 2>&1; then
  bad "apk/aab 都为空应失败"
else
  ok "apk/aab 都为空按预期失败"
fi
expect_fail "产物不存在" "$TMP/missing.txt" EASYRELEASE_APK="$TMP/nope.apk"

echo "== keystore 还原 =="
B64="$(base64 < "$KS" | tr -d '\n')"
KS_OUT="$TMP/import/out.txt"
mkdir -p "$TMP/import"
if env GITHUB_OUTPUT="$KS_OUT" RUNNER_TEMP="$TMP" \
  EASYRELEASE_KEYSTORE_BASE64="$B64" \
  EASYRELEASE_KEYSTORE_PATH="$TMP/proj/release.jks" \
  EASYRELEASE_KEYSTORE_PROPERTIES="$TMP/proj/keystore.properties" \
  EASYRELEASE_ALIAS_PROPERTY=alias.Fixture \
  EASYRELEASE_STORE_PASSWORD="$STORE_PASS" \
  EASYRELEASE_KEY_PASSWORD="$KEY_PASS" \
  EASYRELEASE_KEY_ALIAS=fixture \
  bash "$ROOT/android/scripts/import-keystore.sh" >/dev/null 2>&1; then
  [ -f "$TMP/proj/release.jks" ] && ok "keystore 落盘" || bad "keystore 缺失"
  grep -qx 'storeFile=release.jks' "$TMP/proj/keystore.properties" \
    && ok "storeFile 是相对路径" || bad "storeFile 路径"
  grep -qx 'alias.Fixture=fixture' "$TMP/proj/keystore.properties" \
    && ok "自定义别名键生效" || bad "别名键"
  [ "$(stat -c '%a' "$TMP/proj/keystore.properties")" = "600" ] \
    && ok "keystore.properties 权限 600" || bad "properties 权限"
else
  bad "keystore 还原失败"
fi
if env GITHUB_OUTPUT="$TMP/import/bad.txt" RUNNER_TEMP="$TMP" \
  EASYRELEASE_KEYSTORE_BASE64="$B64" \
  EASYRELEASE_KEYSTORE_PATH="$TMP/proj2/release.jks" \
  EASYRELEASE_STORE_PASSWORD=wrong \
  EASYRELEASE_KEY_PASSWORD="$KEY_PASS" \
  EASYRELEASE_KEY_ALIAS=fixture \
  bash "$ROOT/android/scripts/import-keystore.sh" >/dev/null 2>&1; then
  bad "错误 store 密码应失败"
else
  ok "错误 store 密码按预期失败"
fi

echo ""
echo "通过 $pass 项,失败 $fail 项"
[ "$fail" -eq 0 ]
