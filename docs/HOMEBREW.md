# Homebrew 安装与维护

SimLaunch 是图形应用，使用 Homebrew Cask 安装已编译的 Release ZIP，不在用户电脑上编译 Swift。现有 GitHub 仓库同时作为自定义 tap，无需另建仓库；显式传入仓库 URL 的方式遵循 [Homebrew Tap 文档](https://docs.brew.sh/Taps)。这不代表已经收录到官方 `homebrew/cask`。

## 首次启用

1. 将包含本次改动的代码提交并推送到 GitHub。
2. 从该提交创建新的 `vX.Y.Z` 标签并推送，触发 Release。
3. 确认 `release` 和 `update-homebrew` 两个任务均成功，默认分支出现 `Casks/simlaunch.rb`。

当前接入不会替已有 Release 补附件。在首个包含 Cask 的版本发布成功、生成文件写回默认分支之前，以下安装命令不可用。

## 用户安装

```sh
brew tap echo-braveshine/simlaunch https://github.com/Echo-BraveShine/SimLaunch.git
brew install --cask echo-braveshine/simlaunch/simlaunch
open /Applications/SimLaunch.app
```

首次 `tap` 后不需要再次添加安装源。使用完整名称可明确选择本项目的 Cask。

升级与卸载：

```sh
brew update
brew upgrade --cask --greedy echo-braveshine/simlaunch/simlaunch
brew uninstall --cask echo-braveshine/simlaunch/simlaunch
```

Cask 声明 `auto_updates true`，因为正式版包含 Sparkle。Homebrew 默认升级会跳过可自行更新的应用，手动通过 Homebrew 升级时加入 `--greedy`。应用内更新与 Homebrew 更新任选其一，不要同时执行。普通卸载保留用户设置和日志，也不删除任何模拟器数据。

已有手动安装的同名应用可能与 Homebrew 安装冲突；先退出应用，妥善保留旧包，再移走 `/Applications/SimLaunch.app` 后安装。Homebrew 不会自动安装 Xcode、Android SDK 或 DevEco Studio。

Homebrew 安装不替代 Apple 签名与公证，未公证应用仍可能被 macOS 拦截。

## 自动维护

Release 工作流按顺序执行：

1. 构建、校验双架构、签名和打包。
2. `scripts/create-cask.py` 读取 ZIP 内的版本和最低系统版本，计算该 ZIP 的 SHA-256，生成 `dist/simlaunch.rb`。
3. 将 Cask 随 ZIP、校验文件和 appcast 一起发布。
4. `update-homebrew` 下载已发布的 Cask，将它提交到默认分支的 `Casks/simlaunch.rb`。

下载地址固定到具体版本，SHA-256 不使用 `:no_check`。后续用户执行 `brew update` 即可取得新版本定义。Cask 字段依据 [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)。

默认使用工作流已有的 `GITHUB_TOKEN` 和 `contents: write` 权限，无需额外 Secret。如果默认分支有保护规则、要求 PR 或仓库策略禁止机器人直接提交，最后的同步任务可能失败；此时 Release 已发布，从该 Release 下载 `simlaunch.rb`，通过普通 PR 更新 `Casks/simlaunch.rb` 即可，不必重新发布或放宽分支规则。

也可以用本地保存的同一份发布 ZIP 重新生成：

```sh
python3 scripts/create-cask.py dist/SimLaunch-X.Y.Z-universal.zip --output Casks/simlaunch.rb
ruby -c Casks/simlaunch.rb
```

如需将首次安装简化为单行、不带仓库 URL 的命令，可另建公开的 `Echo-BraveShine/homebrew-tap` 仓库并维护其 `Casks/simlaunch.rb`，届时命令为 `brew install --cask echo-braveshine/tap/simlaunch`。当前实现直接复用现有仓库。
