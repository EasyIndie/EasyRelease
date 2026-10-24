# Apple 接入指南

> ad-hoc 链路已在 macOS 27 / Xcode 27 本机验证;Developer ID + 公证链路已于
> 2026-10-24 用组织共享凭据在 EasyApple EnvDemo 验证通过,见文末「验证记录」。

## 1. 三种签名模式

| 模式 | 证书 | 公证 | 用途 |
|---|---|---|---|
| `adhoc` | 不需要 | 不行 | 本机调试、CI 冒烟、验证接线 |
| `developer-id` + `notarize=false` | 需要 | 不行 | 内部分发(仍会被 Gatekeeper 警告) |
| `developer-id` + `notarize=true` | 需要 | 需要 | 对外分发,双击可直接打开 |

## 2. 凭证准备

| Secret | 内容 | 获取方式 |
|---|---|---|
EasyIndie 组织已有共享凭据,reusable workflow 的 secret 名与它们完全一致,直接 `secrets: inherit`:

| 组织 secret / variable | 用途 |
|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | Developer ID Application 证书 `.p12` 的 base64 |
| `APPLE_CERTIFICATE_P12_PASSWORD` | `.p12` 密码 |
| `APPLE_ASC_API_KEY_ID` | App Store Connect API Key ID |
| `APPLE_ASC_ISSUER_ID` | Issuer ID |
| `APPLE_ASC_API_KEY` | API 私钥(PEM 或 base64) |
| `vars.MACOS_SIGNING_IDENTITY` | 完整签名身份 |

直接调用 composite action 时,再映射到 action 输入:

| action 输入 | 组织 secret / variable |
|---|---|
| `p12_base64` | `APPLE_CERTIFICATE_P12_BASE64` |
| `p12_password` | `APPLE_CERTIFICATE_P12_PASSWORD` |
| `asc_key_id` | `APPLE_ASC_API_KEY_ID` |
| `asc_issuer_id` | `APPLE_ASC_ISSUER_ID` |
| `asc_key_p8` | `APPLE_ASC_API_KEY` |
| `identity` | `vars.MACOS_SIGNING_IDENTITY` |

`identity` 可写完整名称(如 `Developer ID Application: Name (TEAMID)`)或 SHA-1;留空时按 `team_id` 匹配。

### 公证认证方式

| 方式 | 输入 | 状态 |
|---|---|---|
| App Store Connect API Key | `notary_auth: api-key`(auto 下优先) | ✅ 实测 |
| Apple ID + App 专用密码 | `notary_auth: apple-id` + `apple_id` / `apple_password` / `team_id` | ✅ 实测 |

Apple ID 示例:

```yaml
- uses: EasyIndie/EasyRelease/apple@apple-v0.6.1
  with:
    artifact: MyApp.app
    mode: developer-id
    notarize: "true"
    identity: ${{ vars.MACOS_SIGNING_IDENTITY }}
    notary_auth: apple-id
    apple_id: ${{ secrets.APPLE_ID }}
    apple_password: ${{ secrets.APPLE_APP_SPECIFIC_PASSWORD }}
    team_id: ${{ secrets.APPLE_TEAM_ID }}
    p12_base64: ${{ secrets.APPLE_CERTIFICATE_P12_BASE64 }}
    p12_password: ${{ secrets.APPLE_CERTIFICATE_P12_PASSWORD }}
```

`apple_password` 必须是 **App 专用密码**,不是 Apple ID 登录密码。

建议放在 **organization secrets**,按仓库授予可见性;不要每个项目复制一份。

## 3. 接入方式 A:完整流水线

```yaml
name: release
on:
  push:
    tags: ["[0-9]*.[0-9]*.[0-9]*"]

permissions:
  contents: write

jobs:
  release:
    uses: EasyIndie/EasyRelease/.github/workflows/apple-release.yml@apple-v0.4.0
    with:
      app: MyApp
      bundle_id: com.easyindie.myapp
      build_command: bash tools/bundle.sh --platform macOS
      mode: developer-id
      notarize: true
      identity: ${{ vars.MACOS_SIGNING_IDENTITY }}
      release: true
      release_tag: ${{ github.ref_name }}
    secrets: inherit
```

默认产物路径是 `apps/<app>/.build/bundle/<app>.app`;不是这个布局就显式传 `artifact`。

> reusable workflow 的 secret 名已与 EasyIndie 组织完全一致,直接 `secrets: inherit`。
> 只有直接调用 composite action 时,才需要在 `with:` 里显式映射(见上表)。

