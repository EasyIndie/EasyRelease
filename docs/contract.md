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
| `artifact` | ✅ | — | `.app` / `.dmg` / `.pkg` 路径 |
| `mode` | | `adhoc` | `adhoc` 或 `developer-id` |
| `notarize` | | `false` | 仅 `developer-id` 可用 |
| `staple` | | `true` | 公证通过后自动 staple |
| `dry_run` | | `false` | 只校验输入并产出 manifest |
| `version` | | 从 Info.plist | 写入 manifest |
| `build_number` | | 从 Info.plist | 写入 manifest |
| `bundle_id` | | 从 Info.plist | 写入 manifest |
| `output_dir` | | `$GITHUB_WORKSPACE/easyrelease` | manifest 输出目录 |
| `debug` | | `false` | 打印环境信息,不打印密钥 |

## 4. Apple 专属输入

| 输入 | 用途 | 何时必填 |
|---|---|---|
| `p12_base64` | Developer ID Application 证书 | `mode=developer-id` |
| `p12_password` | p12 密码 | `mode=developer-id` |
| `team_id` | 按 Team ID 匹配签名身份 | 建议填 |
| `identity` | 完整签名身份(名称或 SHA-1) | 留空则用 `team_id` 匹配 |
| `keychain_password` | 临时 keychain 密码 | 留空自动生成 |
| `asc_key_id` | App Store Connect API Key ID | `notarize=true` |
| `asc_issuer_id` | App Store Connect Issuer ID | `notarize=true` |
| `asc_key_p8` | API 私钥内容(PEM 或 base64) | `notarize=true` |
| `entitlements` | hardened runtime 权限文件 | 按需 |
| `timeout` | 公证等待超时,默认 `30m` | 按需 |

## 5. 输出

| 输出 | 说明 |
|---|---|
| `signed_artifact` | 处理后的产物绝对路径 |
| `sha256` | 处理后产物的 SHA-256 |
| `manifest_path` | `manifest.json` 路径 |
| `notarization_id` | `notarytool` submission id;未公证为空 |
| `verified` | `true` / `false` |

## 6. manifest schema

```json
{
  "schema": 1,
  "platform": "apple",
  "status": "ok",
  "artifact": "/abs/path/MyApp.app",
  "artifact_kind": "app",
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

`workflow_call` 的 secret 名与 EasyIndie 组织一致
(`APPLE_CERTIFICATE_P12_BASE64` / `APPLE_CERTIFICATE_P12_PASSWORD` /
`APPLE_ASC_API_KEY` / `APPLE_ASC_API_KEY_ID` / `APPLE_ASC_ISSUER_ID`),
调用方直接 `secrets: inherit`。其他组织若命名不同,仍可在 `jobs.<id>.secrets` 显式映射。

composite action 不能提升权限,只能使用调用方授予的上限。

## 9. 安全规则

1. 凭证只经 `secrets` → action 输入,不落盘到仓库。
2. Apple 证书导入**临时 keychain**,`EXIT` trap 删除。
3. `.p8` 写入 `RUNNER_TEMP` 后 `chmod 600`,用完删除。
4. 不用 `set -x`;不打印 base64、密码、p8。
5. 带凭证的 job 不加 `pull_request_target`,不让 fork PR 触达。
6. 生产 pin SHA;tag 保护 + PR review。

## 10. 兼容矩阵

| EasyRelease | Xcode | macOS | 备注 |
|---|---|---|---|
| `apple-v0.x` | 27.0 | 26+/27 | 与 EasyApple 当前环境对齐;2026-10-24 快照 |
