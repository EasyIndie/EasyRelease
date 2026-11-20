#!/usr/bin/env bash
# Android 签名密钥还原:base64 → .jks(+ 可选的 keystore.properties)。
# 由 main.sh source;也可以单独执行(workflow 里**构建之前**就要用它,
# 因为 Gradle 在构建期签名,不像 Apple 那样事后签)。
#
# 硬约束:密码只从环境变量读,绝不回显;落盘文件 600,由 EXIT trap 删除。

EASYRELEASE_KEYSTORE_FILE=""
EASYRELEASE_KEYSTORE_TMP=""
EASYRELEASE_KEYSTORE_PROPERTIES_FILE=""

easyrelease_import_keystore() {
  local b64="$1"
  local dest="$2"
  local store_password="$3"
  local key_alias="$4"
  local key_password="$5"
  local properties="$6"
  local alias_property="${7:-keyAlias}"

  [ -n "$b64" ] || die "keystore_base64 为空"
  [ -n "$store_password" ] || die "store_password 为空"
  [ -n "$key_alias" ] || die "key_alias 为空"
  [ -n "$key_password" ] || die "key_password 为空"

  dest="$(abspath "$dest")"
  mkdir -p "$(dirname "$dest")"
  (
    umask 077
    printf '%s' "$b64" | tr -d '\r\n' | openssl base64 -d -A > "$dest"
  )
  [ -s "$dest" ] || die "keystore 解码失败(检查 base64 是否完整)"

  # keytool 只做「能打开 + 别名存在」的存在性校验,不打印密码与指纹细节。
  local keytool="${JAVA_HOME:+$JAVA_HOME/bin/keytool}"
  if [ -n "$keytool" ] && [ -f "$keytool" ]; then
    if ! "$keytool" -list -keystore "$dest" -storepass "$store_password" \
        -alias "$key_alias" >/dev/null 2>&1; then
      die "keystore 打不开或别名 $key_alias 不存在(检查 base64 / store_password / key_alias)"
    fi
    ok "keystore 已还原($(basename "$dest"),别名 $key_alias)"
  else
    warn "没找到 keytool,跳过 keystore 内容校验"
  fi

  EASYRELEASE_KEYSTORE_FILE="$dest"
  printf '%s\n' "$dest"

  if [ -n "$properties" ]; then
    properties="$(abspath "$properties")"
    mkdir -p "$(dirname "$properties")"
    # storeFile 写相对 properties 文件的路径 —— Gradle 的 keystore.properties 惯例。
    local dir rel
    dir="$(cd "$(dirname "$properties")" && pwd)"
    rel="$dest"
    case "$rel" in
      "$dir"/*) rel="${rel#"$dir"/}" ;;
    esac
    (
      umask 077
      {
        printf 'storeFile=%s\n' "$rel"
        printf 'storePassword=%s\n' "$store_password"
        printf '%s=%s\n' "$alias_property" "$key_alias"
        printf 'keyPassword=%s\n' "$key_password"
      } > "$properties"
    )
    chmod 600 "$properties"
    EASYRELEASE_KEYSTORE_PROPERTIES_FILE="$properties"
    ok "keystore.properties 已写入:$properties(别名键 $alias_property)"
  fi
}

easyrelease_cleanup_keystore() {
  local f
  for f in "${EASYRELEASE_KEYSTORE_TMP:-}" "${EASYRELEASE_KEYSTORE_FILE:-}" \
           "${EASYRELEASE_KEYSTORE_PROPERTIES_FILE:-}"; do
    if [ -n "$f" ] && [ -f "$f" ]; then rm -f "$f"; fi
  done
  EASYRELEASE_KEYSTORE_FILE=""
  EASYRELEASE_KEYSTORE_TMP=""
  EASYRELEASE_KEYSTORE_PROPERTIES_FILE=""
}

# 单独执行:给 workflow 的「构建前还原密钥」步骤用。
# 输出写进 $GITHUB_OUTPUT(keystore_path / keystore_properties_path)。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  # shellcheck disable=SC1091
  # shellcheck source=../../lib/common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/common.sh"

  dest="${EASYRELEASE_KEYSTORE_PATH:-${RUNNER_TEMP:-/tmp}/easyrelease-android/release.jks}"
  if [ -z "${EASYRELEASE_KEYSTORE_PATH:-}" ]; then
    EASYRELEASE_KEYSTORE_TMP="$(dirname "$dest")"
  fi
  properties="${EASYRELEASE_KEYSTORE_PROPERTIES:-}"

  easyrelease_import_keystore \
    "${EASYRELEASE_KEYSTORE_BASE64:-}" \
    "$dest" \
    "${EASYRELEASE_STORE_PASSWORD:-}" \
    "${EASYRELEASE_KEY_ALIAS:-}" \
    "${EASYRELEASE_KEY_PASSWORD:-}" \
    "$properties" \
    "${EASYRELEASE_ALIAS_PROPERTY:-keyAlias}"

  write_output keystore_path "$EASYRELEASE_KEYSTORE_FILE"
  [ -n "$properties" ] && write_output keystore_properties_path "$(abspath "$properties")"
fi
