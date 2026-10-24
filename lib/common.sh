#!/usr/bin/env bash
# EasyRelease 共享函数。被平台脚本 source,不直接执行。
# 硬约束:只依赖 macOS / Linux 自带工具;不引入 fastlane 等第三方发布框架。

set -euo pipefail

note() { printf '::group::%s\n' "$*"; }
end_note() { printf '::endgroup::\n'; }
ok() { printf '  ✅ %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

json_bool() {
  if is_true "${1:-}"; then printf 'true'; else printf 'false'; fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令:$1"
}

# 目录(.app/.dmg 目录形态)按文件树哈希;文件按内容哈希。
sha256_of() {
  if [ -d "$1" ]; then
    (cd "$1" && find . -type f -print | LC_ALL=C sort \
      | while IFS= read -r f; do shasum -a 256 "$f"; done \
      | shasum -a 256 | awk '{print $1}')
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

json_escape() {
  # 先压掉换行/制表符,再做 JSON 转义,避免 manifest 出现裸控制字符。
  printf '%s' "${1:-}" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

abspath() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PWD" "$1" ;;
  esac
}

write_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

append_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat >> "$GITHUB_STEP_SUMMARY"
  else
    cat >/dev/null
  fi
}

# 临时文件统一登记,由 main.sh 的 EXIT trap 清理。bash 3.2 兼容。
EASYRELEASE_TEMP_FILES=()

easyrelease_temp() {
  EASYRELEASE_TEMP_FILES+=("$1")
}

easyrelease_cleanup_temp() {
  if [ ${#EASYRELEASE_TEMP_FILES[@]} -gt 0 ]; then
    local f
    for f in "${EASYRELEASE_TEMP_FILES[@]}"; do
      [ -n "$f" ] && rm -rf "$f"
    done
  fi
  EASYRELEASE_TEMP_FILES=()
}
