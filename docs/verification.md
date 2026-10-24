# 验证记录

> **单一证据账本。** README、`apple.md`、`pkg.md` 只写状态并链接到这里,
> 不再重复 run / 公证 ID,避免同一主题散落多处。
>
> 环境快照:macOS 27 / Xcode 27(2026-10-24)。

## 1. 总表

| 能力 | 验证方式 | Run | 公证 submission | 结果 |
|---|---|---|---|---|
| ad-hoc `.app` / `.dmg` / `.zip` | `scripts/local-selftest.sh`(22 项) | 本地 | — | ✅ |
| `.app` Developer ID + 公证 | `verify-release.yml` | [40095862502](https://github.com/EasyIndie/EasyApple/actions/runs/40095862502) | `78a6fd71-1b0c-49c4-acf7-68e0e33f29af` | ✅ |
| reusable workflow 全链路 | `verify-reusable.yml` | [40096049639](https://github.com/EasyIndie/EasyApple/actions/runs/40096049639) | `cbfc8bb4-53ff-418e-9af5-6d80cc6c0e01` | ✅ |
| `secrets: inherit` | `verify-reusable.yml` | [40097027827](https://github.com/EasyIndie/EasyApple/actions/runs/40097027827) | `6229b65c-de5c-4667-be8d-30b33f63bf63` | ✅ |
| `.dmg` Developer ID + 公证 | `verify-formats.yml`(dmg job) | [40099541736](https://github.com/EasyIndie/EasyApple/actions/runs/40099541736) | `9c43591c-25ca-4608-8566-3ab84cf43df1` | ✅ |
| `.zip` 输入 + 重打包校验 | `verify-formats.yml`(zip job) | [40099541736](https://github.com/EasyIndie/EasyApple/actions/runs/40099541736) | `06a78317-6150-4ab9-b4e3-d3182425b001` | ✅ |
| `release.yml` dry-run(不建 Release) | `release.yml` + `dry_run=true` | [40099918160](https://github.com/EasyIndie/EasyApple/actions/runs/40099918160) | `12b46464-cd74-434e-848b-d6018fc60aac` | ✅ |
| Apple ID + App 专用密码 | `verify-apple-id.yml` | [40101281656](https://github.com/EasyIndie/EasyApple/actions/runs/40101281656) | `cff3b8b8-02db-438b-ba05-c9446c9f9ad8` | ✅ |
| `.pkg` + Developer ID Installer | `verify-pkg.yml` | [40105139059](https://github.com/EasyIndie/EasyApple/actions/runs/40105139059) | `aa154aa3-e359-41f0-b5c8-240317b87d76` | ✅ |
| 证书到期检查 | `credential-health.yml` | [40107660113](https://github.com/EasyIndie/EasyRelease/actions/runs/40107660113) | — | ✅ |

## 2. 关键细节

### `.app`

- 身份:`Developer ID Application: Zhizhou Wang (2N62934Y28)`
- `codesign`:hardened runtime + secure timestamp
- `stapler validate`:passed
- `spctl`:`accepted` / `source=Notarized Developer ID`

### `.dmg`

- 先签 app(Developer ID Application),再制作 DMG,再签 DMG
- `Notarization Ticket=stapled`
- `spctl -a -t open --context context:primary-signature`:`accepted` / `source=Notarized Developer ID`

### `.zip`

- 输入 zip 内含 `EnvDemo.app`;EasyRelease 解包、签名、公证、staple、重打包
- 重新解压后 `codesign` / `stapler validate` / `spctl -a -t exec` 全部通过
- manifest:`container=zip`、`inner_artifact=EnvDemo.app`、`inner_kind=app`

### `.pkg`

- 先用 Developer ID Application 签 pkg 内的 app,再 `pkgbuild`
- pkg 用 `Developer ID Installer` + `productsign --timestamp` 签名
- `pkgutil --check-signature`:
  - `signed by a developer certificate issued by Apple for distribution`
  - `Notarization: trusted by the Apple notary service`
- `stapler validate`:passed
- `spctl -a -t install`:`accepted` / `source=Notarized Developer ID`

### Apple ID + App 专用密码

- `notary auth: apple-id`
- manifest:`notary_auth=apple-id`、`notarized/stapled/verified=true`
- 使用 EasyApple 的测试专用密码 secret;生产建议仍用 Team API Key

### 证书到期检查

- Run:[40107660113](https://github.com/EasyIndie/EasyRelease/actions/runs/40107660113)
- Developer ID Application:`NotAfter=2031-05-19`
- Developer ID Installer:`NotAfter=2027-02-01`
- 首次运行曾因直接用 `openssl` 解析 Apple p12 失败产生误报 issue,
  已改为 `security import` 并关闭误报。

### `release.yml` dry-run

- `prepare` 与 `sign` 都检出目标 tag(`0.3.0`)
- 产出 `<app>-<tag>.zip` + `<app>-<tag>-manifest.json` + 各自 `.sha256`
- 下载 zip 后用 `ditto -x -k` 解压,签名/票据仍有效
- **未执行**真实 tag 触发的 `gh release create`;dry-run 在发布前停止

## 3. 复现

```bash
# app
gh workflow run verify-release.yml -R EasyIndie/EasyApple

# reusable workflow
gh workflow run verify-reusable.yml -R EasyIndie/EasyApple

# dmg + zip
gh workflow run verify-formats.yml -R EasyIndie/EasyApple

# Apple ID + app 专用密码
gh workflow run verify-apple-id.yml -R EasyIndie/EasyApple

# pkg(需要 Installer secrets)
gh workflow run verify-pkg.yml -R EasyIndie/EasyApple

# 证书到期检查
gh workflow run credential-health.yml -R EasyIndie/EasyRelease
```

## 4. 未覆盖

- 真实 tag 触发的 `gh release create`
- `.pkg` 的 ad-hoc 模式(设计上不支持;`.pkg` 必须用 Installer 证书)
- Android(尚未实现)