## 4. 接入方式 B:只要签名/公证

```yaml
jobs:
  sign:
    runs-on: xcode-27
    steps:
      - uses: actions/checkout@v4
      - run: bash tools/bundle.sh
      - uses: EasyIndie/EasyRelease/apple@apple-v0.4.0
        id: sign
        with:
          artifact: .build/bundle/MyApp.app
          mode: developer-id
          notarize: "true"
          entitlements: MyApp.entitlements
          identity: ${{ vars.MACOS_SIGNING_IDENTITY }}
          p12_base64: ${{ secrets.APPLE_CERTIFICATE_P12_BASE64 }}
          p12_password: ${{ secrets.APPLE_CERTIFICATE_P12_PASSWORD }}
          asc_key_id: ${{ secrets.APPLE_ASC_API_KEY_ID }}
          asc_issuer_id: ${{ secrets.APPLE_ASC_ISSUER_ID }}
          asc_key_p8: ${{ secrets.APPLE_ASC_API_KEY }}
      - run: echo "ticket=${{ steps.sign.outputs.notarization_id }}"
```

## 5. .zip 输入

`.zip` 必须恰好包含一个 `.app` / `.dmg` / `.pkg`(可以嵌套在子目录):

```yaml
- uses: EasyIndie/EasyRelease/apple@apple-v0.6.1
  with:
    artifact: dist/MyApp.zip
    mode: developer-id
    notarize: "true"
    # 其余签名/公证参数同上
```

输出是 `dist/MyApp-signed.zip`;manifest 里 `artifact_kind=zip`、`container=zip`、
`inner_artifact` 指向 zip 内产物。重新打包后会再解压校验一次,确认签名/staple 未被破坏。

## 6. 本地复现

```bash
# ad-hoc
EASYRELEASE_ARTIFACT=/tmp/Hello.app \
EASYRELEASE_MODE=adhoc \
GITHUB_WORKSPACE=/tmp \
RUNNER_TEMP=/tmp \
bash apple/scripts/main.sh
```

`manifest.json` 默认写到 `$GITHUB_WORKSPACE/easyrelease/`。

## 7. 顺序(不要颠倒)

1. 签嵌套代码(dylib / framework / xpc / appex / 内嵌 app)
2. 签主 app(`--options runtime --timestamp`)
3. 打 zip 提交公证(`.app` 必须先 zip;`.dmg` / `.pkg` 直接提交)
4. 公证通过
5. **staple 到产物本身**
6. 再打最终分发包(zip / dmg)

先打包再 staple 是最常见的错误:票据没进 bundle,离线机器仍会被拦。

## 8. 排错

| 症状 | 原因 | 处理 |
|---|---|---|
| `errSecInternalComponent` | keychain 未解锁 / 未加入搜索列表 | 检查 `security set-key-partition-list` 与 `list-keychains -s` |
| `no identity found` | 证书不在 keychain / Team ID 不匹配 | 打印 `security find-identity -v -p codesigning` |
| `code object is not signed at all` | 嵌套代码没先签 | 确认 frameworks / dylib 在 app 之前签 |
| 公证 `Invalid` | 未开 hardened runtime / entitlements 不符 / 签名不完整 | `notarytool log <id>` 看具体 issue |
| `stapler: no ticket` | 公证还没通过或 staple 错了对象 | 先确认 `status=Accepted` |
| `spctl` 报 `source=no usable signature` | ad-hoc 模式 | 预期行为,ad-hoc 不参与 Gatekeeper |
| 公证超时 | Apple 队列慢 | 调大 `timeout`,job `timeout-minutes` 也要大于它 |

## 9. 状态

| 链路 | 状态 | 验证方式 |
|---|---|---|
| ad-hoc `.app` | ✅ 已验证(2026-10-24) | 本机 macOS 27 / Xcode 27 + `scripts/local-selftest.sh` |
| ad-hoc `.dmg` | ✅ 已验证(2026-10-24) | 同上 |
| ad-hoc `.zip`(内含 `.app` / `.dmg`) | ✅ 已验证(2026-10-24) | `scripts/local-selftest.sh`(22 项) |
| dry-run(无证书) | ✅ 已验证(2026-10-24) | 同上 + CI selftest |
| 证书导入 / 临时 keychain 清理 | ✅ 已验证(2026-10-24) | 自签名 p12 导入后按预期报「未找到 Developer ID」,无残留 |
| Developer ID 签名 | ✅ 已验证(2026-10-24) | EasyApple EnvDemo,组织共享证书 |
| 公证 + staple(`.app`) | ✅ 已验证(2026-10-24) | submission `78a6fd71-1b0c-49c4-acf7-68e0e33f29af`,`stapler validate` 通过 |
| `.dmg` Developer ID + 公证 | ✅ 已验证(2026-10-24) | run `40099541736`,submission `9c43591c-...`,`spctl -t open` 通过 |
| `.zip` 输入 + 公证 | ✅ 已验证(2026-10-24) | run `40099541736`,submission `06a78317-...`,重打包后再次校验通过 |
| App 专用密码公证 | ✅ 已验证(2026-10-24) | run `40101281656`,submission `cff3b8b8-...` |
| `.pkg` | ✅ 已验证(2026-10-24) | run `40105139059`,submission `aa154aa3-...`;Installer 身份 |

