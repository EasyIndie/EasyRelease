#!/usr/bin/env bash
# shellcheck disable=SC1091
# EasyRelease Apple 入口:签名 → 公证 → staple → 校验 → manifest。
# 由 apple/action.yml 调用。所有输入通过 EASYRELEASE_* 环境变量传入。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
source "$SCRIPT_DIR/import-cert.sh"
source "$SCRIPT_DIR/sign.sh"
source "$SCRIPT_DIR/notarize.sh"
source "$SCRIPT_DIR/verify.sh"
source "$SCRIPT_DIR/zip.sh"

ARTIFACT_INPUT="${EASYRELEASE_ARTIFACT:-}"
MODE="${EASYRELEASE_MODE:-adhoc}"
NOTARIZE="${EASYRELEASE_NOTARIZE:-false}"
STAPLE="${EASYRELEASE_STAPLE:-true}"
DRY_RUN="${EASYRELEASE_DRY_RUN:-false}"
DEBUG="${EASYRELEASE_DEBUG:-false}"

P12_BASE64="${EASYRELEASE_P12_BASE64:-}"
P12_PASSWORD="${EASYRELEASE_P12_PASSWORD:-}"
TEAM_ID="${EASYRELEASE_TEAM_ID:-}"
IDENTITY_INPUT="${EASYRELEASE_IDENTITY:-}"
KEYCHAIN_PASSWORD="${EASYRELEASE_KEYCHAIN_PASSWORD:-}"

NOTARY_AUTH="${EASYRELEASE_NOTARY_AUTH:-auto}"
APPLE_ID="${EASYRELEASE_APPLE_ID:-}"
APPLE_PASSWORD="${EASYRELEASE_APPLE_PASSWORD:-}"
ASC_KEY_ID="${EASYRELEASE_ASC_KEY_ID:-}"
ASC_ISSUER_ID="${EASYRELEASE_ASC_ISSUER_ID:-}"
ASC_KEY_P8="${EASYRELEASE_ASC_KEY_P8:-}"

ENTITLEMENTS="${EASYRELEASE_ENTITLEMENTS:-}"
TIMEOUT="${EASYRELEASE_TIMEOUT:-30m}"
VERSION="${EASYRELEASE_VERSION:-}"
BUILD_NUMBER="${EASYRELEASE_BUILD_NUMBER:-}"
BUNDLE_ID="${EASYRELEASE_BUNDLE_ID:-}"
OUTPUT_DIR="${EASYRELEASE_OUTPUT_DIR:-}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

# 密钥只做存在性判断,绝不打印。
cleanup() {
  easyrelease_cleanup_temp
  easyrelease_cleanup_keychain
}
trap cleanup EXIT

[ -n "$ARTIFACT_INPUT" ] || die "artifact 不能为空"
INPUT_ARTIFACT="$(abspath "$ARTIFACT_INPUT")"
[ -e "$INPUT_ARTIFACT" ] || die "产物不存在:$INPUT_ARTIFACT"

ARTIFACT="$INPUT_ARTIFACT"
KIND="$(easyrelease_artifact_kind "$INPUT_ARTIFACT")"
CONTAINER_KIND=""
INNER_REL=""
OUTPUT_ZIP=""

if [ "$KIND" = "zip" ]; then
  CONTAINER_KIND="zip"
  easyrelease_extract_zip "$INPUT_ARTIFACT"
  ARTIFACT="$EASYRELEASE_INNER_ARTIFACT"
  KIND="$EASYRELEASE_INNER_KIND"
  INNER_REL="$EASYRELEASE_INNER_REL"
  base="${INPUT_ARTIFACT%.zip}"
  case "$base" in
    *-signed) OUTPUT_ZIP="$base.zip" ;;
    *) OUTPUT_ZIP="$base-signed.zip" ;;
  esac
fi

ARTIFACT_KIND="$KIND"
if [ "$CONTAINER_KIND" = "zip" ]; then
  ARTIFACT_KIND="zip"
fi

case "$MODE" in
  adhoc|developer-id) ;;
  *) die "mode 只能是 adhoc 或 developer-id,当前:$MODE" ;;
esac

if is_true "$NOTARIZE" && [ "$MODE" != "developer-id" ]; then
  die "公证需要 Developer ID 签名;请设置 mode=developer-id"
fi

# 认证方式:auto 优先 API Key;显式 apple-id 时只走 Apple ID + app 专用密码。
NOTARY_AUTH_RESOLVED=""
if is_true "$NOTARIZE"; then
  NOTARY_AUTH_RESOLVED="$NOTARY_AUTH"
  if [ "$NOTARY_AUTH_RESOLVED" = "auto" ]; then
    if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -n "$ASC_KEY_P8" ]; then
      NOTARY_AUTH_RESOLVED="api-key"
    elif [ -n "$APPLE_ID" ] || [ -n "$APPLE_PASSWORD" ]; then
      NOTARY_AUTH_RESOLVED="apple-id"
    else
      NOTARY_AUTH_RESOLVED="api-key"
    fi
  fi
  case "$NOTARY_AUTH_RESOLVED" in
    api-key|apple-id) ;;
    *) die "notary_auth 只能是 auto / api-key / apple-id,当前:$NOTARY_AUTH_RESOLVED" ;;
  esac
