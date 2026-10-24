# 凭据获取与配置

> 本文覆盖 EasyRelease 在 Apple 平台发布所需的全部凭据:如何申请、导出、放进 GitHub、
> 映射到 EasyRelease 输入,以及如何验证和轮换。
>
> 原则:**证书/私钥/密码只放 GitHub Secrets;仓库里只留名称和占位符。**

## 1. 总览

| 凭据 | 用途 | EasyRelease 输入 | 建议 secret 名 |
|---|---|---|---|
| Team ID | 匹配签名身份、公证团队 | `team_id` | `APPLE_TEAM_ID` |
| Developer ID Application `.p12` | 签 `.app` / `.dmg` / `.zip` 内的 app | `p12_base64` / `p12_password` | `APPLE_CERTIFICATE_P12_BASE64` / `APPLE_CERTIFICATE_P12_PASSWORD` |
| Developer ID Installer `.p12` | 签 `.pkg` | `p12_base64` / `p12_password` | `APPLE_INSTALLER_P12_BASE64` / `APPLE_INSTALLER_P12_PASSWORD` |
| App Store Connect Team API Key | 公证(推荐) | `asc_key_id` / `asc_issuer_id` / `asc_key_p8` | `APPLE_ASC_API_KEY_ID` / `APPLE_ASC_ISSUER_ID` / `APPLE_ASC_API_KEY` |
| Apple ID + App 专用密码 | 公证(备用) | `apple_id` / `apple_password` + `team_id` | `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD` |
| 完整签名身份(可选) | 精确选择证书 | `identity` | `MACOS_SIGNING_IDENTITY` / `MACOS_INSTALLER_IDENTITY`(variable) |

> `.pkg` 的签名身份必须是 **Developer ID Installer**,不能用 Application 证书。
> EasyRelease `v0.6.3+` 对 `.pkg` 会自动按 Installer 身份查找。

## 2. 前置:开发者账号与 Team ID

