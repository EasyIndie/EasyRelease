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
| ad-hoc 签名 + 校验(`.app` / `.dmg`) | ✅ 已验证(2026-10-24,本机 macOS 27 / Xcode 27,13 项本地自测) |
| Developer ID 签名 | ✅ 已验证(2026-10-24,EasyApple EnvDemo,run [40095862502](https://github.com/EasyIndie/EasyApple/actions/runs/40095862502)) |
| 公证 + staple | ✅ 已验证(同上,submission `78a6fd71-1b0c-49c4-acf7-68e0e33f29af`) |
| reusable workflow 全链路 | ✅ 已验证(2026-10-24,run [40096049639](https://github.com/EasyIndie/EasyApple/actions/runs/40096049639)) |
| `.pkg` 签名 | ⚠️ 未验证(需 Developer ID Installer 证书) |
| Android 签名 | ⏳ 未实现(契约已预留) |

> 没跑通的链路不要写成「已验证」。本仓库 selftest 覆盖 ad-hoc 与 dry-run;
> Developer ID + 公证通过 EasyApple 集成 run 验证(见上表)。

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
    secrets:
      APPLE_P12_BASE64: ${{ secrets.APPLE_CERTIFICATE_P12_BASE64 }}
      APPLE_P12_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_P12_PASSWORD }}
      ASC_KEY_ID: ${{ secrets.APPLE_ASC_API_KEY_ID }}
      ASC_ISSUER_ID: ${{ secrets.APPLE_ASC_ISSUER_ID }}
      ASC_KEY_P8: ${{ secrets.APPLE_ASC_API_KEY }}
```

> reusable workflow 的 secret 名是通用名(`APPLE_P12_BASE64` 等),与组织现有
> `APPLE_CERTIFICATE_P12_BASE64` 不同时,必须像上面这样显式映射;`secrets: inherit`
> 只在两边命名完全一致时可用。

### 方式 B：只插入签名/公证步骤

```yaml
- uses: EasyIndie/EasyRelease/apple@apple-v0
  id: sign
  with:
    artifact: .build/bundle/MyApp.app
    mode: developer-id
    notarize: "true"
    p12_base64: ${{ secrets.APPLE_P12_BASE64 }}
    p12_password: ${{ secrets.APPLE_P12_PASSWORD }}
    team_id: ${{ secrets.APPLE_TEAM_ID }}
    asc_key_id: ${{ secrets.ASC_KEY_ID }}
    asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
    asc_key_p8: ${{ secrets.ASC_KEY_P8 }}
```

没有证书时先用 ad-hoc 验证接线：

```yaml
- uses: EasyIndie/EasyRelease/apple@apple-v0
  with:
    artifact: .build/bundle/MyApp.app
    mode: adhoc
```

## 本地自测(不需要证书)

```bash
bash scripts/local-selftest.sh
```

覆盖 ad-hoc `.app` / `.dmg`、dry-run、缺产物、`adhoc + notarize` 组合错误、缺证书等失败路径。
2026-10-24 在本机(macOS 27.0.1 / Xcode 27.0)13 项全通过。

## 目录

```
apple/                Apple 平台 composite action + 原生脚本
lib/                  共享 shell 函数
scripts/              本地自测
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
| `apple-v0.1.0` | Apple 平台不可变版本 |
| `apple-v0` | 浮动别名,只用于试用 |
| `android-v0.x` | 预留,与 Apple 独立演进 |

生产建议 pin 精确 tag 或 commit SHA,不要 `@main`。

## 文档

- [docs/contract.md](docs/contract.md):输入、输出、manifest、版本策略
- [docs/apple.md](docs/apple.md):Apple 接入、凭证配置、排错

## 与 EasyApple 的关系

EasyApple 是 Apple 无 IDE 开发实践库,也是本仓库的**首个消费方**;
发布基础设施不再放进实践库,避免版本与评审互相牵连。

## License

MIT