`.pkg` 与 Android 链路补齐后,按同样格式追加记录。

## 10. 验证记录

2026-10-24,EasyApple `EnvDemo`(`com.easyapple.envdemo`,版本 `0.3.0` / build `300`):

- Run:<https://github.com/EasyIndie/EasyApple/actions/runs/40095862502>
- identity:`Developer ID Application: Zhizhou Wang (2N62934Y28)`
- notarization:`78a6fd71-1b0c-49c4-acf7-68e0e33f29af`(`status=Accepted`)
- `stapler validate`:The validate action worked
- `spctl`:`accepted`,`source=Notarized Developer ID`
- manifest:`signed=true` / `notarized=true` / `stapled=true` / `gatekeeper=accepted` / `verified=true`
- 产物:`app bundle with Mach-O thin (arm64)`,signature flags `runtime`,`Notarization Ticket=stapled`

reusable workflow 全链路(构建 → 签名 → 公证 → 上传)也验证通过:

- Run:<https://github.com/EasyIndie/EasyApple/actions/runs/40096049639>
- notarization:`cbfc8bb4-53ff-418e-9af5-6d80cc6c0e01`(`status=Accepted`)
- `spctl`:`accepted` / `source=Notarized Developer ID`
- `contents: write` + `upload_artifact: true`,`release: false`

`secrets: inherit` 版本(secret 名对齐组织后):

- Run:<https://github.com/EasyIndie/EasyApple/actions/runs/40097027827>
- notarization:`6229b65c-de5c-4667-be8d-30b33f63bf63`(`status=Accepted`)
- `spctl`:`accepted` / `source=Notarized Developer ID`

EasyApple 正式 `release.yml` dry-run(构建 → 公证 → zip + sha256,不建 Release):

- Run:<https://github.com/EasyIndie/EasyApple/actions/runs/40099918160>(tag `0.3.0`)
- notarization:`12b46464-cd74-434e-848b-d6018fc60aac`(`status=Accepted`)
- `sign` job 日志确认检出 `refs/tags/0.3.0`,与 `prepare` 的 tag 一致
- 下载 zip 后用 `ditto -x -k` 解压,重新校验:`codesign` 通过、`Notarization Ticket=stapled`、
  `stapler validate` 通过、`spctl` `accepted` / `source=Notarized Developer ID`
- `.sha256` 校验通过(含 `*-manifest.json` 与 zip)
- 发布步骤按产物类型处理:`.app` → zip、`.zip` → 直传、`.dmg`/`.pkg` → 原生

更早的 dry-run:`40098486383`(notarization `8271d395-...`)、`40098005804`(`dc014cc6-...`)也通过。

DMG / ZIP 真链路(run `40099541736`,tag 前 `main`):

- `.dmg`:notarization `9c43591c-25ca-4608-8566-3ab84cf43df1`(`Accepted`);
  `stapler validate` 通过;`spctl -a -t open --context context:primary-signature` →
  `accepted` / `source=Notarized Developer ID`;`codesign` 显示 `Notarization Ticket=stapled`
- `.zip`(内含 `.app`):notarization `06a78317-6150-4ab9-b4e3-d3182425b001`(`Accepted`);
  重新打包后 `ditto -x -k` 解压,`codesign` / `stapler validate` / `spctl -a -t exec` 全部通过
- manifest:`container=zip`、`inner_artifact=EnvDemo.app`、`inner_kind=app`,
  `notarized/stapled/verified=true`

Apple ID + App 专用密码(run `40101281656`):

- `notary auth: apple-id`
- notarization:`cff3b8b8-02db-438b-ba05-c9446c9f9ad8`(`Accepted`)
- `spctl`:`accepted` / `source=Notarized Developer ID`
- manifest:`notary_auth=apple-id`、`notarized/stapled/verified=true`
