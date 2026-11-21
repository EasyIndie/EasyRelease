# Android 接入

> 与 [apple.md](apple.md) 对称。契约(输入/输出/manifest)见 [contract.md](contract.md)。
> 版本:`android-v0.1.0` 起支持**校验**;`android-v0.2.0` 起支持 `mode=sign`(事后补签)。

## 1. 它做什么 / 不做什么

| 做 | 不做 |
|---|---|
| 还原签名密钥(base64 → `.jks`,可选写 `keystore.properties`) | 构建 Gradle 工程(由 `build_command` 调方提供) |
| 校验 APK:包名 / 版本 / 非 debuggable / 禁用字符串 / ABI / targetSdk / 签名指纹 | 决定版本号策略、打 tag、改 `version.properties` |
| `mode=sign`:`zipalign` → `apksigner` / `jarsigner` 补签 | 用 Gradle `signingConfigs` 在构建期签名(那是业务仓库的事) |
| 校验 AAB:Bundle 结构 / ABI / `jarsigner` 签名 / upload key 指纹 | 上架到 Play / 国内商店(仍需人工) |
| 生成 `android-manifest.json` + SHA-256 | 保存任何证书或密码 |
| 打包发布资产 + 创建 GitHub Release | 走 fastlane / bundletool 之外的第三方链路 |

**默认只校验不签名**(`mode=verify`):绝大多数 Gradle 工程在**构建期**就用
`signingConfigs` 签好了(CI 在构建前还原密钥)。事后重签会破坏 v2/v3 签名链,
还可能把 Play 的 upload key 换掉。

**什么时候用 `mode=sign`**:构建产物是**未签名**的 —— 自定义构建脚本、
Unity / Flutter 的非标准打包、或项目故意不把密钥放进构建环境。它会
`zipalign`(仅在未对齐时)→ `apksigner sign`(APK,密码走 `env:`)/
`jarsigner`(AAB)。

> ⚠️ AAB 用 `jarsigner` 签,而 JDK 17 的 `jarsigner` **不支持** `-storepass:env`,
> 所以 AAB 补签时密码会出现在命令行上(`ps` 可见)。runner 是一次性独占虚拟机,
> 可接受;多租户机器上不要开 `mode=sign`。

## 2. 方式 A:整条流水线(reusable workflow)

```yaml
jobs:
  release:
    permissions:
      contents: write
    uses: EasyIndie/EasyRelease/.github/workflows/android-release.yml@android-v0.1.0
    with:
      app: OrzMusic
      package_name: com.jokerhub.orzmusic.android
      tag_prefix: android-v            # tag android-v0.7.1 → 版本 0.7.1
      version_file: clients/android/version.properties
      apk: clients/android/app/build/outputs/apk/release/app-release.apk
      aab: clients/android/app/build/outputs/bundle/release/app-release.aab
      build_command: cd clients/android && ./gradlew assembleRelease bundleRelease
      keystore_properties: clients/android/keystore.properties
      alias_property: alias.OrzMusic   # 对应 keystore.properties 里的别名键
      forbidden_strings: UiDumpReceiver # debug 自截图钩子的广播 action
      min_target_sdk: 36
      release: true
      release_tag: ${{ github.ref_name }}
    secrets: inherit
```

要点:

- `build_command` 是**字符串**,在仓库根执行;它负责真正构建(含 `local.properties`)。
- `keystore_properties` 交给 EasyRelease 写(`storeFile` 用相对路径),业务仓库里
  不再出现「拼 properties」的脚本。
- `version_file` 可选:给了就断言「tag 推出的版本 == 文件里的版本」,不给就跳过 ——
  版本策略仍归业务仓库。
- `forbidden_strings` / `require_abis` / `min_target_sdk` 都是**参数**,不写死具体仓库的约定。

### 凭证

4 个 secret,名字与 EasyIndie 组织一致:

| secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `.jks` 的 base64(单行) |
| `ANDROID_STORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_PASSWORD` | key 密码(PKCS12 下通常等于 store 密码) |
| `ANDROID_KEY_ALIAS` | key 别名 |

怎么产出 base64:

```bash
base64 -w0 keystore/release.jks > release.jks.b64   # Linux
base64 -i keystore/release.jks | tr -d '\n'         # macOS
```

> EasyAndroid 的 `tools/gen-keystore.sh --export` 直接产出这种格式的凭据包
> (base64 的 keystore + 明文密码),解出来的 `.jks` 就是这里要的输入。

**没有 `ANDROID_KEYSTORE_BASE64` 时不会报错**,只打一条 warning 并跳过还原 ——
适用于「产物已经签好、只需要校验」的场景。

> ⚠️ **跨 owner 调用时不要用 `secrets: inherit`。** 实测(2026-11-20,
> 调用方 `OrzGeeker/*`、本仓库 `EasyIndie/EasyRelease`)`inherit` 传过去是**空的**,
> 而且不报错 —— 构建拿不到 keystore,静默产出未签名包,失败一路延后到校验步骤。
> 生产请逐项显式映射:
>
> ```yaml
>     secrets:
>       ANDROID_KEYSTORE_BASE64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
>       ANDROID_STORE_PASSWORD: ${{ secrets.ANDROID_STORE_PASSWORD }}
>       ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
>       ANDROID_KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
> ```

## 3. 方式 B:单步 action

