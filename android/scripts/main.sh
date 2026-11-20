#!/usr/bin/env bash
# shellcheck disable=SC1091
# EasyRelease Android 入口:校验 APK / AAB → 生成 manifest → 输出。
# 由 android/action.yml 调用,所有输入通过 EASYRELEASE_* 环境变量传入。
#
# 为什么 v0.1.0 只校验不签名:绝大多数 Gradle 工程在构建期就用签名配置签好了
# (密钥由 CI 在构建前还原),事后重签只会破坏 v2/v3 签名链与 Play 的 upload key。
# 需要「构建产物未签名、发布时再签」的场景留给 android-v0.2.0 的 mode=sign。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
source "$SCRIPT_DIR/resolve-tools.sh"
source "$SCRIPT_DIR/verify.sh"

APK_INPUT="${EASYRELEASE_APK:-}"
AAB_INPUT="${EASYRELEASE_AAB:-}"
EXPECTED_PACKAGE="${EASYRELEASE_EXPECTED_PACKAGE:-}"
EXPECTED_VERSION_NAME="${EASYRELEASE_EXPECTED_VERSION_NAME:-}"
EXPECTED_VERSION_CODE="${EASYRELEASE_EXPECTED_VERSION_CODE:-}"
EXPECTED_SHA256="${EASYRELEASE_EXPECTED_SHA256:-}"
FORBIDDEN_STRINGS="${EASYRELEASE_FORBIDDEN_STRINGS:-}"
REQUIRE_ABIS="${EASYRELEASE_REQUIRE_ABIS-arm64-v8a}"
MIN_TARGET_SDK="${EASYRELEASE_MIN_TARGET_SDK:-}"
BUILD_TOOLS_INPUT="${EASYRELEASE_BUILD_TOOLS:-}"
DRY_RUN="${EASYRELEASE_DRY_RUN:-false}"
OUTPUT_DIR="${EASYRELEASE_OUTPUT_DIR:-}"
DEBUG="${EASYRELEASE_DEBUG:-false}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
RUNNER_TEMP_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

WORK="$(mktemp -d "$RUNNER_TEMP_DIR/easyrelease-android.XXXXXX")"
easyrelease_temp "$WORK"
trap 'easyrelease_cleanup_temp' EXIT

[ -n "$APK_INPUT" ] || [ -n "$AAB_INPUT" ] || die "apk 与 aab 至少要有一个"
[ -n "$APK_INPUT" ] && APK="$(abspath "$APK_INPUT")" || APK=""
[ -n "$AAB_INPUT" ] && AAB="$(abspath "$AAB_INPUT")" || AAB=""

easyrelease_resolve_tools "$BUILD_TOOLS_INPUT"

note "EasyRelease Android"
printf '  apk          : %s\n' "${APK:-—}"
printf '  aab          : %s\n' "${AAB:-—}"
printf '  build-tools  : %s\n' "$EASYRELEASE_BUILD_TOOLS"
printf '  expect pkg   : %s\n' "${EXPECTED_PACKAGE:-—}"
printf '  expect ver   : %s\n' "${EXPECTED_VERSION_NAME:-—}"
printf '  expect code  : %s\n' "${EXPECTED_VERSION_CODE:-—}"
printf '  require abis : %s\n' "${REQUIRE_ABIS:-—}"
printf '  min target   : %s\n' "${MIN_TARGET_SDK:-—}"
printf '  forbid       : %s\n' "${FORBIDDEN_STRINGS:-—}"
printf '  dry_run      : %s\n' "$(is_true "$DRY_RUN" && echo true || echo false)"
if is_true "$DEBUG"; then
  printf '  jdk          : %s\n' "$("$EASYRELEASE_TOOL_JARSIGNER" -help 2>/dev/null | sed -n '1p' || true)"
  printf '  uname        : %s\n' "$(uname -srm)"
fi
end_note

note "校验"
if [ -n "$APK" ]; then
  _ar_check_apk "$APK" "$EXPECTED_PACKAGE" "$EXPECTED_VERSION_NAME" "$EXPECTED_VERSION_CODE" \
    "$EXPECTED_SHA256" "$FORBIDDEN_STRINGS" "$REQUIRE_ABIS" "$MIN_TARGET_SDK" "$WORK"
else
  # 只给 AAB 时,包名/版本仍从 APK 拿不到,记录为空即可。
  warn "没有 apk,跳过 APK 相关校验(版本 / 签名指纹 / ABI 检查依赖 APK)"
fi
if [ -n "$AAB" ]; then
  _ar_check_aab "$AAB" "$REQUIRE_ABIS" "$FORBIDDEN_STRINGS" "$WORK" "$EXPECTED_SHA256"
