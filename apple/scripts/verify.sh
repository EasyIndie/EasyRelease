#!/usr/bin/env bash
# shellcheck disable=SC2034  # 变量由 main.sh 跨文件读取
# 校验:codesign 结构校验 + 公证后的 Gatekeeper 校验。
# 由 main.sh source,不单独执行。

EASYRELEASE_VERIFIED=false
EASYRELEASE_GATEKEEPER=skipped

easyrelease_verify() {
  local artifact="$1"
  local kind="$2"
  local notarize="$3"
  local mode="$4"

  EASYRELEASE_VERIFIED=false
  EASYRELEASE_GATEKEEPER=skipped

  if [ "$kind" = "pkg" ]; then
    # .pkg 没有 codesign 结构校验;只有公证 + spctl 才能证明可用。
    EASYRELEASE_VERIFIED=false
  else
    codesign --verify --deep --strict --verbose=2 "$artifact" \
      || die "codesign 校验失败:$artifact"
    EASYRELEASE_VERIFIED=true
  fi

  # ad-hoc 没有公证票据,Gatekeeper 必然拒绝,不误报。
  [ "$mode" = "developer-id" ] || return 0
  is_true "$notarize" || return 0

  if ! spctl --status 2>/dev/null | grep -q "assessments enabled"; then
    warn "本机 Gatekeeper 未启用,跳过 spctl"
    EASYRELEASE_GATEKEEPER=disabled
    return 0
  fi

  local -a args=(-a -vvv)
  case "$kind" in
    app) args+=(-t exec) ;;
    dmg) args+=(-t open --context context:primary-signature) ;;
    pkg) args+=(-t install) ;;
  esac

  spctl "${args[@]}" "$artifact" || die "Gatekeeper 校验失败:$artifact"
  EASYRELEASE_GATEKEEPER=accepted
  EASYRELEASE_VERIFIED=true
  ok "Gatekeeper 校验通过"
}
