#!/usr/bin/env bash
# shellcheck disable=SC2034  # 变量由 main.sh 跨文件读取
# .zip 输入:解包、定位唯一产物、重新打包。
# 由 main.sh source,不单独执行。

EASYRELEASE_ZIP_WORK=""
EASYRELEASE_INNER_ARTIFACT=""
EASYRELEASE_INNER_KIND=""
EASYRELEASE_INNER_REL=""

easyrelease_extract_zip() {
  local zip="$1"
  local work="$RUNNER_TEMP/easyrelease-unzip-$$"
  rm -rf "$work"
  mkdir -p "$work"
  easyrelease_temp "$work"
  ditto -x -k "$zip" "$work" || die "解压失败:$zip"
  EASYRELEASE_ZIP_WORK="$work"

  local -a apps=() files=()
  local p

  # 只要最外层 .app;嵌套 helper .app 由签名阶段处理。
  while IFS= read -r -d '' p; do
    apps+=("$p")
  done < <(find "$work" -type d -name '*.app' -prune -print0)

  while IFS= read -r -d '' p; do
    case "$p" in
      *".app/"*) continue ;;
    esac
    files+=("$p")
  done < <(find "$work" -type f \( -name '*.dmg' -o -name '*.pkg' \) -print0)

  local count=$(( ${#apps[@]} + ${#files[@]} ))
  if [ "$count" -ne 1 ]; then
    echo "zip 内必须恰好有一个 .app / .dmg / .pkg,实际找到 $count 个:" >&2
    find "$work" -maxdepth 4 -print | sed 's/^/  /' >&2
    die "无法确定 zip 内要处理的产物:$zip"
  fi

  if [ ${#apps[@]} -eq 1 ]; then
    EASYRELEASE_INNER_ARTIFACT="${apps[0]}"
    EASYRELEASE_INNER_KIND="app"
  else
    EASYRELEASE_INNER_ARTIFACT="${files[0]}"
    case "$EASYRELEASE_INNER_ARTIFACT" in
      *.dmg) EASYRELEASE_INNER_KIND="dmg" ;;
      *.pkg) EASYRELEASE_INNER_KIND="pkg" ;;
      *) die "不支持的 zip 内产物:$EASYRELEASE_INNER_ARTIFACT" ;;
    esac
  fi

  EASYRELEASE_INNER_REL="${EASYRELEASE_INNER_ARTIFACT#"$work"/}"
  ok "zip 内产物:$EASYRELEASE_INNER_REL($EASYRELEASE_INNER_KIND)"
}

easyrelease_repack_zip() {
  local work="$1"
  local out="$2"
  rm -f "$out"
  ditto -c -k "$work" "$out" || die "重新打包 zip 失败:$out"
  ok "重新打包:$out"
}

# 重新解压最终 zip,确认打包没有破坏签名/staple。
easyrelease_verify_zip_output() {
  local zip="$1"
  local rel="$2"
  local kind="$3"
  local notarize="$4"
  local mode="$5"
  local check="$RUNNER_TEMP/easyrelease-zipcheck-$$"
  local inner

  rm -rf "$check"
  mkdir -p "$check"
  easyrelease_temp "$check"
  ditto -x -k "$zip" "$check" || die "重新解压失败:$zip"
  inner="$check/$rel"
  [ -e "$inner" ] || die "重新打包后找不到内层产物:$inner"
  easyrelease_verify "$inner" "$kind" "$notarize" "$mode"
}