```yaml
      - uses: EasyIndie/EasyRelease/android@android-v0.1.0
        with:
          apk: app/build/outputs/apk/release/app-release.apk
          aab: app/build/outputs/bundle/release/app-release.aab
          expected_package: com.example.myapp
          expected_version_name: 1.2.3
          expected_version_code: 10203
          expected_sha256: ${{ vars.RELEASE_CERT_SHA256 }}
          forbidden_strings: UiDumpReceiver
          min_target_sdk: 36
```

输出:`artifact` / `apk` / `aab` / `sha256` / `sha256_aab` / `manifest_path` /
`package` / `version_name` / `version_code` / `certificate_sha256` / `verified`。

## 4. 校验项

| 项 | 依据 | 失败会怎样 |
|---|---|---|
| 包名 | `aapt2 dump badging` | 与 `expected_package` 不符、或 `com.example.*` → 失败 |
| 版本 | 同上 | `versionName` / `versionCode` 与期望不符 → 失败 |
| debuggable | badging 里的 `application-debuggable` | debug 包装成正式包 → 失败 |
| 禁用字符串 | 扫 `*.dex`(AAB 扫 `base/dex/*`) | 命中 `forbidden_strings` → 失败 |
| targetSdk | badging | 低于 `min_target_sdk` → 失败 |
| ABI | badging 的 `native-code` + AAB 的 `base/lib/<abi>/` | 缺 `require_abis` 里的任一 → 失败 |
| APK 签名 | `apksigner verify --print-certs` | 无签名 → 失败;指纹不在 `expected_sha256` 里 → 失败 |
| AAB 结构 | `unzip -Z1` | 缺 `BundleConfig.pb` / manifest / dex → 失败 |
| AAB 签名 | `jarsigner -verify` + `keytool -printcert` | 未签名/校验不过 → 失败;指纹与期望不符 → 失败 |

一次列全所有失败项(不在第一个错误就退出),和人工验收的顺序一致。

### 两个容易踩的点

**APK 与 AAB 是两条签名链。** APK 用 `apksigner`(v2/v3 scheme),AAB 用 `jarsigner`
(Play 只要求 upload key 的 JAR 签名)。不要试图用一套逻辑覆盖两者。

**AAB 不能用 `jarsigner -strict`。** upload key 是自签证书,`-strict` 会把
「证书链不受信任」算成 `signer error`(退出码 4),输出却是
`jar verified, with signer errors.`。所以这里用 `jarsigner -verify` + 断言
`jar verified`,再用 `keytool -printcert` 单独比对指纹 —— 那才是商店真正关心的东西。

## 5. 本地自测(不需要发布证书)

```bash
ANDROID_HOME=/opt/android-sdk bash scripts/local-selftest-android.sh
```

用 `keytool` 现生成临时 keystore,用 `aapt2` 现造 fixture APK / AAB,
覆盖正例、禁词命中、指纹不符、debuggable、缺 ABI、版本不符、dry-run、
密钥还原与各条失败路径。2026-11-20 在本机(WSL2 / build-tools 36.0.0 / JDK 17)
**21 项全通过**。

## 6. 输入对照(与 Apple 侧)

| Apple | Android | 说明 |
|---|---|---|
| `artifact` | `apk` / `aab` | Android 常两个都发,所以是两个参数 |
| `mode: adhoc/developer-id` | `mode: verify/sign` | `verify` 用于「构建期已签名」,`sign` 用于未签名产物 |
| `p12_base64` / `p12_password` | `ANDROID_KEYSTORE_BASE64` / `ANDROID_STORE_PASSWORD` / `ANDROID_KEY_PASSWORD` / `ANDROID_KEY_ALIAS` | 密钥还原 |
| `identity` / `team_id` | `expected_sha256` | 用证书指纹锁死「是不是同一把密钥」 |
| `entitlements` | `forbidden_strings` / `require_abis` / `min_target_sdk` | 都是产物级断言 |
| `bundle_id` / `version` / `build_number` | `expected_package` / `expected_version_name` / `expected_version_code` | |
| `notarize` / `notary_auth` | — | Android 没有对偶概念 |

## 7. 排错

| 症状 | 原因 / 处理 |
|---|---|
| `找不到 Android SDK` | runner 上设 `ANDROID_HOME`,或传 `build_tools` |
| `缺少 apksigner` | runner 没装 build-tools;`build_tools` 显式指向一份 |
| `AAB 未通过 jarsigner 校验` | AAB 没签;Play 要求 upload key 签名(`bundleRelease` 里配 `signingConfig`) |
| `签名指纹 … 不在期望列表里` | 换了密钥,或 secrets 指到了另一把 keystore |
| `keystore 打不开或别名 … 不存在` | base64 截断、`ANDROID_KEY_ALIAS` 写错,或 PKCS12 的 key 密码与 store 密码不一致 |
| `versionName 不符` | tag 与产物版本对不上;用 `version_file` 提前拦住更省事 |
| `mode=sign 需要 keystore_base64` | 没传密钥;`sign` 模式必须有 4 个凭据输入 |
| `apksigner sign 失败` | keystore 密码/别名不对,或 PKCS12 的 key 密码与 store 密码不一致 |
| run 直接 `startup_failure`(只有「workflow file issue」) | 调用方 job 的 `permissions` 比被调 workflow 声明的窄。它声明 `contents: write`,调用方必须给 write(只允许降权) |
| 四个密钥在日志里都是空、构建产物是 `app-release-unsigned.apk` | `secrets: inherit` 跨 owner 没生效;改成逐项显式映射 |
