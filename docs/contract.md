# 契约(Contract)

> 这是 EasyRelease 与业务仓库之间的稳定接口。改这里等于改公共 API,需要新的主版本。

## 1. 设计边界

| 做 | 不做 |
|---|---|
| 对已有产物签名、公证、staple、校验 | 构建 SwiftPM / Xcode / Gradle 工程 |
| 生成 `manifest.json` 与校验结果 | 决定版本号策略、打 tag |
| 用平台原生工具 | 引入 fastlane / 第三方公证 SDK |
| 接收调用方注入的凭证 | 存储、读取、回传凭证 |

## 2. 命名约定

输入/输出统一 **snake_case**(如 `p12_base64`、`dry_run`、`signed_artifact`)。

原因:GitHub Actions 表达式里 `inputs.p12-base64` 的连字符会被解析器当运算符,必须写成
`inputs['p12-base64']`。snake_case 在 YAML、shell、表达式里都安全。

布尔输入在 composite action 中是字符串,统一接受 `true/false/1/0/yes/no/on/off`。

## 3. 通用输入

| 输入 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `artifact` | ✅ | — | `.app` / `.dmg` / `.pkg` / `.zip` 路径 |
| `mode` | | `adhoc` | `adhoc` 或 `developer-id` |
| `notarize` | | `false` | 仅 `developer-id` 可用 |
| `staple` | | `true` | 公证通过后自动 staple |
| `dry_run` | | `false` | 只校验输入并产出 manifest |
| `version` | | 从 Info.plist | 写入 manifest |
| `build_number` | | 从 Info.plist | 写入 manifest |
| `bundle_id` | | 从 Info.plist | 写入 manifest |
| `checkout_ref` | | 事件 ref | reusable workflow 检出业务仓库的 ref |
| `output_dir` | | `$GITHUB_WORKSPACE/easyrelease` | manifest 输出目录 |
| `debug` | | `false` | 打印环境信息,不打印密钥 |

## 4. Apple 专属输入

> 凭据获取、导出、GitHub 配置与轮换统一见 [credentials.md](credentials.md)。

| 输入 | 用途 | 何时必填 |
|---|---|---|
| `p12_base64` | Developer ID Application 证书;`.pkg` 用 Developer ID Installer | `mode=developer-id` |
| `p12_password` | p12 密码 | `mode=developer-id` |
| `team_id` | 按 Team ID 匹配签名身份 | 建议填 |
| `identity` | 完整签名身份(名称或 SHA-1) | 留空则按产物类型匹配 Application / Installer |
| `keychain_password` | 临时 keychain 密码 | 留空自动生成 |
| `notary_auth` | `auto` / `api-key` / `apple-id` | 默认 `auto` |
| `apple_id` | Apple ID | `notary_auth=apple-id` |
| `apple_password` | App 专用密码 | `notary_auth=apple-id` |
| `asc_key_id` | App Store Connect API Key ID | `notary_auth=api-key` |
| `asc_issuer_id` | App Store Connect Issuer ID | `notary_auth=api-key` |
| `asc_key_p8` | API 私钥内容(PEM 或 base64) | `notary_auth=api-key` |
| `entitlements` | hardened runtime 权限文件 | 按需 |
| `timeout` | 公证等待超时,默认 `30m` | 按需 |

### zip 输入

`.zip` 必须**恰好包含一个** `.app` / `.dmg` / `.pkg`;嵌套在子目录里也可以。
处理流程:解包 → 签名/公证/staple 内层 → 重新打包为 `<name>-signed.zip` → 再解压校验。
manifest 会记录 `container=zip`、`inner_artifact`、`inner_kind`。

## 5. 输出

| 输出 | 说明 |
|---|---|
| `signed_artifact` | 处理后的产物绝对路径 |
| `sha256` | 处理后产物的 SHA-256 |
| `manifest_path` | `manifest.json` 路径 |
| `notarization_id` | `notarytool` submission id;未公证为空 |
| `verified` | `true` / `false` |

