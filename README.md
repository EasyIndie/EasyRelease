# EasyRelease

Apple(以及后续 Android)发布通用能力的**独立仓库**。业务项目在自己的 workflow 里引用并配置一次，
后续所有项目的签名 / 公证 / 校验逻辑都在这里统一迭代。

- 只做**产物处理**：签名、公证、staple、校验、生成 manifest。
- **不做构建**：SwiftPM / xcodebuild / Gradle 留在业务仓库。
- **只用平台原生工具**：`codesign` / `notarytool` / `stapler` / `productsign` / `apksigner`，不引入 fastlane。
- **不保存凭证**：证书、密码、API Key 全部由调用方通过 secrets 注入。

## 状态

| 能力 | 状态 |
|---|---|
| 本地 ad-hoc `.app` / `.dmg` / `.zip` | ✅ 22 项自测 |
| `.app` Developer ID + 公证 | ✅ |
| `.dmg` Developer ID + 公证 | ✅ |
| `.zip` 输入 + 重打包校验 | ✅ |
| `.pkg` + Developer ID Installer | ✅ |
| API Key / Apple ID + 专用密码 | ✅ |
| reusable workflow / `secrets: inherit` | ✅ |
| `release.yml` dry-run | ✅ |
| **Android 校验**(APK/AAB:包名 / 版本 / 签名指纹 / ABI / Bundle 结构) | ✅ 21 项自测 |
| Android `mode=sign`(构建产物未签名时补签:`zipalign` + `apksigner` / `jarsigner`) | ✅ |

> run、公证 ID、复现命令与未覆盖项统一见 [docs/verification.md](docs/verification.md)。
> 证书到期与轮换见 [docs/credentials.md](docs/credentials.md) 第 9 节;
> 自动检查由 `.github/workflows/credential-health.yml` 每月执行。

## 快速开始

### 方式 A：整条流水线(reusable workflow)

```yaml
jobs:
  release:
    permissions:
      contents: write
    uses: EasyIndie/EasyRelease/.github/workflows/apple-release.yml@apple-v0
    with:
      app: MyApp
      bundle_id: com.easyindie.myapp
      build_command: swift build -c release && bash tools/bundle.sh
      mode: developer-id
      notarize: true
      identity: ${{ vars.MACOS_SIGNING_IDENTITY }}
      release: true
      release_tag: ${{ github.ref_name }}
    secrets: inherit
```

> reusable workflow 的 secret 名已与 EasyIndie 组织完全一致
> (`APPLE_CERTIFICATE_P12_BASE64` / `APPLE_CERTIFICATE_P12_PASSWORD` /
> `APPLE_ASC_API_KEY` / `APPLE_ASC_API_KEY_ID` / `APPLE_ASC_ISSUER_ID`),
> 所以直接 `secrets: inherit` 即可。
>
> 直接调用 `EasyRelease/apple` composite action 时没有 `inherit` 语义,
> 仍需在 `with:` 里显式写 `p12_base64: ${{ secrets.APPLE_CERTIFICATE_P12_BASE64 }}`。

单步签名/公证、ad-hoc、`.zip` / `.dmg` / `.pkg` 的用法见
[docs/apple.md](docs/apple.md)。

### 方式 B:Android(校验 + 发布;签名在构建期完成)

```yaml
jobs:
  release:
    permissions:
      contents: write
    uses: EasyIndie/EasyRelease/.github/workflows/android-release.yml@android-v0.3.0
    with:
      app: MyApp
      package_name: com.example.myapp
      tag_prefix: android-v
      version_file: app/version.properties
      apk: app/build/outputs/apk/release/app-release.apk
      aab: app/build/outputs/bundle/release/app-release.aab
      build_command: ./gradlew :app:assembleRelease :app:bundleRelease
      keystore_properties: keystore.properties   # storeFile 用相对路径
      forbidden_strings: UiDumpReceiver          # debug 钩子的广播 action
      min_target_sdk: 36
      release: true
      release_tag: ${{ github.ref_name }}
    secrets: inherit
```

默认 `mode=verify`(**只校验不签名**)—— 签名在构建期由 Gradle 完成(密钥由本仓库在
构建前还原),事后重签会破坏 v2/v3 签名链与 Play 的 upload key。
构建产物确实未签名时,传 `mode: sign` + 四个 `ANDROID_*` 凭据,由本仓库补签。
校验项、凭证与排错见 [docs/android.md](docs/android.md)。

