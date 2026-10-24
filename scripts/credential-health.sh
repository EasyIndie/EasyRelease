#!/usr/bin/env bash
# 检查 EasyRelease 使用的 Developer ID Application / Installer 证书到期时间。
# 由 .github/workflows/credential-health.yml 调用,也可本地跑。
#
# 输入环境变量:
#   APPLE_CERTIFICATE_P12_BASE64 / APPLE_CERTIFICATE_P12_PASSWORD
#   APPLE_INSTALLER_P12_BASE64   / APPLE_INSTALLER_P12_PASSWORD
#   THRESHOLD_DAYS(默认 30)
# 输出:
#   $RUNNER_TEMP/credential-health.tsv
#   $RUNNER_TEMP/credential-health-alert.md(仅告警时)
#   $GITHUB_OUTPUT: alert=true|false, expired=true|false

set -euo pipefail

THRESHOLD="${THRESHOLD_DAYS:-30}"
TMP="${RUNNER_TEMP:-/tmp}"
mkdir -p "$TMP"
OUT="$TMP/credential-health.tsv"
ALERT="$TMP/credential-health-alert.md"
: > "$OUT"
rm -f "$ALERT"

alert=0
expired=0

check_cert() {
  local name="$1" b64="$2" password="$3"
  local dir keychain keychain_password subject notafter days

  if [ -z "$b64" ]; then
    printf '%s\tnot-configured\t-\t-\n' "$name" >> "$OUT"
    return 0
  fi

  dir="$(mktemp -d)"
  keychain="$dir/health.keychain-db"
  keychain_password="$(openssl rand -hex 16)"
  printf '%s' "$b64" | openssl base64 -d -A > "$dir/cert.p12"

  # 用 security import 解析,兼容 Apple Keychain 导出的 p12(openssl 3 可能读不了)。
  security create-keychain -p "$keychain_password" "$keychain" >/dev/null 2>&1 || true
  security set-keychain-settings -lut 600 "$keychain" >/dev/null 2>&1 || true
  security unlock-keychain -p "$keychain_password" "$keychain" >/dev/null 2>&1 || true
  security import "$dir/cert.p12" -k "$keychain" -P "$password" -A >/dev/null 2>&1 || true
  security find-certificate -a -c "$name" -p "$keychain" > "$dir/cert.pem" 2>/dev/null || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true

  if [ ! -s "$dir/cert.pem" ]; then
    printf '%s\tread-error(import/no matching cert)\t-\t-\n' "$name" >> "$OUT"
    rm -rf "$dir"
    alert=1
    return 0
  fi

  subject="$(openssl x509 -in "$dir/cert.pem" -noout -subject | sed 's/^subject=//')"
  notafter="$(openssl x509 -in "$dir/cert.pem" -noout -enddate | sed 's/^notAfter=//')"
  days="$(python3 - "$notafter" <<'PY'
import sys, datetime
s = sys.argv[1].replace('GMT', '').strip()
s = ' '.join(s.split())
d = datetime.datetime.strptime(s, '%b %d %H:%M:%S %Y')
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
print((d - now).days)
PY
)"

  if ! printf '%s' "$days" | grep -Eq '^-?[0-9]+$'; then
    printf '%s\tparse-error(%s)\t-\t-\n' "$name" "$notafter" >> "$OUT"
    rm -rf "$dir"
    alert=1
    return 0
  fi

  printf '%s\t%s\t%s\t%s\n' "$name" "$subject" "$notafter" "$days" >> "$OUT"
  if [ "$days" -lt 0 ]; then
    expired=1
    alert=1
  elif [ "$days" -le "$THRESHOLD" ]; then
    alert=1
  fi
  rm -rf "$dir"
}

check_cert "Developer ID Application" \
  "${APPLE_CERTIFICATE_P12_BASE64:-}" "${APPLE_CERTIFICATE_P12_PASSWORD:-}"
check_cert "Developer ID Installer" \
  "${APPLE_INSTALLER_P12_BASE64:-}" "${APPLE_INSTALLER_P12_PASSWORD:-}"

render_table() {
  echo "| 证书 | Subject | NotAfter | 剩余天数 |"
  echo "|---|---|---|---|"
  while IFS=$'\t' read -r name subject notafter days; do
    echo "| $name | \`$subject\` | $notafter | $days |"
  done < "$OUT"
}

render_table | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$alert" -eq 1 ]; then
  {
    echo "## 证书到期提醒"
    echo ""
    echo "阈值:${THRESHOLD} 天"
    echo ""
    render_table
    echo ""
    repo="${GITHUB_REPOSITORY:-EasyIndie/EasyRelease}"
    echo "轮换步骤见 [docs/credentials.md](https://github.com/${repo}/blob/main/docs/credentials.md) 第 9 节。"
  } > "$ALERT"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  if [ "$alert" -eq 1 ]; then echo "alert=true" >> "$GITHUB_OUTPUT"; else echo "alert=false" >> "$GITHUB_OUTPUT"; fi
  if [ "$expired" -eq 1 ]; then echo "expired=true" >> "$GITHUB_OUTPUT"; else echo "expired=false" >> "$GITHUB_OUTPUT"; fi
fi

if [ "$alert" -eq 1 ]; then
  echo "::warning::证书即将到期或已过期(阈值 ${THRESHOLD} 天)"
fi
