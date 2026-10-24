#!/usr/bin/env bash
# 签名:.app / .dmg / .pkg,只用 codesign / productsign。
# 由 main.sh source,不单独执行。

easyrelease_artifact_kind() {
  case "$1" in
    *.app) printf 'app' ;;
    *.dmg) printf 'dmg' ;;
    *.pkg) printf 'pkg' ;;
    *) die "不支持的产物类型:$1(只支持 .app / .dmg / .pkg)" ;;
  esac
}

# 先签嵌套代码,再签外层。entitlements 只给主 app。
easyrelease_sign_nested() {
  local artifact="$1"
  local identity="$2"
  local runtime="$3"
  local timestamp="$4"
  local -a args=(--force --sign "$identity")
  local p
  if [ "$identity" != "-" ] && [ -n "${EASYRELEASE_KEYCHAIN:-}" ]; then
    args+=(--keychain "$EASYRELEASE_KEYCHAIN")
  fi

  if is_true "$runtime"; then args+=(--options runtime); fi
  if is_true "$timestamp"; then args+=(--timestamp); fi

  while IFS= read -r -d '' p; do
    codesign "${args[@]}" "$p" >/dev/null
  done < <(find "$artifact" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)

  while IFS= read -r -d '' p; do
    codesign "${args[@]}" "$p" >/dev/null
  done < <(find "$artifact" -depth -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -print0)

  while IFS= read -r -d '' p; do
    codesign "${args[@]}" "$p" >/dev/null
  done < <(find "$artifact" -depth -type d -name '*.app' ! -path "$artifact" -print0)
}

easyrelease_sign() {
  local artifact="$1"
  local identity="$2"
  local mode="$3"
  local entitlements="${4:-}"
  local kind
  kind="$(easyrelease_artifact_kind "$artifact")"

  if [ "$mode" = "adhoc" ]; then
    case "$kind" in
      app)
        easyrelease_sign_nested "$artifact" "-" false false
        codesign --force --sign - "$artifact"
        ;;
      dmg)
        codesign --force --sign - "$artifact"
        ;;
      pkg)
        die "ad-hoc 不支持 .pkg;请用 mode=developer-id 走 productsign"
        ;;
    esac
  else
    [ -n "$identity" ] || die "developer-id 模式缺少签名身份"
    case "$kind" in
      app)
        easyrelease_sign_nested "$artifact" "$identity" true true
        local -a args=(--force --sign "$identity" --options runtime --timestamp)
        args+=(--keychain "$EASYRELEASE_KEYCHAIN")
        if [ -n "$entitlements" ]; then
          [ -f "$entitlements" ] || die "entitlements 文件不存在:$entitlements"
          args+=(--entitlements "$entitlements")
        fi
        codesign "${args[@]}" "$artifact"
        ;;
      dmg)
        codesign --force --sign "$identity" --timestamp --keychain "$EASYRELEASE_KEYCHAIN" "$artifact"
        ;;
      pkg)
        [ -f "$entitlements" ] && warn "entitlements 对 .pkg 不生效,已忽略"
        local out
        out="$RUNNER_TEMP/$(basename "$artifact").signed"
        easyrelease_temp "$out"
        xcrun productsign --sign "$identity" --timestamp --keychain "$EASYRELEASE_KEYCHAIN" "$artifact" "$out"
        mv "$out" "$artifact"
        ;;
    esac
  fi

  if [ "$kind" != "pkg" ]; then
    codesign --verify --deep --strict --verbose=2 "$artifact"
  fi
  ok "签名完成($kind / $mode)"
}
