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

## 本地自测(不需要证书)

```bash
bash scripts/local-selftest.sh
```

覆盖 ad-hoc `.app` / `.dmg` / `.zip`、dry-run、缺产物、`adhoc + notarize`
组合错误、缺证书等失败路径。2026-10-24 在本机(macOS 27.0.1 / Xcode 27.0)
**22 项全通过**。

## 目录

```
apple/                Apple 平台 composite action + 原生脚本
lib/                  共享 shell 函数
scripts/              本地自测 + 证书健康检查
.github/workflows/
  apple-release.yml   完整流水线(workflow_call)
  selftest.yml        无证书自测(adhoc + dry-run)
docs/
  contract.md         输入/输出/manifest 契约
  apple.md            Apple 接入、凭证与排错
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
| `android-v0.x` | 预留,与 Apple 独立演进 |

生产建议 pin 精确 tag 或 commit SHA,不要 `@main`。

## 文档

- [docs/credentials.md](docs/credentials.md):**全部凭据的获取、导出、GitHub 配置、轮换与排错**
- [docs/verification.md](docs/verification.md):**唯一验证记录**(run / 公证 ID / 未覆盖项)
- [docs/contract.md](docs/contract.md):EasyRelease 输入、输出、manifest、版本策略
- [docs/apple.md](docs/apple.md):Apple 接入、使用方式与排错
- [docs/pkg.md](docs/pkg.md):`.pkg` 构建、签名、公证与验证

## 与 EasyApple 的关系

EasyApple 是 Apple 无 IDE 开发实践库,也是本仓库的**首个消费方**;
发布基础设施不再放进实践库,避免版本与评审互相牵连。

## License

MIT