fi
end_note

APK_SHA=""
AAB_SHA=""
[ -n "$APK" ] && APK_SHA="$(sha256_file "$APK")"
[ -n "$AAB" ] && AAB_SHA="$(sha256_file "$AAB")"

if [ "$EASYRELEASE_ANDROID_FAILURES" -gt 0 ] && ! is_true "$DRY_RUN"; then
  die "校验失败 $EASYRELEASE_ANDROID_FAILURES 项(见上面的 ❌)"
fi

STATUS="ok"
if is_true "$DRY_RUN"; then
  STATUS="dry-run"
fi

OUT_DIR="${OUTPUT_DIR:-$WORKSPACE/easyrelease}"
mkdir -p "$OUT_DIR"
MANIFEST="$OUT_DIR/android-manifest.json"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BT_VERSION="$(basename "$EASYRELEASE_BUILD_TOOLS")"

cat > "$MANIFEST" <<EOF
{
  "schema": 1,
  "platform": "android",
  "status": "$(json_escape "$STATUS")",
  "artifact": "$(json_escape "${APK:-$AAB}")",
  "artifact_kind": "$(if [ -n "$APK" ]; then echo apk; else echo aab; fi)",
  "apk": "$(json_escape "$APK")",
  "aab": "$(json_escape "$AAB")",
  "bundle_id": "$(json_escape "$EASYRELEASE_ANDROID_PACKAGE")",
  "version": "$(json_escape "$EASYRELEASE_ANDROID_VERSION_NAME")",
  "build": "$(json_escape "$EASYRELEASE_ANDROID_VERSION_CODE")",
  "target_sdk": "$(json_escape "$EASYRELEASE_ANDROID_TARGET_SDK")",
  "abis": "$(json_escape "$EASYRELEASE_ANDROID_ABIS")",
  "certificate_sha256": "$(json_escape "$EASYRELEASE_ANDROID_FINGERPRINT")",
  "dry_run": $(json_bool "$DRY_RUN"),
  "verified": $(json_bool "$(if [ "$EASYRELEASE_ANDROID_FAILURES" -eq 0 ]; then echo true; else echo false; fi)"),
  "apk_verified": $(json_bool "$EASYRELEASE_ANDROID_APK_VERIFIED"),
  "aab_verified": $(json_bool "$EASYRELEASE_ANDROID_AAB_VERIFIED"),
  "sha256": "$(json_escape "$APK_SHA")",
  "sha256_aab": "$(json_escape "$AAB_SHA")",
  "toolchain": {
    "build_tools": "$(json_escape "$BT_VERSION")",
    "java": "$(json_escape "${JAVA_HOME:-}")"
  },
  "created_at": "$(json_escape "$CREATED_AT")"
}
EOF

write_output artifact "${APK:-$AAB}"
write_output apk "$APK"
write_output aab "$AAB"
write_output sha256 "$APK_SHA"
write_output sha256_aab "$AAB_SHA"
write_output manifest_path "$MANIFEST"
write_output version_name "$EASYRELEASE_ANDROID_VERSION_NAME"
write_output version_code "$EASYRELEASE_ANDROID_VERSION_CODE"
write_output package "$EASYRELEASE_ANDROID_PACKAGE"
write_output certificate_sha256 "$EASYRELEASE_ANDROID_FINGERPRINT"
write_output verified "$(if [ "$EASYRELEASE_ANDROID_FAILURES" -eq 0 ]; then echo true; else echo false; fi)"

{
  echo "### EasyRelease Android"
  echo ""
  echo "| 项 | 值 |"
  echo "|---|---|"
  echo "| APK | \`${APK:-—}\` |"
  echo "| AAB | \`${AAB:-—}\` |"
  echo "| 包名 | ${EASYRELEASE_ANDROID_PACKAGE:-—} |"
  echo "| 版本 | ${EASYRELEASE_ANDROID_VERSION_NAME:-—} (${EASYRELEASE_ANDROID_VERSION_CODE:-—}) |"
  echo "| targetSdk | ${EASYRELEASE_ANDROID_TARGET_SDK:-—} |"
  echo "| ABI | ${EASYRELEASE_ANDROID_ABIS:-—} |"
  echo "| 签名指纹 | \`${EASYRELEASE_ANDROID_FINGERPRINT:-—}\` |"
  echo "| SHA-256 | \`${APK_SHA:-—}\` |"
  echo "| Manifest | \`$MANIFEST\` |"
} | append_summary

ok "完成:$MANIFEST"
