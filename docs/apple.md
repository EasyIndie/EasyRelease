# Apple 接入指南

> ad-hoc 链路已在 macOS 27 / Xcode 27 本机验证;Developer ID + 公证链路已于
> 2026-10-24 用组织共享凭据在 EasyApple EnvDemo 验证通过,见文末「验证记录」。

## 1. 三种签名模式

| 模式 | 证书 | 公证 | 用途 |
|---|---|---|---|
| `adhoc` | 不需要 | 不行 | 本机调试、CI 冒烟、验证接线 |
| `developer-id` + `notarize=false` | 需要 | 不行 | 内部分发(仍会被 Gatekeeper 警告) |
| `developer-id` + `notarize=true` | 需要 | 需要 | 对外分发,双击可直接打开 |

## 2. 凭证

证书、API Key、App 专用密码的获取、导出、GitHub 配置、轮换与排错,
统一见 [credentials.md](credentials.md)。本文只讲怎么接入使用。

需要记住的映射:

| 用途 | 证书 / 凭据 |
|---|---|
| 签 `.app` / `.dmg` / `.zip` | Developer ID Application |
| 签 `.pkg` | Developer ID Installer |
| 公证(推荐) | App Store Connect **Team** API Key |
| 公证(备用) | Apple ID + App 专用密码 |

EasyRelease 输入定义见 [contract.md §4](contract.md#4-apple-专属输入)。

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

签名/证书/公证认证相关错误统一见 [credentials.md 第 11 节](credentials.md#11-排错);
`.pkg` 专属问题见 [pkg.md 第 5 节](pkg.md#5-实测与排错)。

## 9. 状态与证据

所有实测 run、公证 ID、复现命令与未覆盖项统一见
[verification.md](verification.md)。