fi

if is_true "$DRY_RUN"; then
  # dry-run 不要求证书/密钥,只校验输入和工具是否存在。
  require_cmd codesign
  if is_true "$NOTARIZE"; then
    xcrun --find notarytool >/dev/null 2>&1 || warn "未找到 notarytool(dry-run 继续)"
  fi
else
  require_cmd codesign
  if is_true "$NOTARIZE"; then
    xcrun --find notarytool >/dev/null 2>&1 || die "未找到 notarytool(需要完整 Xcode)"
    xcrun --find stapler >/dev/null 2>&1 || die "未找到 stapler(需要完整 Xcode)"
    case "$NOTARY_AUTH_RESOLVED" in
      api-key)
        [ -n "$ASC_KEY_ID" ] || die "api-key 认证需要 asc_key_id"
        [ -n "$ASC_ISSUER_ID" ] || die "api-key 认证需要 asc_issuer_id"
        [ -n "$ASC_KEY_P8" ] || die "api-key 认证需要 asc_key_p8"
        ;;
      apple-id)
        [ -n "$APPLE_ID" ] || die "apple-id 认证需要 apple_id"
        [ -n "$APPLE_PASSWORD" ] || die "apple-id 认证需要 apple_password(app 专用密码)"
        [ -n "$TEAM_ID" ] || die "apple-id 认证需要 team_id"
        ;;
    esac
  fi
  if [ "$MODE" = "developer-id" ]; then
    [ -n "$P12_BASE64" ] || die "mode=developer-id 需要 p12_base64"
    [ -n "$P12_PASSWORD" ] || die "mode=developer-id 需要 p12_password"
    if [ -z "$KEYCHAIN_PASSWORD" ]; then
      KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
    fi
  fi
fi

if [ "$KIND" = "app" ] && [ -f "$ARTIFACT/Contents/Info.plist" ]; then
  if [ -z "$VERSION" ]; then
    VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ARTIFACT/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$ARTIFACT/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [ -z "$BUNDLE_ID" ]; then
    BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$ARTIFACT/Contents/Info.plist" 2>/dev/null || true)"
  fi
fi

note "EasyRelease Apple"
printf '  input      : %s\n' "$INPUT_ARTIFACT"
printf '  container  : %s\n' "${CONTAINER_KIND:-none}"
printf '  artifact   : %s\n' "$ARTIFACT"
printf '  kind       : %s\n' "$KIND"
printf '  mode       : %s\n' "$MODE"
printf '  notarize   : %s\n' "$(is_true "$NOTARIZE" && echo true || echo false)"
printf '  notary auth: %s\n' "${NOTARY_AUTH_RESOLVED:-—}"
printf '  staple     : %s\n' "$(is_true "$STAPLE" && echo true || echo false)"
printf '  dry_run    : %s\n' "$(is_true "$DRY_RUN" && echo true || echo false)"
printf '  version    : %s\n' "${VERSION:-—}"
printf '  build      : %s\n' "${BUILD_NUMBER:-—}"
printf '  bundle id  : %s\n' "${BUNDLE_ID:-—}"
if is_true "$DEBUG"; then
  printf '  runner os  : %s\n' "$(uname -srm)"
  printf '  xcode      : %s\n' "$(xcodebuild -version 2>/dev/null | sed -n '1p' || true)"
fi
end_note

SHA_BEFORE="$(sha256_of "$INPUT_ARTIFACT")"
FINAL_ARTIFACT="$ARTIFACT"

if is_true "$DRY_RUN"; then
  EASYRELEASE_NOTARY_ID=""
  EASYRELEASE_VERIFIED=false
  EASYRELEASE_GATEKEEPER=skipped
  STATUS="dry-run"
  if [ "$CONTAINER_KIND" = "zip" ]; then
    FINAL_ARTIFACT="$INPUT_ARTIFACT"
  fi
