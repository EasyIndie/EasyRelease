#!/usr/bin/env bash
# 定位 Android build-tools 与 JDK 签名工具。
# 由 main.sh source,不单独执行;也可以 `bash resolve-tools.sh` 打印解析结果。
#
# 只认 Android SDK 自带的 aapt2 / apksigner 与 JDK 自带的 jarsigner,
# 不引入 bundletool / fastlane。SDK 位置按常见环境变量与默认路径探测。

EASYRELEASE_TOOL_AAPT2=""
EASYRELEASE_TOOL_APKSIGNER=""
EASYRELEASE_TOOL_JARSIGNER=""
EASYRELEASE_TOOL_KEYTOOL=""
EASYRELEASE_BUILD_TOOLS=""

# 版本比较:挑最高的 build-tools。优先 sort -V(GNU),
# 退化到按 x.y.z 数值排序的 awk —— BSD sort 不支持 -V。
_easyrelease_pick_highest() {
  [ $# -gt 0 ] || return 1
  if printf '%s\n' "$@" | sort -V >/dev/null 2>&1; then
    printf '%s\n' "$@" | sort -V | tail -1
    return 0
  fi
  printf '%s\n' "$@" \
    | awk -F. '{ printf "%05d%05d%05d %s\n", $1 + 0, $2 + 0, $3 + 0, $0 }' \
    | sort | tail -1 | cut -d' ' -f2-
}

easyrelease_android_sdk_root() {
  local c
  for c in "${EASYRELEASE_ANDROID_SDK:-}" "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    if [ -n "$c" ] && [ -d "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  for c in /usr/local/lib/android/sdk "${HOME}/Android/Sdk" "${HOME}/Library/Android/sdk"; do
    if [ -d "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

# build_tools 输入可以显式指定;留空则从 SDK 里挑最高版本。
easyrelease_resolve_build_tools() {
  local explicit="${1:-}"
  if [ -n "$explicit" ]; then
    [ -d "$explicit" ] || die "build_tools 目录不存在:$explicit"
    EASYRELEASE_BUILD_TOOLS="$explicit"
    return 0
  fi
  local sdk bt_root chosen d
  sdk="$(easyrelease_android_sdk_root)" || die "找不到 Android SDK:请设置 ANDROID_HOME 或传 build_tools"
  bt_root="$sdk/build-tools"
  [ -d "$bt_root" ] || die "SDK 里没有 build-tools:$bt_root"
  local -a dirs=()
  for d in "$bt_root"/*; do
    [ -d "$d" ] && dirs+=("${d##*/}")
  done
  [ ${#dirs[@]} -gt 0 ] || die "build-tools 目录为空:$bt_root"
  chosen="$(_easyrelease_pick_highest "${dirs[@]}")"
  EASYRELEASE_BUILD_TOOLS="$bt_root/$chosen"
}

easyrelease_resolve_tools() {
  local build_tools_input="${1:-}"
  easyrelease_resolve_build_tools "$build_tools_input"

  EASYRELEASE_TOOL_AAPT2="$EASYRELEASE_BUILD_TOOLS/aapt2"
  [ -f "$EASYRELEASE_TOOL_AAPT2" ] || die "缺少 aapt2:$EASYRELEASE_TOOL_AAPT2"

  EASYRELEASE_TOOL_APKSIGNER="$EASYRELEASE_BUILD_TOOLS/apksigner"
  [ -f "$EASYRELEASE_TOOL_APKSIGNER" ] || die "缺少 apksigner:$EASYRELEASE_TOOL_APKSIGNER"

  if [ -n "${JAVA_HOME:-}" ] && [ -f "$JAVA_HOME/bin/jarsigner" ]; then
    EASYRELEASE_TOOL_JARSIGNER="$JAVA_HOME/bin/jarsigner"
  else
    EASYRELEASE_TOOL_JARSIGNER="$(command -v jarsigner || true)"
  fi
  [ -n "$EASYRELEASE_TOOL_JARSIGNER" ] || die "缺少 jarsigner(需要 JDK 17+)"

  if [ -n "${JAVA_HOME:-}" ] && [ -f "$JAVA_HOME/bin/keytool" ]; then
    EASYRELEASE_TOOL_KEYTOOL="$JAVA_HOME/bin/keytool"
  else
    EASYRELEASE_TOOL_KEYTOOL="$(command -v keytool || true)"
  fi
  [ -n "$EASYRELEASE_TOOL_KEYTOOL" ] || die "缺少 keytool(需要 JDK 17+)"
}

# apksigner / aapt2 在 Linux 上是原生程序;Windows 的 .bat 不在这里支持。
easyrelease_run_tool() {
  local tool="$1"
  shift
  case "$tool" in
    *apksigner)
      if [ -x "$tool" ]; then
        "$tool" "$@"
      else
        # 部分 SDK 里 apksigner 没有可执行位,用 bash 跑。
        bash "$tool" "$@"
      fi
      ;;
    *)
      "$tool" "$@"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  # shellcheck disable=SC1091
  # shellcheck source=../../lib/common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/common.sh"
  easyrelease_resolve_tools "${1:-}"
  printf 'build-tools : %s\n' "$EASYRELEASE_BUILD_TOOLS"
  printf 'aapt2       : %s\n' "$EASYRELEASE_TOOL_AAPT2"
  printf 'apksigner   : %s\n' "$EASYRELEASE_TOOL_APKSIGNER"
  printf 'jarsigner   : %s\n' "$EASYRELEASE_TOOL_JARSIGNER"
  printf 'keytool     : %s\n' "$EASYRELEASE_TOOL_KEYTOOL"
fi