1. 加入 **Apple Developer Program**(付费)。
2. 需要 **Account Holder** 或 **Admin** 角色才能创建证书/团队 API Key。
3. Team ID 在 [Apple Developer 账号](https://developer.apple.com/account) →
   Membership details 查看,10 位,如 `ABCDE12345`。
4. 验证命令:

```bash
# 已安装的签名身份
security find-identity -v -p codesigning
security find-identity -v | grep "Developer ID Installer"
```

## 3. Developer ID Application 证书

用于 `.app` / `.dmg` / `.zip` 里的 app。

### 3.1 创建

**方式 A:Xcode(推荐)**

1. Xcode → Settings → Accounts → 选择团队
2. Manage Certificates → `+` → **Developer ID Application**
3. Xcode 生成私钥并下载证书到登录钥匙串

**方式 B:Developer 网站**

1. [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list)
2. `Certificates` → `+` → **Developer ID Application**
3. 用 Keychain Access → Certificate Assistant →
   Request a Certificate from a Certificate Authority
   - 填 Apple ID 邮箱和名称
   - 选 **Saved to disk**
4. 上传 `.certSigningRequest` → 下载 `.cer` → 双击安装

### 3.2 导出 p12

1. Keychain Access → `login` → **My Certificates**
2. 找到 `Developer ID Application: Name (TEAMID)`,确认带私钥
3. 右键 → Export → `.p12`,设置密码
4. 转 base64:

```bash
openssl base64 -A -in application.p12 > application.p12.b64
```

### 3.3 配置

| Secret / Variable | 值 |
|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | `application.p12.b64` 的内容 |
| `APPLE_CERTIFICATE_P12_PASSWORD` | p12 导出密码 |
| `APPLE_TEAM_ID` | Team ID(secret,不是 variable) |
| `MACOS_SIGNING_IDENTITY`(variable,可选) | `Developer ID Application: Name (TEAMID)` |

## 4. Developer ID Installer 证书

用于 `.pkg`。获取步骤与 Application 相同,但证书类型选 **Developer ID Installer**。

```bash
# 导出
openssl base64 -A -in installer.p12 > installer.p12.b64
```

| Secret / Variable | 值 |
|---|---|
| `APPLE_INSTALLER_P12_BASE64` | `installer.p12.b64` 的内容 |
| `APPLE_INSTALLER_P12_PASSWORD` | p12 导出密码 |
| `MACOS_INSTALLER_IDENTITY`(variable,可选) | `Developer ID Installer: Name (TEAMID)` |

详细步骤、`pkgbuild` 示例和 `pkgutil`/`spctl` 验证见 [pkg.md](pkg.md)。

> 注意:`.pkg` 里的 app 必须先签 **Developer ID Application**(hardened runtime +
> secure timestamp),再 `pkgbuild`;否则公证会报 app 签名无效。

## 5. App Store Connect Team API Key(推荐公证方式)

### 5.1 创建

1. 登录 [App Store Connect](https://appstoreconnect.apple.com)
2. Users and Access → Integrations → App Store Connect API
3. `Team Keys` → `+` 生成
4. 角色:按最小权限选择;公证提交通常需要 Developer 或更高权限(以实际提交成功为准)
5. 记录 **Key ID** 和 **Issuer ID**
6. 下载 `AuthKey_XXXXXXXXXX.p8`(**只能下载一次**)

> **必须用 Team Key**:Apple 文档明确说明 Individual Key 不能用于 `notaryTool`。
> 生成 Team Key 需要 Admin 账号。

### 5.2 配置

| Secret | 值 |
|---|---|
| `APPLE_ASC_API_KEY_ID` | Key ID |
| `APPLE_ASC_ISSUER_ID` | Issuer ID(UUID) |
| `APPLE_ASC_API_KEY` | `.p8` 全文(PEM)或其 base64;EasyRelease 两者都接受 |

p8 内容形如:

```
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
```

EasyRelease 会写入临时文件、`chmod 600`、job 结束删除。

## 6. Apple ID + App 专用密码(备用公证方式)

适合只有 Apple ID、没有 API Key 的场景;安全性不如 Team API Key。

### 6.1 创建

1. 登录 [Apple ID](https://account.apple.com)
2. Sign-In and Security → **App-Specific Passwords**
3. 生成一个专用密码(需要账号已开启 2FA)
4. 记录生成的密码;可随时撤销

### 6.2 配置

| Secret | 值 |
|---|---|
| `APPLE_ID` | Apple ID 邮箱 |
| `APPLE_APP_SPECIFIC_PASSWORD` | 生成的 App 专用密码 |
| `APPLE_TEAM_ID` | 10 位 Team ID |

使用:

```yaml
notary_auth: apple-id
apple_id: ${{ secrets.APPLE_ID }}
apple_password: ${{ secrets.APPLE_APP_SPECIFIC_PASSWORD }}
team_id: ${{ secrets.APPLE_TEAM_ID }}
```

> `apple_password` 是 **App 专用密码**,不是 Apple ID 登录密码。
> EasyApple 仓库里的 `APPLE_APP_SPECIFIC_PASSWORD_TEST` 仅用于验证,不要用于正式发布。

## 7. 配到 GitHub

### 7.1 组织级 vs 仓库级

- 多项目共用:放 **organization secrets**,按仓库授予可见性。
- 单项目专用(如测试密码):放 **repo secrets**。
- 变量(非密钥):`MACOS_SIGNING_IDENTITY`、`MACOS_INSTALLER_IDENTITY` 放
  organization/repo **variables**。
- `APPLE_TEAM_ID` 必须放 **secret**:EasyRelease reusable workflow 从
  `secrets.APPLE_TEAM_ID` 读取;改成 variable 会读不到。

### 7.2 命令行配置

```bash
# 证书(base64 必须单行,用 openssl -A)
openssl base64 -A -in application.p12 | gh secret set APPLE_CERTIFICATE_P12_BASE64 --org EasyIndie
gh secret set APPLE_CERTIFICATE_P12_PASSWORD --org EasyIndie

# Installer
openssl base64 -A -in installer.p12 | gh secret set APPLE_INSTALLER_P12_BASE64 --org EasyIndie
gh secret set APPLE_INSTALLER_P12_PASSWORD --org EasyIndie

# API Key
gh secret set APPLE_ASC_API_KEY_ID --org EasyIndie
gh secret set APPLE_ASC_ISSUER_ID --org EasyIndie
gh secret set APPLE_ASC_API_KEY --org EasyIndie < AuthKey_XXXXXXXXXX.p8

# Team ID 必须是 secret(reusable workflow 从 secrets.APPLE_TEAM_ID 读取)
gh secret set APPLE_TEAM_ID --org EasyIndie --body "ABCDE12345"

# 签名身份用 variable

gh variable set MACOS_SIGNING_IDENTITY --org EasyIndie \
  --body "Developer ID Application: Name (ABCDE12345)"
gh variable set MACOS_INSTALLER_IDENTITY --org EasyIndie \
  --body "Developer ID Installer: Name (ABCDE12345)"
```

> `--org` 需要组织管理员权限;没有权限就用 `--repo owner/repo`。

### 7.3 reusable workflow 的 secret 名

`EasyRelease/.github/workflows/apple-release.yml` 的 secret 名已与组织命名对齐:

`APPLE_CERTIFICATE_P12_BASE64`、`APPLE_CERTIFICATE_P12_PASSWORD`、
`APPLE_ASC_API_KEY_ID`、`APPLE_ASC_ISSUER_ID`、`APPLE_ASC_API_KEY`、
`APPLE_TEAM_ID`、`APPLE_ID`、`APPLE_APP_SPECIFIC_PASSWORD`。

调用方直接:

```yaml
    secrets: inherit
```

其他组织命名不同时,在 `jobs.<id>.secrets` 显式映射。

## 8. 验证

| 工作流(EasyApple) | 验证内容 |
|---|---|
| `verify-release.yml` | composite action + `.app` Developer ID/公证 |
| `verify-reusable.yml` | reusable workflow 全链路 |
| `verify-formats.yml` | `.dmg` 与 `.zip` 输入 |
| `verify-apple-id.yml` | Apple ID + App 专用密码 |
| `verify-pkg.yml` | `.pkg` + Installer 证书 |

手动运行:

```bash
gh workflow run verify-pkg.yml -R EasyIndie/EasyApple
```

本地验证:

```bash
# app
codesign --verify --deep --strict MyApp.app
xcrun stapler validate MyApp.app
spctl -a -vvv -t exec MyApp.app

# dmg
xcrun stapler validate MyApp.dmg
spctl -a -vvv -t open --context context:primary-signature MyApp.dmg

# pkg
pkgutil --check-signature MyApp.pkg
xcrun stapler validate MyApp.pkg
spctl -a -vvv -t install MyApp.pkg
```

期望:`accepted` / `source=Notarized Developer ID`。

## 9. 轮换与撤销

- 证书到期前:创建新证书 → 导出新 p12 → 更新 secret → 跑验证工作流 → 删除旧 secret。
- p8 泄露:App Store Connect → Integrations → 撤销 Key,重新生成。
- App 专用密码泄露:Apple ID → App-Specific Passwords → 撤销。
- 证书私钥泄露:Developer 后台 Revoke 证书,重新签发。
- 建议在到期前 30 天设提醒;EasyRelease 的 manifest 会记录公证 ID 便于追溯。

## 10. 安全规则

1. 不把 `.p12` / `.p8` / 密码 / base64 提交到仓库或贴进 issue。
2. EasyRelease 只在**临时 keychain** 导入证书,job 结束删除;p8 写入 `RUNNER_TEMP` 后删除。
3. 带凭证的 workflow 不放 `pull_request_target`,不让 fork PR 触达。
4. 生产 pin EasyRelease 的精确 tag/SHA,不要 `@main`。
5. 证书按用途分开:Application 与 Installer 不共用 p12。
6. API Key 优先于 App 专用密码;能用 Team Key 就不用 Apple ID。
7. `gh secret set` 输入后不要在 shell history 里留明文;用 `--body-file -` 或管道。

## 11. 排错

| 症状 | 原因 | 处理 |
|---|---|---|
| `MAC verification failed during PKCS12 import` | p12 密码错 / OpenSSL 3 默认加密不兼容 | 用 Keychain 导出的 p12;或 `openssl pkcs12 -export -legacy` |
| `未找到 Developer ID Application 证书` | p12 没导入 / Team ID 不匹配 | 检查 `security find-identity -v` |
| `未找到 Developer ID Installer 证书` | 用了 Application 证书签 pkg | 创建 Installer 证书并单独配 p12 |
| `productsign` 卡住 | 无头 runner 钥匙串授权 | EasyRelease `v0.6.4+` 已用 `-A` + 300s 超时 |
| 公证 `Invalid: binary is not signed with a valid Developer ID` | pkg 内 app 没签 Application | 先签 app,再 `pkgbuild` |
| `signature does not include a secure timestamp` | 签 app 时没加 `--timestamp` | EasyRelease developer-id 模式默认加 |
| `hardened runtime disabled` | app 没开 runtime | EasyRelease developer-id 模式默认 `--options runtime` |
| `Individual API key` 公证失败 | notaryTool 不支持 Individual Key | 改用 Team Key |
| `notarytool` 认证失败 | Key ID / Issuer / p8 不匹配 | 重新下载 p8,核对 Key ID/Issuer |
| App 专用密码认证失败 | 用了登录密码 | 重新生成 App 专用密码 |