else
  note "签名"
  if [ "$MODE" = "adhoc" ]; then
    easyrelease_sign "$ARTIFACT" "-" adhoc ""
  else
    easyrelease_import_cert "$P12_BASE64" "$P12_PASSWORD" "$KEYCHAIN_PASSWORD"
    if [ -n "$IDENTITY_INPUT" ]; then
      IDENTITY="$IDENTITY_INPUT"
      security find-identity -v -p codesigning "$EASYRELEASE_KEYCHAIN" | grep -Fq "$IDENTITY" \
        || die "指定的 identity 不在临时 keychain 中:$IDENTITY"
    else
      IDENTITY="$(easyrelease_find_identity "$TEAM_ID")"
    fi
    ok "签名身份:$IDENTITY"
    easyrelease_sign "$ARTIFACT" "$IDENTITY" developer-id "$ENTITLEMENTS"
  fi
  end_note

  if is_true "$NOTARIZE"; then
    note "公证"
    easyrelease_notarize "$ARTIFACT" "$KIND" "$NOTARY_AUTH_RESOLVED" \
      "$APPLE_ID" "$APPLE_PASSWORD" "$TEAM_ID" \
      "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_P8" "$TIMEOUT"
    end_note
  fi

  if is_true "$STAPLE" && is_true "$NOTARIZE"; then
    note "staple"
    easyrelease_staple "$ARTIFACT" "$KIND"
    end_note
  fi

  note "校验"
  easyrelease_verify "$ARTIFACT" "$KIND" "$NOTARIZE" "$MODE"
  end_note

  if [ "$CONTAINER_KIND" = "zip" ]; then
    note "重新打包 zip"
    easyrelease_repack_zip "$EASYRELEASE_ZIP_WORK" "$OUTPUT_ZIP"
    easyrelease_verify_zip_output "$OUTPUT_ZIP" "$INNER_REL" "$KIND" "$NOTARIZE" "$MODE"
    FINAL_ARTIFACT="$OUTPUT_ZIP"
    end_note
  fi
  STATUS="ok"
fi

SHA_AFTER="$(sha256_of "$FINAL_ARTIFACT")"

OUT_DIR="${OUTPUT_DIR:-$WORKSPACE/easyrelease}"
mkdir -p "$OUT_DIR"
MANIFEST="$OUT_DIR/apple-manifest.json"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | sed -n '1p' || true)"
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"

cat > "$MANIFEST" <<EOF
{
  "schema": 1,
  "platform": "apple",
  "status": "$(json_escape "$STATUS")",
  "artifact": "$(json_escape "$FINAL_ARTIFACT")",
  "artifact_kind": "$(json_escape "$ARTIFACT_KIND")",
  "container": "$(json_escape "$CONTAINER_KIND")",
  "inner_artifact": "$(json_escape "$INNER_REL")",
  "inner_kind": "$(json_escape "$KIND")",
  "input_artifact": "$(json_escape "$INPUT_ARTIFACT")",
  "bundle_id": "$(json_escape "$BUNDLE_ID")",
  "version": "$(json_escape "$VERSION")",
  "build": "$(json_escape "$BUILD_NUMBER")",
  "mode": "$(json_escape "$MODE")",
  "notary_auth": "$(json_escape "$NOTARY_AUTH_RESOLVED")",
  "dry_run": $(json_bool "$DRY_RUN"),
  "signed": $(if is_true "$DRY_RUN"; then echo false; else echo true; fi),
  "notarized": $(if is_true "$NOTARIZE" && ! is_true "$DRY_RUN"; then echo true; else echo false; fi),
  "stapled": $(if is_true "$STAPLE" && is_true "$NOTARIZE" && ! is_true "$DRY_RUN"; then echo true; else echo false; fi),
  "gatekeeper": "$(json_escape "$EASYRELEASE_GATEKEEPER")",
  "verified": $(json_bool "$EASYRELEASE_VERIFIED"),
  "notarization_id": "$(json_escape "$EASYRELEASE_NOTARY_ID")",
  "sha256_before": "$(json_escape "$SHA_BEFORE")",
  "sha256": "$(json_escape "$SHA_AFTER")",
  "toolchain": {
    "xcode": "$(json_escape "$XCODE_VERSION")",
    "macos": "$(json_escape "$MACOS_VERSION")"
  },
  "created_at": "$(json_escape "$CREATED_AT")"
}
EOF

write_output signed_artifact "$FINAL_ARTIFACT"
write_output sha256 "$SHA_AFTER"
write_output manifest_path "$MANIFEST"
write_output notarization_id "$EASYRELEASE_NOTARY_ID"
write_output verified "$EASYRELEASE_VERIFIED"

{
  echo "### EasyRelease Apple"
  echo ""
  echo "| 项 | 值 |"
  echo "|---|---|"
  echo "| 产物 | \`$(basename "$FINAL_ARTIFACT")\` |"
  echo "| 容器 | ${CONTAINER_KIND:-none} |"
  echo "| 内层 | ${INNER_REL:-—} |"
  echo "| 模式 | $MODE |"
  echo "| 公证认证 | ${NOTARY_AUTH_RESOLVED:-—} |"
  echo "| 公证 | $(is_true "$NOTARIZE" && echo yes || echo no) |"
  echo "| Gatekeeper | $EASYRELEASE_GATEKEEPER |"
  echo "| SHA-256 | \`$SHA_AFTER\` |"
  echo "| Manifest | \`$MANIFEST\` |"
} | append_summary

ok "完成:$MANIFEST"
