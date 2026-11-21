#!/usr/bin/env bash
# shellcheck disable=SC2034  # 变量由 main.sh 跨文件读取
# Android 事后签名(默认不启用,只有 mode=sign 时走这里)。
# 由 main.sh source,不单独执行。
#
# 什么时候需要它:构建产物是**未签名**的(例如自定义构建脚本、Unity/Flutter
# 的非标准打包、或项目故意不把密钥放进构建环境)。Gradle 正常配置了
# signingConfigs 的项目不需要 —— 那种情况下构建期已经签好,事后重签只会
# 破坏 v2/v3 签名链。
#
# 密码传递:
#   · apksigner 支持 `--ks-pass env:VAR`,密码不进命令行;
#   · jarsigner(JDK 17)只支持 `-storepass <password>` 形式,所以 AAB 签名时密码
#     会出现在本进程的命令行上。runner 是一次性独占虚拟机,可接受,但不要在
#     多租户机器上开 mode=sign。

EASYRELEASE_SIGNED_APK=""
EASYRELEASE_SIGNED_AAB=""

_easyrelease_signed_name() {
  # app-release.apk → app-release-signed.apk(已经是 -signed 就原样)
  local path="$1" suffix="$2" base ext
  case "$path" in
    *-"$suffix") printf '%s' "$path" ;;
    *)
      base="${path%.*}"
      ext="${path##*.}"
      printf '%s-signed%s' "$base" ".$ext"
      ;;
  esac
}

easyrelease_sign_apk() {
  local input="$1" output="$2" keystore="$3"
  local store_password="$4" key_alias="$5" key_password="$6" work="$7"

  [ -f "$input" ] || die "待签名 APK 不存在:$input"

  # zipalign 必须在签名之前:签名后改内容会让 v2/v3 摘要失效。
  local source="$input"
  if ! "$EASYRELEASE_TOOL_ZIPALIGN" -c -p 4 "$(easyrelease_tool_path "$input")" >/dev/null 2>&1; then
    source="$work/aligned.apk"
    "$EASYRELEASE_TOOL_ZIPALIGN" -p 4 -f "$(easyrelease_tool_path "$input")" \
      "$(easyrelease_tool_path "$source")" >/dev/null 2>&1 \
      || die "zipalign 失败:$input"
    ok "zipalign 已重新对齐"
  else
    ok "zipalign 校验通过"
  fi

  mkdir -p "$(dirname "$output")"
  EASYRELEASE_KS_STORE_PASS="$store_password" \
  EASYRELEASE_KS_KEY_PASS="$key_password" \
    easyrelease_run_tool "$EASYRELEASE_TOOL_APKSIGNER" sign \
      --ks "$(easyrelease_tool_path "$keystore")" \
      --ks-pass env:EASYRELEASE_KS_STORE_PASS \
      --ks-key-alias "$key_alias" \
      --key-pass env:EASYRELEASE_KS_KEY_PASS \
      --out "$(easyrelease_tool_path "$output")" "$(easyrelease_tool_path "$source")" \
      >/dev/null 2>&1 \
    || die "apksigner sign 失败(检查 keystore / 别名 / 密码)"

  EASYRELEASE_SIGNED_APK="$output"
  ok "APK 已签名:$(basename "$output")"
}

easyrelease_sign_aab() {
  local input="$1" output="$2" keystore="$3"
  local store_password="$4" key_alias="$5" key_password="$6"

  [ -f "$input" ] || die "待签名 AAB 不存在:$input"
  mkdir -p "$(dirname "$output")"
  cp "$input" "$output"

  "$EASYRELEASE_TOOL_JARSIGNER" -keystore "$(easyrelease_tool_path "$keystore")" \
    -storepass "$store_password" -keypass "$key_password" \
    -sigalg SHA256withRSA -digestalg SHA-256 \
    "$(easyrelease_tool_path "$output")" "$key_alias" >/dev/null 2>&1 \
    || die "jarsigner 签名 AAB 失败(检查 keystore / 别名 / 密码)"

  EASYRELEASE_SIGNED_AAB="$output"
  ok "AAB 已签名:$(basename "$output")"
}
