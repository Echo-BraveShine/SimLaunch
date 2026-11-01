# 发布与应用内更新

SimLaunch 的正式发布链路使用 GitHub Actions、GitHub Releases 和 Sparkle 2.10.1：

```text
推送 vX.Y.Z 标签 → 测试 → arm64 + x86_64 通用应用
→ 可选 Developer ID 签名和公证 → ZIP
→ Sparkle Ed25519 签名、校验公钥匹配 → appcast.xml
→ GitHub Release → 用户在设置中检查、确认下载并安装
```

应用内更新只在包含 Sparkle、公钥和 HTTPS 更新源的正式构建中启用。开发构建默认不下载 Sparkle 依赖，可打开 GitHub Releases 手动下载。首次使用更新功能需要先安装一个正式构建；现有不含 Sparkle 的开发版不会自行变成可自动更新版本。

本机已验证默认开发模式的 Swift 测试、打包，以及发布脚本的版本、元数据和 appcast 测试。Sparkle 2.10.1 依赖现已下载，启用 Sparkle 的 Debug 可执行文件已编译通过；尚未执行正式通用包发布、远程 Actions 或跨版本安装。第一次发布必须检查 Actions 结果，并用旧、新两个正式应用包验证更新闭环。

当前应用 Bundle ID 为 `dev.ekko.simlaunch`。该 ID 与 Sparkle 钥匙串账户名 `dev.simlaunch.updates` 相互独立；已有密钥仍存放在该账户下，不要因为更换 Bundle ID 重新生成密钥。GitHub 上的公钥和私钥应继续使用原来的一对。

更换 Bundle ID 后，旧安装的系统登录项可能需要移除并重新开启；应用会迁移旧标识下的路径、语言和常用设备记录，但不会自动迁移系统授权。此变更不适合作为旧 Bundle ID 应用的直接 Sparkle 升级；当前应以新 ID 发布首个正式版。

## 1. 准备仓库

代码需要先成功推送到 `Echo-BraveShine/SimLaunch`。工作流位于 `.github/workflows/ci.yml` 与 `release.yml`。仓库需允许 Actions 运行及 `GITHUB_TOKEN` 写入 Releases（工作流请求 contents: write）。

当前更新源和下载链接假定仓库公开，用户不需要 GitHub 登录。私有仓库需要额外实现受认证的更新分发，不应把 GitHub Token 内嵌到应用。

## 2. 一次性设置 Sparkle 密钥

Sparkle 的更新签名密钥与 Apple Developer ID 证书不是同一种凭据。更新签名密钥不可提交到 Git，也不要把私钥发到聊天中。

在可以连接 GitHub 的开发机上：

```sh
SIMLAUNCH_ENABLE_SPARKLE=1 swift package resolve
find .build/artifacts -type f -name generate_keys
```