zip 输入时 `signed_artifact` 指向新生成的 `<name>-signed.zip`。

reusable workflow 在 `upload_artifact: true` 时上传**扁平** artifact:
根目录直接是 `<app>.app` 与 `apple-manifest.json`,下游 release job 不需要解析
`apps/...` 深路径。

## 6. manifest schema

```json
{
  "schema": 1,
  "platform": "apple",
  "status": "ok",
  "artifact": "/abs/path/MyApp.app",
  "artifact_kind": "app",
  "container": "",
  "inner_artifact": "",
  "inner_kind": "app",
  "input_artifact": "/abs/path/MyApp.app",
  "bundle_id": "com.easyindie.myapp",
  "version": "1.2.0",
  "build": "10200",
  "mode": "developer-id",
  "dry_run": false,
  "signed": true,
  "notarized": true,
  "stapled": true,
  "gatekeeper": "accepted",
  "verified": true,
  "notary_auth": "api-key",
  "notarization_id": "…",
  "sha256_before": "…",
  "sha256": "…",
  "toolchain": { "xcode": "Xcode 27.0", "macos": "27.0.1" },
  "created_at": "2026-10-24T12:00:00Z"
}
```

约定:

- `status`:`ok` / `dry-run`
- `gatekeeper`:`accepted` / `disabled` / `skipped`
- `sha256_before` 与 `sha256` 不同,说明签名/staple 确实改写了产物
- 后续 Android 复用同名字段,只把 `platform` 改成 `android`

## 7. 版本策略

| 平台 | 不可变 tag | 浮动别名 |
|---|---|---|
| Apple | `apple-v0.4.0` | `apple-v0` |
| Android | `android-v0.1.0` | `android-v0` |

- 破坏性变更 → 升主版本,旧主版本保留至少一个大版本周期。
- 生产仓库 pin 精确 tag 或 SHA。
- 业务仓库只在 `pull_request` 之外使用带凭证的调用。

## 8. Runner 与权限

| 平台 | runner | 必需工具 |
|---|---|---|
| Apple | macOS(默认 `xcode-27`) | 完整 Xcode:`codesign` / `notarytool` / `stapler` / `productsign` |
| Android | Linux | JDK + Android build-tools:`apksigner` |

调用方必须给:

```yaml
permissions:
  contents: write   # 只有 release=true 时需要
```

`workflow_call` 额外支持 `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD`(App 专用密码认证);
其 secret 名与 EasyIndie 组织一致
(`APPLE_CERTIFICATE_P12_BASE64` / `APPLE_CERTIFICATE_P12_PASSWORD` /
`APPLE_ASC_API_KEY` / `APPLE_ASC_API_KEY_ID` / `APPLE_ASC_ISSUER_ID`),
调用方直接 `secrets: inherit`。其他组织若命名不同,仍可在 `jobs.<id>.secrets` 显式映射。

`release: true` 时,reusable workflow 会自动打包发布物:
`.app` → zip、`.zip` → 直传、`.dmg` / `.pkg` → 原生文件,并附带
`<app>-<tag>-manifest.json` 与各自的 `.sha256`。

composite action 不能提升权限,只能使用调用方授予的上限。

## 9. 安全规则

凭据的存放、导入、清理、轮换与排错统一见
[credentials.md 第 10 节](credentials.md#10-安全规则);这里只保留 action 接口层约束:

1. 凭证只经 `secrets` → 输入,不落盘、不回传。
2. 带凭证的 job 不加 `pull_request_target`,不让 fork PR 触达。
3. 生产 pin SHA;tag 保护 + PR review。
4. action 内部临时文件由 `EXIT` trap 清理(实现见 `apple/scripts/`)。

## 10. 兼容矩阵

> 实测 run 与公证 ID 见 [verification.md](verification.md)。

| EasyRelease | Xcode | macOS | 备注 |
|---|---|---|---|
| `apple-v0.x` | 27.0 | 26+/27 | 与 EasyApple 当前环境对齐;2026-10-24 快照 |
