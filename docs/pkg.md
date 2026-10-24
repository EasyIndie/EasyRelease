# `.pkg` 与 Developer ID Installer

> 状态:EasyRelease 代码路径已支持(`productsign` + `notarytool` + `stapler` + `spctl -t install`),
> 但**尚未用真实 Installer 证书实跑**。配好证书后跑 EasyApple 的 `verify-pkg.yml` 即可补齐。

## 1. 需要哪种证书

`.pkg` 安装包必须用 **Developer ID Installer** 证书签名,**不是**
`Developer ID Application`。两者用途不同:

| 证书 | 用途 | 工具 |
|---|---|---|
| Developer ID Application | `.app` / `.dmg` / `.zip` 内的 app | `codesign` |
| Developer ID Installer | `.pkg` 安装包 | `productsign` |

前置条件:付费 Apple Developer Program 账号,角色为 Account Holder 或 Admin。

## 2. 获取证书

### 方式 A:Xcode(推荐)

1. Xcode → Settings → Accounts → 选择团队
2. Manage Certificates → 左下角 `+` → **Developer ID Installer**
3. Xcode 会生成私钥并下载证书到登录钥匙串

### 方式 B:Developer 网站

1. 打开 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list)
2. `Certificates` → `+` → 选 **Developer ID Installer** → Continue
3. 在 Mac 上用 **Keychain Access** → Certificate Assistant →
   Request a Certificate from a Certificate Authority
   - 填 Apple ID 邮箱与名称
   - 选 **Saved to disk**
4. 上传生成的 `.certSigningRequest`
5. 下载 `.cer` → 双击安装到登录钥匙串

## 3. 导出 p12

1. Keychain Access → `login` → **My Certificates**
2. 找到 `Developer ID Installer: Name (TEAMID)`,确认它带有私钥(可展开)
3. 右键 → Export → 保存为 `.p12`,设置导出密码
4. 生成 base64:

```bash
openssl base64 -A -in installer.p12 > installer.p12.b64
# 或:base64 -i installer.p12 | pbcopy
```

> 不要把 `.p12` / 密码提交到仓库;只放 GitHub Secrets。

## 4. 配置到 GitHub

建议用 **organization secrets**:

| Secret / Variable | 内容 |
|---|---|
| `APPLE_INSTALLER_P12_BASE64` | Installer `.p12` 的 base64 |
| `APPLE_INSTALLER_P12_PASSWORD` | `.p12` 导出密码 |
| `APPLE_TEAM_ID` | 10 位 Team ID |
| `APPLE_ASC_API_KEY_ID` / `APPLE_ASC_ISSUER_ID` / `APPLE_ASC_API_KEY` | 公证用 API Key |
| `MACOS_INSTALLER_IDENTITY`(可选 variable) | 完整身份,如 `Developer ID Installer: Name (TEAMID)` |

不配 `MACOS_INSTALLER_IDENTITY` 也可以:EasyRelease `apple-v0.6.3+` 会对 `.pkg`
自动按 `Developer ID Installer` + `team_id` 查找身份。

## 5. 构建 pkg

> **pkg 内的 app 必须先签 Developer ID Application(带 hardened runtime + timestamp),
> 再用 pkgbuild 打包;否则公证会报「binary is not signed with a valid Developer ID /
> no secure timestamp / hardened runtime disabled」。**

EasyRelease 只做签名/公证,不负责构建。最小示例:

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

## 6. 用 EasyRelease 签名 + 公证

```yaml
- uses: EasyIndie/EasyRelease/apple@apple-v0.6.3
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

处理顺序:`productsign --timestamp` → `notarytool submit` → `stapler staple` →
`spctl -a -t install`。

## 7. 本地验证

```bash
pkgutil --check-signature MyApp.pkg
xcrun stapler validate MyApp.pkg
spctl -a -vvv -t install MyApp.pkg
# 期望:accepted / source=Notarized Developer ID
```

## 8. 证书轮换

- 证书有效期以 Apple Developer 后台为准;到期前用新证书重新导出 p12。
- 轮换顺序:先加新 secret → 跑一次 `verify-pkg.yml` → 再删旧 secret。
- 泄露时立即在后台 Revoke,并更换 secret。

## 9. 实跑验证

EasyApple 已准备 `.github/workflows/verify-pkg.yml`:

```bash
gh workflow run verify-pkg.yml -R EasyIndie/EasyApple
```

配置缺失时会在 preflight 明确列出缺少的 secret,不会进入签名步骤。