找到 Sparkle 发行包内的 `bin/generate_keys`，使用 SimLaunch 专用账户：

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.simlaunch.updates
```

密钥保存在本机钥匙串，重复执行会读取既有密钥而不是覆盖。读取公钥使用 `--account dev.simlaunch.updates -p`；为 CI 导出私钥时使用 `--account dev.simlaunch.updates -x /安全目录/private-key.txt`，并妥善备份。不要省略账户参数，否则工具会使用默认的另一条钥匙串记录。

在 GitHub 仓库 Settings → Secrets and variables → Actions 中设置：

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Repository variable | `SPARKLE_PUBLIC_ED_KEY` | generate_keys 输出的 Base64 公钥，解码为 32 字节 |
| Repository secret | `SPARKLE_PRIVATE_KEY` | 导出的 Base64 私钥文件内容，保留原值 |

每次发布都使用同一对密钥。脚本签署归档后会使用应用内公钥验证签名，私钥不匹配时停止发布。不要随意更换公钥，否则旧版本可能无法验证新版本；需要换钥时按 Sparkle 的密钥轮换文档操作。

`SUFeedURL` 固定为：

```text
https://github.com/Echo-BraveShine/SimLaunch/releases/latest/download/appcast.xml
```

每个 Release 均包含 appcast.xml，发布成功后 latest 链接自动指向最新正式版，无需修改 main 分支中的 XML。

## 3. 可选：Apple Developer ID 签名与公证

未配置 Apple 证书时，工作流使用 ad hoc 签名，仍要求 Sparkle 更新归档签名。但 ad hoc 签名不代表 Apple 认可的开发者身份，也不能代替公证；用户首次安装可能被 Gatekeeper 拦截。面向普通用户分发建议配置 Developer ID。

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Repository variable | `CODESIGN_IDENTITY` | Developer ID Application 证书的完整身份名称 |
| Repository secret | `APPLE_CERTIFICATE_P12` | 含私钥的 Developer ID Application .p12 文件经 Base64 编码的内容 |
| Repository secret | `APPLE_CERTIFICATE_PASSWORD` | .p12 导出密码 |
| Repository secret | `APPLE_NOTARY_KEY_P8` | Apple 公证 API 私钥 .p8 的文件内容 |
| Repository secret | `APPLE_NOTARY_KEY_ID` | 对应 Key ID |
| Repository secret | `APPLE_NOTARY_ISSUER_ID` | 对应 Issuer ID |

配置 Apple 证书后，工作流要求同时提供公证凭据，否则失败，不会悄悄发布未公证版本。脚本先对 Sparkle 内部代码与辅助应用从内到外签名，再签主应用；公证通过并装订 ticket 后才创建最终 ZIP 和更新签名。临时钥匙串和凭据文件在 CI 结束时清理。

## 4. 发布一个正式版本

先将根目录 `Info.plist` 的 `CFBundleShortVersionString` 改为本次版本（例如 `0.1.1`），确保代码与工作流已提交、推送。之后创建与之匹配的标签，例如：

```sh
git tag -a v0.1.1 -m "SimLaunch 0.1.1"
git push origin v0.1.1
```

仅支持 `v主版本.次版本.修订版本` 稳定版标签，当前不支持 beta / rc 通道。也可从 Actions 手动运行 Release 工作流，但必须选择一个符合规则的版本标签，不能选择 main。

工作流使用 `macos-26` runner 上的 Xcode，需包含 macOS 26+ SDK。版本号唯一来源是根目录 `Info.plist` 的 `CFBundleShortVersionString`；`APP_VERSION` 读取该值后用于归档命名，标签不一致时立即停止。设置 `APP_VERSION` 环境变量不能覆盖源文件中的版本，值不一致时打包会报错。`APP_BUILD` 为 Release 工作流的 `GITHUB_RUN_NUMBER + 1`，用于 Sparkle 比较新旧版本；本地未设置时使用源文件的 `CFBundleVersion`。保持同一发布工作流且确保构建号递增。不要重新打包并覆盖已发布的同一版本，修复应修改源文件版本并使用新标签。

Release 包含：

- `SimLaunch-X.Y.Z-universal.zip`：仅包含 SimLaunch.app，含 arm64 和 x86_64。
- `appcast.xml`：该版本的更新源、最低系统版本、下载地址、长度与 Ed25519 签名。
- `SHA256SUMS.txt`：下载归档的 SHA-256，供人工校验。
- `simlaunch.rb`：该归档的 Homebrew Cask，包含精确版本和 SHA-256。发布后 `update-homebrew` 任务将其提交到默认分支，详见 [Homebrew 说明](HOMEBREW.md)。

先创建草稿、上传附件，再发布并标记 latest，避免用户读到尚未上传归档的更新源。如果发布失败留下草稿，修复后应先人工检查该草稿和失败步骤，不要覆盖已经公开的归档。

## 5. 应用端行为

设置 → 通用 → 软件更新显示当前版本和构建号。正式构建中的“检查更新…”由 Sparkle 处理，负责版本比较、下载、更新签名验证、安装和重新启动。自动检查已启用，自动安装默认关闭，安装通过 Sparkle 界面由用户确认。更新检查周期、跳过版本等行为遵循 Sparkle 默认机制。

开发模式不启用 Sparkle，检查按钮禁用，保留“查看发布版本”入口；首次 Release 之前页面可能没有下载内容。安装应用后应放在稳定可写的位置（通常为 /Applications），不要从 ZIP 预览或只读镜像中长期运行。

## 6. 本地验证

```sh
swift test
python3 -m unittest discover -s scripts/tests -v
./scripts/build-app.sh
```

验证带 Sparkle 的正式包（需要网络和真实公钥）：

```sh
export SIMLAUNCH_ENABLE_SPARKLE=1
export SPARKLE_PUBLIC_ED_KEY='你的公钥'
export APP_BUILD=2
export APP_ARCHITECTURES=universal
./scripts/build-app.sh
lipo dist/SimLaunch.app/Contents/MacOS/SimLaunch -archs
lipo dist/SimLaunch.app/Contents/MacOS/SimLaunch -verify_arch arm64
lipo dist/SimLaunch.app/Contents/MacOS/SimLaunch -verify_arch x86_64
```

应用文件路径放在 `-verify_arch` 之前，并分别校验两个架构，以兼容不同版本的 Xcode 工具。发布流程修复后，需提交并推送修改，再从包含修复的新版本标签发布；直接重跑旧标签的任务仍会使用旧代码。

以上只构建应用，不发布。要验证完整升级，保留较旧构建号的正式包，发布较高构建号的版本后，从旧包执行检查更新；检查更新签名、版本号、用户确认、安装位置、重启、配置和登录项状态。请用测试应用副本操作。

## 参考

- [Sparkle 官方配置与分发文档](https://sparkle-project.org/documentation/)
- [Sparkle SwiftUI 接入说明](https://sparkle-project.org/documentation/programmatic-setup/)
- [GitHub runner 支持范围](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
