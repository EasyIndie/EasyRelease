#!/usr/bin/env bash
# shellcheck disable=SC2034  # 变量由 main.sh 跨文件读取
# Android 产物校验:清单 / 版本 / 签名 / ABI / 结构。
# 由 main.sh source,不单独执行。
#
# 设计原则:
#   1. **不在第一个错误就退出** —— 一次把问题列全,和人工验收的顺序一致;
#   2. repo 特定常量(debug 钩子类名、ABI、targetSdk 门槛)全部走参数,
#      不把任何仓库的约定写进这里;
#   3. APK 与 AAB 是两条签名链(apksigner v2/v3 vs jarsigner),分开检查。

EASYRELEASE_ANDROID_FAILURES=0
EASYRELEASE_ANDROID_PACKAGE=""
EASYRELEASE_ANDROID_VERSION_NAME=""
EASYRELEASE_ANDROID_VERSION_CODE=""
EASYRELEASE_ANDROID_TARGET_SDK=""
EASYRELEASE_ANDROID_ABIS=""
EASYRELEASE_ANDROID_FINGERPRINT=""
EASYRELEASE_ANDROID_APK_VERIFIED=false
EASYRELEASE_ANDROID_AAB_VERIFIED=false

_ar_ok() { ok "$*"; }
_ar_bad() {
  printf '  ❌ %s\n' "$*" >&2
  EASYRELEASE_ANDROID_FAILURES=$((EASYRELEASE_ANDROID_FAILURES + 1))
}

# 从 aapt2 badging 的一行里取引号值。$2 是前缀(带分隔符),
# 如 "name=" 或 "targetSdkVersion:"。纯 bash,不经 sed ——
# 含字面单引号的表达式在某些 shell 桥接层会被重新分词。
_ar_quoted_value() {
  local line="$1" prefix="$2" value=""
  case "$line" in
    *"$prefix"\'*) value="${line#*"$prefix"\'}"; value="${value%%\'*}" ;;
  esac
  printf '%s' "$value"
}

_ar_attr() { _ar_quoted_value "$1" "$2="; }

_ar_has_quoted_token() {
  # 在 `native-code: 'arm64-v8a' 'x86'` 这类行里找某个 token。
  local line="$1" token="$2" normalized
  normalized="$(printf '%s' "$line" | tr "'\"" '  ')"
  case " $normalized " in
    *" $token "*) return 0 ;;
  esac
  return 1
}

_ar_scan_strings() {
  # $1=产物 $2=zip 内条目 $3=逗号分隔的禁词  → 命中第一个就打印它
  local artifact="$1" pattern="$2" list="$3" tmp="$4" word n
  [ -n "$list" ] || return 0
  rm -f "$tmp"
  unzip -p "$artifact" "$pattern" > "$tmp" 2>/dev/null || true
  [ -s "$tmp" ] || return 0
  local IFS=,
  for word in $list; do
    [ -n "$word" ] || continue
    n="$(grep -acF -- "$word" "$tmp" 2>/dev/null || true)"
    # grep -c 不会因提前退出而让上游吃 SIGPIPE(配合 set -o pipefail 更稳)。
    if [ "${n:-0}" -gt 0 ]; then
      printf '%s' "$word"
      return 0
    fi
  done
  return 0
}

