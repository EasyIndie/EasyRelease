# 契约(Contract)

> 这是 EasyRelease 与业务仓库之间的稳定接口。改这里等于改公共 API,需要新的主版本。

## 1. 设计边界

| 做 | 不做 |
|---|---|
| 对已有产物签名、公证、staple、校验 | 构建 SwiftPM / Xcode / Gradle 工程 |
| 校验 Android APK / AAB(清单 / 版本 / 签名 / ABI / 结构) | 构建 APK / AAB、上架商店 |
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

## 4b. Android 专属输入

> 校验项与排错见 [android.md](android.md)。`android-v0.1.0` **只校验不签名**:
> 签名在构建期由业务仓库完成(CI 构建前还原密钥),事后重签会破坏 v2/v3 签名链。

| 输入 | 用途 | 何时必填 |
|---|---|---|
| `apk` | `.apk` 路径 | 与 `aab` 至少一个 |
| `aab` | `.aab` 路径 | 与 `apk` 至少一个 |
| `expected_package` | 期望的 applicationId | 建议填 |
| `expected_version_name` / `expected_version_code` | 期望版本 | 建议填 |
| `expected_sha256` | 签名证书 SHA-256,逗号分隔可多个 | 建议填(锁死密钥) |
| `forbidden_strings` | 产物里不允许出现的字符串(如 debug 钩子的广播 action) | 按需 |
| `require_abis` | 必须包含的 ABI,默认 `arm64-v8a` | 按需 |
| `min_target_sdk` | targetSdk 下限 | 按需(Play / 国内商店门槛由调用方决定) |
| `build_tools` | 显式指定 build-tools 目录 | 留空则从 `ANDROID_HOME` 挑最高版本 |

reusable workflow 额外接受:`build_command`(构建命令,留空表示产物已存在)、
`tag_prefix`(从 `GITHUB_REF_NAME` 剥前缀得版本)、`version_file` / `version_file_key`
(可选的版本一致性断言)、`keystore_path` / `keystore_properties` / `alias_property`
(密钥落盘位置与 properties 写法)、`upload_artifact`。

**密钥与凭据**全部来自 secrets(`ANDROID_KEYSTORE_BASE64` / `ANDROID_STORE_PASSWORD` /
`ANDROID_KEY_PASSWORD` / `ANDROID_KEY_ALIAS`),与 EasyIndie 组织一致,
调用方直接 `secrets: inherit`。没给 base64 时跳过还原并打 warning。

`keystore.properties` 的 `storeFile` 写**相对 properties 文件的路径**,
这样同一份配置在本机与 CI 都能用。

## 5. 输出

| 输出 | 说明 |
|---|---|
| `signed_artifact` | 处理后的产物绝对路径 |
| `sha256` | 处理后产物的 SHA-256 |
| `manifest_path` | `manifest.json` 路径 |
| `notarization_id` | `notarytool` submission id;未公证为空 |
| `verified` | `true` / `false` |

Android 侧输出(平台字段用 `platform: "android"`,签名相关输出留空):

| 输出 | 说明 |
|---|---|
| `artifact` | 主产物(有 APK 时是 APK,否则 AAB) |
| `apk` / `aab` | 各自的绝对路径 |
| `sha256` / `sha256_aab` | 各自的 SHA-256 |
| `package` / `version_name` / `version_code` | 从产物里读出来的值 |
| `certificate_sha256` | 签名证书指纹(小写十六进制) |
| `verified` | APK 与 AAB 的校验是否全部通过 |

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

Android 用同一套字段,`platform: "android"`,签名相关字段留空,另加产物维度:

```json
{
  "schema": 1,
  "platform": "android",
  "status": "ok",
  "artifact": "/abs/path/app-release.apk",
  "artifact_kind": "apk",
  "apk": "/abs/path/app-release.apk",
  "aab": "/abs/path/app-release.aab",
  "bundle_id": "com.example.myapp",
  "version": "1.2.3",
  "build": "10203",
  "target_sdk": "36",
  "abis": "arm64-v8a armeabi-v7a",
  "certificate_sha256": "d8121929…",
  "dry_run": false,
  "verified": true,
  "apk_verified": true,
  "aab_verified": true,
  "sha256": "…",
  "sha256_aab": "…",
  "toolchain": { "build_tools": "36.0.0", "java": "/opt/java" },
  "created_at": "2026-11-20T12:00:00Z"
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

| EasyRelease | build-tools | JDK | 备注 |
|---|---|---|---|
| `android-v0.1.0` | 36.0.0 | 17 | 只校验;本地自测 21 项通过(WSL2);2026-11-20 快照 |
