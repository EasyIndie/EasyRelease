#!/usr/bin/env bash
# shellcheck disable=SC2034  # 变量由 main.sh 跨文件读取
# 公证 + staple。只用 notarytool / stapler。
# 支持 API Key 与 Apple ID + app 专用密码两种认证。
# 由 main.sh source,不单独执行。

EASYRELEASE_NOTARY_ID=""

easyrelease_notarize() {
  local artifact="$1"
  local kind="$2"
  local auth="$3"
  local apple_id="$4"
  local apple_password="$5"
  local team_id="$6"
  local key_id="$7"
  local issuer="$8"
  local key_p8="$9"
  local timeout="${10}"

  local submit_path="$artifact"
  local tmp_zip="" p8_file="" out="" log="" rc=0 id="" status=""
  local -a auth_args=()

  if [ "$kind" = "app" ]; then
    tmp_zip="$RUNNER_TEMP/easyrelease-$(basename "$artifact").zip"
    easyrelease_temp "$tmp_zip"
    ditto -c -k --keepParent "$artifact" "$tmp_zip"
    submit_path="$tmp_zip"
  fi

  case "$auth" in
    api-key)
      p8_file="$RUNNER_TEMP/AuthKey_${key_id}.p8"
      easyrelease_temp "$p8_file"
      case "$key_p8" in
        *"BEGIN PRIVATE KEY"*)
          (umask 077; printf '%s\n' "$key_p8" > "$p8_file")
          ;;
        *)
          (umask 077; printf '%s' "$key_p8" | openssl base64 -d -A > "$p8_file")
          ;;
      esac
      [ -s "$p8_file" ] || die "asc_key_p8 解析失败(需要 PEM 或 base64)"
      auth_args=(--key "$p8_file" --key-id "$key_id" --issuer "$issuer")
      ;;
    apple-id)
      [ -n "$apple_id" ] || die "apple-id 认证缺少 apple_id"
      [ -n "$apple_password" ] || die "apple-id 认证缺少 apple_password"
      [ -n "$team_id" ] || die "apple-id 认证缺少 team_id"
      auth_args=(--apple-id "$apple_id" --password "$apple_password" --team-id "$team_id")
      ;;
    *)
      die "未知的公证认证方式:$auth"
      ;;
  esac

  out="$RUNNER_TEMP/easyrelease-notary.json"
  log="$RUNNER_TEMP/easyrelease-notary.log"

  set +e
  xcrun notarytool submit "$submit_path" "${auth_args[@]}" \
    --wait --timeout "$timeout" --output-format json \
    > "$out" 2> "$log"
  rc=$?
  set -e

  [ -s "$log" ] && cat "$log"
  [ -s "$out" ] && cat "$out"

  id="$(plutil -extract id raw -o - "$out" 2>/dev/null || true)"
  [ -n "$id" ] || id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$out" | head -1)"
  status="$(plutil -extract status raw -o - "$out" 2>/dev/null || true)"
  [ -n "$status" ] || status="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$out" | head -1)"

  if [ "$rc" -ne 0 ] || [ "$status" != "Accepted" ]; then
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" "${auth_args[@]}" \
        > "$RUNNER_TEMP/easyrelease-notary-detail.json" 2>&1 || true
      cat "$RUNNER_TEMP/easyrelease-notary-detail.json" || true
    fi
    die "公证未通过(status=${status:-unknown}, rc=$rc)"
  fi

  EASYRELEASE_NOTARY_ID="$id"
  ok "公证通过:$id"
}

easyrelease_staple() {
  local artifact="$1"
  local kind="$2"
  case "$kind" in
    app|dmg|pkg)
      xcrun stapler staple "$artifact"
      xcrun stapler validate "$artifact"
      ;;
    *)
      warn "不 staple 的类型:$kind"
      ;;
  esac
  ok "staple 完成"
}