_ar_check_apk() {
  local apk="$1"
  local expected_package="$2" expected_version_name="$3" expected_version_code="$4"
  local expected_sha256="$5" forbidden="$6" require_abis="$7" min_target_sdk="$8"
  local work="$9"

  if [ ! -f "$apk" ]; then
    _ar_bad "APK 不存在:$apk"
    return 0
  fi

  local badging
  if ! badging="$("$EASYRELEASE_TOOL_AAPT2" dump badging "$(easyrelease_tool_path "$apk")" 2>/dev/null)"; then
    _ar_bad "aapt2 读不出 APK 清单(路径或文件损坏?):$apk"
    return 0
  fi

  local pkg_line
  pkg_line="$(printf '%s\n' "$badging" | grep -m1 '^package:' || true)"
  EASYRELEASE_ANDROID_PACKAGE="$(_ar_attr "$pkg_line" name)"
  EASYRELEASE_ANDROID_VERSION_NAME="$(_ar_attr "$pkg_line" versionName)"
  EASYRELEASE_ANDROID_VERSION_CODE="$(_ar_attr "$pkg_line" versionCode)"

  if [ -z "$EASYRELEASE_ANDROID_PACKAGE" ]; then
    _ar_bad "取不到包名(aapt2 badging 输出异常)"
  else
    case "$EASYRELEASE_ANDROID_PACKAGE" in
      com.example.*) _ar_bad "包名是 $EASYRELEASE_ANDROID_PACKAGE —— 商店会拒收 com.example.*" ;;
    esac
    if [ -n "$expected_package" ] && [ "$EASYRELEASE_ANDROID_PACKAGE" != "$expected_package" ]; then
      _ar_bad "包名不符:$EASYRELEASE_ANDROID_PACKAGE(期望 $expected_package)"
    else
      _ar_ok "包名 $EASYRELEASE_ANDROID_PACKAGE"
    fi
  fi

  if [ -n "$expected_version_name" ] && [ "$EASYRELEASE_ANDROID_VERSION_NAME" != "$expected_version_name" ]; then
    _ar_bad "versionName 不符:$EASYRELEASE_ANDROID_VERSION_NAME(期望 $expected_version_name)"
  elif [ -n "$expected_version_code" ] && [ "$EASYRELEASE_ANDROID_VERSION_CODE" != "$expected_version_code" ]; then
    _ar_bad "versionCode 不符:$EASYRELEASE_ANDROID_VERSION_CODE(期望 $expected_version_code)"
  else
    _ar_ok "versionName=$EASYRELEASE_ANDROID_VERSION_NAME versionCode=$EASYRELEASE_ANDROID_VERSION_CODE"
  fi

  case "$badging" in
    *application-debuggable*) _ar_bad "APK 是 debuggable 的 —— 这是 debug 包,不是正式包" ;;
    *) _ar_ok "非 debuggable" ;;
  esac

  local hit
  hit="$(_ar_scan_strings "$apk" '*.dex' "$forbidden" "$work/apk-strings.bin")"
  if [ -n "$hit" ]; then
    _ar_bad "APK 里出现了禁用字符串「$hit」(通常是 debug 钩子混进了正式包)"
  else
    _ar_ok "dex 里没有禁用字符串"
  fi

  local target_sdk
  target_sdk="$(_ar_quoted_value "$(printf '%s\n' "$badging" | grep -m1 '^targetSdkVersion:' || true)" targetSdkVersion:)"
  EASYRELEASE_ANDROID_TARGET_SDK="$target_sdk"
  if [ -n "$min_target_sdk" ]; then
    if [ -z "$target_sdk" ]; then
      _ar_bad "取不到 targetSdkVersion(期望 ≥ $min_target_sdk)"
    elif [ "$target_sdk" -lt "$min_target_sdk" ]; then
      _ar_bad "targetSdk=$target_sdk < $min_target_sdk —— 商店会拒收"
    else
      _ar_ok "targetSdk=$target_sdk ≥ $min_target_sdk"
    fi
  else
    _ar_ok "targetSdk=$target_sdk"
  fi

  local abi_line
  abi_line="$(printf '%s\n' "$badging" | grep -m1 '^native-code:' || true)"
  EASYRELEASE_ANDROID_ABIS="$(printf '%s' "${abi_line#native-code:}" | tr -d "'\"" | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//')"
  if [ -n "$require_abis" ]; then
    local abi local_missing=""
    local IFS=,
    for abi in $require_abis; do
      [ -n "$abi" ] || continue
      _ar_has_quoted_token "$abi_line" "$abi" || local_missing="$local_missing $abi"
    done
    unset IFS
    if [ -n "$local_missing" ]; then
      _ar_bad "缺少 ABI:$local_missing(实际:$EASYRELEASE_ANDROID_ABIS)"
    else
      _ar_ok "含所需 ABI:$require_abis"
    fi
  fi

  if ! easyrelease_run_tool "$EASYRELEASE_TOOL_APKSIGNER" verify --print-certs \
       "$(easyrelease_tool_path "$apk")" > "$work/apk-certs.txt" 2>&1; then
    _ar_bad "APK 没有有效签名(apksigner 校验失败)"
  else
    EASYRELEASE_ANDROID_FINGERPRINT="$(awk -F': ' '/SHA-256 digest/ { print tolower($NF); exit }' "$work/apk-certs.txt")"
    if [ -z "$EASYRELEASE_ANDROID_FINGERPRINT" ]; then
      _ar_bad "签名校验通过但取不到证书 SHA-256(apksigner 输出异常)"
    elif [ -n "$expected_sha256" ]; then
      local want found=""
      local IFS=,
      for want in $expected_sha256; do
        want="$(printf '%s' "$want" | tr 'A-F' 'a-f' | tr -d ' ')"
        [ -n "$want" ] || continue
        [ "$want" = "$EASYRELEASE_ANDROID_FINGERPRINT" ] && found="$want"
      done
      unset IFS
      if [ -n "$found" ]; then
        _ar_ok "签名指纹与期望一致(${EASYRELEASE_ANDROID_FINGERPRINT:0:16}…)"
      else
        _ar_bad "签名指纹 ${EASYRELEASE_ANDROID_FINGERPRINT:0:16}… 不在期望列表里 —— 陌生密钥,不能发"
      fi
    else
      _ar_ok "已签名(${EASYRELEASE_ANDROID_FINGERPRINT:0:16}…)"
    fi
  fi

  EASYRELEASE_ANDROID_APK_VERIFIED=true
}

