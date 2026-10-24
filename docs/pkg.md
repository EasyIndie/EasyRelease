# `.pkg` 构建与验证

> 证书获取、导出、GitHub secrets 配置、轮换统一见
> [credentials.md](credentials.md);本文只讲 pkg 的构建、签名、公证和验证。

## 1. 前置

`.pkg` 用 **Developer ID Installer** 证书;pkg 里的 app 仍然用
**Developer ID Application** 签名。

- Installer 证书配置:见 [credentials.md](credentials.md) 第 4 节
- secrets:`APPLE_INSTALLER_P12_BASE64`、`APPLE_INSTALLER_P12_PASSWORD`、
  `APPLE_TEAM_ID`(+ 公证 API Key)
- EasyRelease `v0.6.3+` 对 `.pkg` 自动按 Installer 身份查找;也可显式传
  `identity: "Developer ID Installer: ..."`

## 2. 先签 app,再打 pkg

这一步不能省:公证会检查 pkg 内 app 的 Developer ID 签名、timestamp 和
hardened runtime。

```yaml
- uses: EasyIndie/EasyRelease/apple@apple-v0.6.4
  with:
    artifact: build/MyApp.app
    mode: developer-id
    notarize: "false"
    identity: ${{ vars.MACOS_SIGNING_IDENTITY }}
    p12_base64: ${{ secrets.APPLE_CERTIFICATE_P12_BASE64 }}
    p12_password: ${{ secrets.APPLE_CERTIFICATE_P12_PASSWORD }}
```

然后打 pkg:

```bash
root="$RUNNER_TEMP/pkg-root"
mkdir -p "$root"
ditto "build/MyApp.app" "$root/MyApp.app"

pkgbuild --root "$root" \
  --identifier com.example.myapp \
  --version 1.2.0 \
  --install-location /Applications \
  MyApp.pkg
```

需要安装向导/多包时用 `productbuild --distribution distribution.xml`。

## 3. 用 EasyRelease 签名 + 公证

```yaml
- uses: EasyIndie/EasyRelease/apple@apple-v0.6.4
  with:
    artifact: MyApp.pkg
    mode: developer-id
    notarize: "true"
    team_id: ${{ secrets.APPLE_TEAM_ID }}
    # identity 可省略,自动匹配 Developer ID Installer
    p12_base64: ${{ secrets.APPLE_INSTALLER_P12_BASE64 }}
    p12_password: ${{ secrets.APPLE_INSTALLER_P12_PASSWORD }}
    asc_key_id: ${{ secrets.APPLE_ASC_API_KEY_ID }}
    asc_issuer_id: ${{ secrets.APPLE_ASC_ISSUER_ID }}
    asc_key_p8: ${{ secrets.APPLE_ASC_API_KEY }}
```

内部顺序:`productsign --timestamp` → 公证 → `stapler staple` →
`spctl -a -t install`。

## 4. 本地验证

```bash
pkgutil --check-signature MyApp.pkg
xcrun stapler validate MyApp.pkg
spctl -a -vvv -t install MyApp.pkg
# 期望:accepted / source=Notarized Developer ID
```

## 5. 实测与排错

- 实测记录(run / 公证 ID)见 [verification.md](verification.md)。
- 证书/公证相关错误见 [credentials.md](credentials.md) 第 11 节。
- `productsign` 在无头 runner 上的卡住问题已在 EasyRelease `v0.6.4`
  修复(临时 keychain `-A` + 300s 超时)。

复现:

```bash
gh workflow run verify-pkg.yml -R EasyIndie/EasyApple
```
