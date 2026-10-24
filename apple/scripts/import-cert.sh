#!/usr/bin/env bash
# Developer ID 证书导入:临时 keychain,只在本次 job 内有效。
# 由 main.sh source,不单独执行。

EASYRELEASE_KEYCHAIN=""

easyrelease_import_cert() {
  local p12_b64="$1"
  local p12_password="$2"
  local keychain_password="$3"

  [ -n "$p12_b64" ] || die "p12_base64 为空"
  [ -n "$keychain_password" ] || die "keychain_password 为空"

  local p12="$RUNNER_TEMP/easyrelease-cert-$$.p12"
  easyrelease_temp "$p12"
  EASYRELEASE_KEYCHAIN="$RUNNER_TEMP/easyrelease-$$.keychain-db"

  (umask 077; printf '%s' "$p12_b64" | openssl base64 -d -A > "$p12")
  [ -s "$p12" ] || die "p12 解码失败(检查 base64 是否完整)"

  security create-keychain -p "$keychain_password" "$EASYRELEASE_KEYCHAIN"
  security set-keychain-settings -lut 21600 "$EASYRELEASE_KEYCHAIN"
  security unlock-keychain -p "$keychain_password" "$EASYRELEASE_KEYCHAIN"
  security import "$p12" -k "$EASYRELEASE_KEYCHAIN" -P "$p12_password" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$keychain_password" "$EASYRELEASE_KEYCHAIN" >/dev/null

  # 把临时 keychain 放到搜索列表最前面,保留原有 keychain。
  local chains=() line
  while IFS= read -r line; do
    [ -n "$line" ] && chains+=("$line")
  done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')

  if [ ${#chains[@]} -gt 0 ]; then
    security list-keychains -d user -s "$EASYRELEASE_KEYCHAIN" "${chains[@]}"
  else
    security list-keychains -d user -s "$EASYRELEASE_KEYCHAIN"
  fi

  ok "证书已导入临时 keychain"
}

easyrelease_find_identity() {
  local team_id="${1:-}"
  local label="${2:-Developer ID Application}"
  local all identity

  # Installer 证书不属于 codesigning policy,这里不指定 -p,统一按名称筛选。
  all="$(security find-identity -v "$EASYRELEASE_KEYCHAIN" \
    | sed -n "s/.*\"\\($label: .*\\)\"/\\1/p")"

  if [ -n "$team_id" ]; then
    identity="$(printf '%s\n' "$all" | grep -F "($team_id)" | head -1 || true)"
  else
    identity="$(printf '%s\n' "$all" | head -1)"
  fi

  [ -n "$identity" ] || die "未找到 $label 证书(team_id=${team_id:-未指定})"
  [ -n "$team_id" ] || warn "未指定 team_id,使用找到的第一个 $label 身份"
  printf '%s' "$identity"
}

easyrelease_cleanup_keychain() {
  if [ -n "${EASYRELEASE_KEYCHAIN:-}" ] && [ -f "$EASYRELEASE_KEYCHAIN" ]; then
    security delete-keychain "$EASYRELEASE_KEYCHAIN" >/dev/null 2>&1 || true
    EASYRELEASE_KEYCHAIN=""
  fi
}