_ar_aab_fingerprint() {
  # AAB 的签名证书指纹。jarsigner -printcert 的输出来自 META-INF/*.RSA,
  # 比从 jarsigner -verify 的文本里抠更可靠。
  local aab="$1" work="$2" sig
  rm -f "$work/aab-cert.rsa"
  unzip -p "$aab" 'META-INF/*.RSA' > "$work/aab-cert.rsa" 2>/dev/null || true
  [ -s "$work/aab-cert.rsa" ] || return 0
  "$EASYRELEASE_TOOL_KEYTOOL" -printcert -file "$(easyrelease_tool_path "$work/aab-cert.rsa")" 2>/dev/null \
    | awk -F': ' '/SHA256:/ { print $2; exit }' \
    | tr -d ':' | tr 'A-F' 'a-f'
}

_ar_check_aab() {
  local aab="$1" require_abis="$2" forbidden="$3" work="$4" expected_sha256="${5:-}"

  if [ ! -f "$aab" ]; then
    _ar_bad "AAB 不存在:$aab"
    return 0
  fi

  local entries
  if ! entries="$(unzip -Z1 "$aab" 2>/dev/null)"; then
    _ar_bad "AAB 不是合法的 zip:$aab"
    return 0
  fi

  local entry missing=""
  for entry in BundleConfig.pb base/manifest/AndroidManifest.xml; do
    case "$entries" in
      *"$entry"*) ;;
      *) missing="$missing $entry" ;;
    esac
  done
  case "$entries" in
    *base/dex/classes*.dex*) ;;
    *) missing="$missing base/dex/classes*.dex" ;;
  esac
  if [ -n "$missing" ]; then
    _ar_bad "AAB 结构不完整,缺:$missing"
  else
    _ar_ok "AAB 结构完整(BundleConfig / manifest / dex)"
  fi

  local abi
  local IFS=,
  for abi in $require_abis; do
    [ -n "$abi" ] || continue
    case "$entries" in
      *"base/lib/$abi/"*) ;;
      *) _ar_bad "AAB 缺 base/lib/$abi/" ;;
    esac
  done
  unset IFS

  local hit
  hit="$(_ar_scan_strings "$aab" 'base/dex/*.dex' "$forbidden" "$work/aab-strings.bin")"
  if [ -n "$hit" ]; then
    _ar_bad "AAB 里出现了禁用字符串「$hit」"
  fi

  # 不用 -strict:upload key 是自签证书,jarsigner -strict 会把「证书链不受信任」
  # 算成 signer error(rc=4),而商店只关心「是否由登记的 upload key 签名」。
  if "$EASYRELEASE_TOOL_JARSIGNER" -verify "$(easyrelease_tool_path "$aab")" > "$work/aab-jarsigner.txt" 2>&1 \
     && grep -q 'jar verified' "$work/aab-jarsigner.txt"; then
    _ar_ok "AAB 已签名(jarsigner 校验通过)"
    EASYRELEASE_ANDROID_AAB_VERIFIED=true

    if [ -n "$expected_sha256" ]; then
      local aab_fp want found=""
      aab_fp="$(_ar_aab_fingerprint "$aab" "$work")"
      local IFS=,
      for want in $expected_sha256; do
        want="$(printf '%s' "$want" | tr 'A-F' 'a-f' | tr -d ' ')"
        [ -n "$want" ] || continue
        [ "$want" = "$aab_fp" ] && found="$want"
      done
      unset IFS
      if [ -z "$aab_fp" ]; then
        _ar_bad "取不到 AAB 的签名证书指纹(无法核对 upload key)"
      elif [ -n "$found" ]; then
        _ar_ok "AAB 签名与期望一致(${aab_fp:0:16}…)"
      else
        _ar_bad "AAB 签名指纹 ${aab_fp:0:16}… 与 APK / 期望不一致 —— upload key 换了,商店会拒收"
      fi
    fi
  else
    _ar_bad "AAB 未通过 jarsigner 校验 —— 商店要求 upload key 签名"
  fi
}