## 本地自测(不需要证书)

```bash
bash scripts/local-selftest.sh
```

覆盖 ad-hoc `.app` / `.dmg` / `.zip`、dry-run、缺产物、`adhoc + notarize`
组合错误、缺证书等失败路径。2026-10-24 在本机(macOS 27.0.1 / Xcode 27.0)
**22 项全通过**。

Android 侧同样不需要发布证书:

```bash
ANDROID_HOME=/opt/android-sdk bash scripts/local-selftest-android.sh
```

用 `keytool` 现生成临时 keystore、用 `aapt2` 现造 fixture APK / AAB,覆盖正例、
禁词、指纹不符、debuggable、缺 ABI、dry-run、密钥还原与失败路径。
**21 项全通过**(WSL2 / build-tools 36.0.0 / JDK 17)。

## 目录

```
apple/                Apple 平台 composite action + 原生脚本
android/              Android 平台 composite action(校验 + manifest)
lib/                  共享 shell 函数
scripts/              本地自测 + 证书健康检查
.github/workflows/
  apple-release.yml   完整流水线(workflow_call)
  android-release.yml Android 流水线:还原密钥 → 构建 → 校验 → 发布
  selftest.yml        无证书自测(adhoc / dry-run / Android fixture)
docs/
  contract.md         输入/输出/manifest 契约
  apple.md            Apple 接入、凭证与排错
  android.md          Android 接入、校验项与排错
```

> Runner 标签默认 `xcode-27`(含 Xcode 27)。如果你的组织用 `macos-26` 或自托管,
> 调用时传 `runs_on`,并确保 `xcode-select -p` 指向完整 Xcode。

## 版本

| tag | 含义 |
|---|---|
| `apple-v0.1.0` | Apple 平台首个版本 |
| `apple-v0.2.0` | 支持显式 `identity`、base64 p8 |
| `apple-v0.3.x` | 真链路验证 + 文档 |
| `apple-v0.4.0` | reusable workflow secret 名对齐 EasyIndie 组织,支持 `secrets: inherit` |
| `apple-v0.5.0` | 上传 artifact 改为扁平目录(`<app>.app` + `apple-manifest.json`) |
| `apple-v0.5.1` | reusable workflow 支持 `checkout_ref`,dry-run 也检出目标 tag |
| `apple-v0.6.0` | 支持 `.zip` 输入、App 专用密码公证 |
| `apple-v0.6.1` | reusable workflow 透传 App 专用密码认证 |
| `apple-v0.6.2` | `release: true` 时自动打包:`.app` → zip、`.zip` 直传、`.dmg`/`.pkg` 原生 |
| `apple-v0.6.3` | 签名身份查找支持 `Developer ID Installer`(`.pkg`) |
| `apple-v0.6.4` | 修复 `.pkg` 的 `productsign` 无头卡住;`.pkg` 真链路验证通过 |
| `apple-v0` | 浮动别名,只用于试用 |
| `android-v0.1.0` | Android 首个版本:**只校验不签名**(APK/AAB + manifest) |
| `android-v0.2.0` | 增加 `mode=sign`:未签名产物现场补签(zipalign + apksigner / jarsigner) |
| `android-v0.3.0` | 跨平台调用扩展点:`EASYRELEASE_PATH_HELPER` / 工具路径预置(供 Windows 上的调用方) |
| `android-v0` | 浮动别名,只用于试用 |

生产建议 pin 精确 tag 或 commit SHA,不要 `@main`。

## 文档

- [docs/credentials.md](docs/credentials.md):**全部凭据的获取、导出、GitHub 配置、轮换与排错**
- [docs/verification.md](docs/verification.md):**唯一验证记录**(run / 公证 ID / 未覆盖项)
- [docs/contract.md](docs/contract.md):EasyRelease 输入、输出、manifest、版本策略
- [docs/apple.md](docs/apple.md):Apple 接入、使用方式与排错
- [docs/pkg.md](docs/pkg.md):`.pkg` 构建、签名、公证与验证
- [docs/android.md](docs/android.md):**Android 接入、校验项、凭证与排错**

## 与 EasyApple 的关系

EasyApple 是 Apple 无 IDE 开发实践库,也是本仓库的**首个消费方**;
发布基础设施不再放进实践库,避免版本与评审互相牵连。

## License

MIT
