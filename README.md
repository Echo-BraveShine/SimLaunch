# SimLaunch

SimLaunch 是使用 SwiftUI 编写的 macOS 模拟器管理工具，提供锚定状态栏的设备面板，用于查询、启动和停止 iOS、Android、HarmonyOS 模拟器。

当前应用 Bundle ID 为 `dev.ekko.simlaunch`。

应用信息统一维护在根目录 `Info.plist`：`CFBundleShortVersionString` 是版本号，`CFBundleVersion` 是本地默认构建号。打包时复制该文件；正式发布要求 Git 标签 `vX.Y.Z` 与其中的版本号一致，CI 单独生成递增构建号。设置页面、Sparkle 和 Homebrew 均读取最终应用包的版本信息。直接通过 Swift Package / Xcode 运行未打包的可执行文件时，设置页面仍显示开发模式标识。

项目通过 Swift Package 管理，默认开发模式没有第三方 Swift 包依赖；正式更新版通过 `SIMLAUNCH_ENABLE_SPARKLE=1` 启用固定版本的 Sparkle 2.10.1。各平台功能仍依赖本机安装的 Xcode、Android SDK 或 DevEco Studio；SimLaunch 不负责创建模拟器、下载 SDK、安装系统镜像或接受开发工具许可。

## 环境要求

| 用途 | 要求 |
| --- | --- |
| 运行应用 | 部署目标为 macOS 13+；尚未在全部支持版本上完成实机验证 |
| 编译源码 | 使用包含 macOS 26 或更新 SDK 的 Xcode，以编译 Liquid Glass 接口；当前本机验证环境为 Xcode 27.1、Swift 6.4、Apple Silicon |
| iOS 管理 | 完整 Xcode、可用的 simctl，以及与设备运行时兼容的 Simulator.app 或 DeviceHub.app |
| Android 管理 | Android SDK 中的 emulator、adb；删除 AVD 还需要 avdmanager 及其可用的 Java 运行环境 |
| HarmonyOS 管理 | DevEco Studio 的 Emulator CLI；当前解析基于本机 DevEco Studio 26 的实际 JSON 输出 |

`Package.swift` 中的 `swift-tools-version: 5.9` 是包清单的工具版本声明，不代表使用旧版 Xcode / SDK 即可编译当前源码。

## Homebrew 安装

已接入自定义 Homebrew Cask 分发。需先将本次改动推送并成功发布一个新版本，确认工作流已在默认分支生成 `Casks/simlaunch.rb`，之后可执行：

```sh
brew tap echo-braveshine/simlaunch https://github.com/Echo-BraveShine/SimLaunch.git
brew install --cask echo-braveshine/simlaunch/simlaunch
```

这会安装 Release 应用包，SDK 仍需单独准备。升级、卸载及自动维护说明见 [Homebrew 说明](docs/HOMEBREW.md)。

中英文官网源码位于 `website/`，支持跟随系统、浅色、深色外观，应用截图随语言和外观同步切换，包含 GitHub Pages 自动部署配置。本地预览、启用 Pages 和维护方式见 [官网说明](docs/WEBSITE.md)。

### 首次打开：允许 macOS 安全提示

当前发布版尚未使用 Apple Developer ID 证书签名，也未通过 Apple 公证。无论通过 Homebrew 安装还是从 GitHub Releases 下载，首次打开时都可能被 macOS 拦截，提示无法验证开发者或 Apple 无法检查该应用。

确认应用来自本项目的 GitHub Release 后，按以下步骤允许打开：

1. 在“应用程序”中打开一次 `SimLaunch.app`，使系统显示拦截提示。
2. 打开 **系统设置 → 隐私与安全性**，向下滚动至“安全性”区域。
3. 找到 SimLaunch 的拦截记录，点击 **仍要打开**（Open Anyway）。
4. 按系统提示完成身份验证，并在确认弹窗中点击 **打开**。

菜单和按钮文字可能随 macOS 版本略有不同。具体步骤见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

## 构建与运行

在项目根目录执行：

```sh
# 编译 Debug 可执行文件
swift build

# 执行测试，默认不启动或删除真实设备
swift test

# 生成本机架构的 Release 应用包，包含图标和本地化资源
./scripts/build-app.sh

open dist/SimLaunch.app
```

打包脚本使用 macOS 自带的 sips、iconutil、ditto 和 codesign，生成临时签名（ad hoc）的 `dist/SimLaunch.app`，并尝试刷新该路径的系统应用注册。本地默认生成本机架构二进制；设置 `APP_ARCHITECTURES=universal` 可生成 arm64 / x86_64 通用包。正式发布工作流支持更新归档签名，以及可选的 Developer ID 签名和 Apple 公证，详见 [发布说明](docs/RELEASING.md)。

应用包设置了 `LSUIElement`，作为仅状态栏应用运行，不在 Dock 或应用切换器中显示；直接运行源码也使用相同策略。打开应用直接显示锚定状态栏图标的设备面板，不再创建独立设备主窗口。点击状态栏图标可展开或关闭面板；重复打开应用会复用该面板。齿轮按钮打开独立设置窗口，关闭设置不会退出应用。

### 使用 Xcode 调试

1. 在 Xcode 中打开 `Package.swift`。
2. 选择 SimLaunch scheme 和 My Mac 运行目标。
3. 先退出正在运行的另一份 SimLaunch，再按 ⌘R 编译、运行；添加断点后可调试应用自身代码，⌘U 执行测试。

也可用 `swift run SimLaunch` 运行。Swift Package 直接运行的产物是可执行文件，并不等同于打包脚本生成的 `.app`；当前登录项开关要求运行于应用包中。

## 设备列表与操作

- 按 iOS、Android、HarmonyOS 分组；各分类支持展开与收起，并分别保存状态，重启和切换语言后仍保留。没有可显示设备的平台不展示分类，不可用设备放入单独的可折叠“不可用”分类。所有平台均无设备且查询成功时，统一显示一条空列表提示；查询失败时保留错误提示。
- “常用”位于列表顶部，记录通过 SimLaunch 成功启动到目标状态或成功执行 iOS“显示”的设备，最近一次排在最前，最多显示 5 台当前可用的设备。记录保存在本机；没有可显示记录时隐藏，已删除或当前不可用的设备不显示。它不追踪其他开发工具中的使用行为，平台分组仍保留完整列表。
- 启动、停止和删除前重新查询设备状态；同一设备操作期间禁用重复操作。不同工具同时修改设备状态时仍可能出现竞争，错误会提示重试。
- 完成一轮查询后等待约 5 秒再自动刷新，也可手动刷新。自动查询不显示加载动画；用户点击刷新后，刷新按钮原位显示加载动画，完成后恢复图标。若自动查询正在进行，手动刷新会复用该轮查询并显示其进度。三个平台依次查询，因此实际刷新间隔包含查询耗时；某平台失败会保留它原有条目并标记状态未知，随后继续查询其他平台。
- 查询错误显示在列表中，操作错误使用弹窗。Android / HarmonyOS 启动器输出写入 `~/Library/Logs/SimLaunch/`；该目录不是所有操作的统一日志。

### 右键菜单

| 操作 | 适用平台 | 条件与行为 |
| --- | --- | --- |
| 复制设备名称 | 全部 | 复制设备原名 |
| 复制设备 UDID | iOS | 复制 simctl 返回的 UDID |
| 在访达中显示 | 全部 | 定位设备数据目录；无法解析路径时禁用，目录不存在时提示错误 |
| 冷启动 | Android、HarmonyOS | 仅已停止设备可用；Android 使用 `-no-snapshot-load`，HarmonyOS 使用 `-bootMode coldboot`，不请求清空用户数据 |
| 删除当前设备 | 全部 | 仅已停止设备可用，iOS 不可用设备也允许删除；需确认，并再次查询状态后执行 |

删除调用平台工具：iOS 使用 `simctl delete UDID`，Android 使用 `avdmanager delete avd -n NAME`，HarmonyOS 使用 `Emulator -delete NAME -force`。这会删除所选虚拟设备及其数据，无法通过 SimLaunch 撤销；不会请求卸载共享系统镜像。当前项目未通过删除现有用户设备进行端到端验证。

“在访达中显示”的路径来源：iOS 优先使用 simctl 的 dataPath，缺失时回退到用户默认 CoreSimulator 设备目录；Android 读取 AVD 的 `.ini` 配置；HarmonyOS 使用 instancePath。自定义设备集合、缺失配置或缺失目录可能导致该功能不可用。

## 设置

左侧仅保留“通用”和三个平台的导航。平台路径修改需点击“保存并刷新”；“恢复自动查找”清空当前平台的手动配置，也需要保存；已经全部留空时，该按钮不可用。“自动查找”标签仅表示该字段留空后的查找模式，不代表工具已安装或检测成功。保存前会检查手动路径是否指向所需的可执行文件、模拟器应用或目录；无效路径会在设置页提示，不会覆盖已保存的配置。此检查不验证外部工具版本、许可状态或实际启动能力，设备查询错误仍显示在主面板中。

### 通用

- **外观**：跟随系统、浅色、深色，默认跟随系统。切换后立即应用到设备面板和设置页，并保存供下次启动使用；不修改 macOS 的全局外观设置。
- **语言**：简体中文、English、跟随系统，立即生效并保存。界面、设备状态及应用定义的错误提示提供中英文；设备原名、外部 CLI 输出和系统生成的诊断保留原文。系统原生界面可能遵循系统语言。
- **登录时启动**：使用 `SMAppService.mainApp` 注册或取消登录项，立即生效，不依赖路径保存按钮。开关读取系统状态；需要批准时显示提示和系统设置入口。建议先将应用放在固定位置（如 `/Applications`）再启用。该功能已接入系统接口，但尚未通过注销或重启完成自动启动验证。

- **官方网站**：点击官网卡片，在默认浏览器中打开 [SimLaunch 官网](https://echo-braveshine.github.io/SimLaunch/)。

### 平台路径

| 配置 | 自动发现顺序 / 手动填写 |
| --- | --- |
| Xcode 开发者目录 | 默认使用 xcrun 当前选择的工具链；手动填写如 `/Applications/Xcode-beta.app/Contents/Developer`，通过子进程 DEVELOPER_DIR 生效 |
| 模拟器应用 | 检查所选 Xcode 的 Developer/Applications 和 Contents/Applications 中的 Simulator.app、DeviceHub.app，并使用 Spotlight 补充候选；可手动指定 `.app` 路径 |
| Android Emulator | ANDROID_HOME、ANDROID_SDK_ROOT、`~/Library/Android/sdk`、继承的 PATH；手动填写 emulator 可执行文件路径 |
| Android ADB | 优先尝试所选 emulator 同一 SDK 下的 platform-tools/adb，再检查 SDK 环境变量、默认目录、继承的 PATH；可手动指定 |
| Android 虚拟设备目录 | 留空时由 Android 工具及其环境变量决定；手动填写会为子进程设置 ANDROID_AVD_HOME |
| HarmonyOS Emulator | 系统和用户 Applications 下的 DevEco-Studio.app、Spotlight 中的 DevEco 应用、继承的 PATH；可手动指定 Emulator 可执行文件路径 |

图形应用不一定继承终端的环境变量。对于自定义 SDK、未被 Spotlight 索引的安装或多个版本并存的环境，建议显式指定路径。路径支持 `~` 和空格，不要额外添加 shell 引号。

手动 CLI 路径无效时会报错，不会静默改用自动候选。Android 的 avdmanager 从所选 emulator 所在 SDK 的 cmdline-tools（优先 latest）、旧 tools/bin 或继承的 PATH 查找，目前没有单独的手动配置字段。

## 平台实现与兼容边界

### iOS

列表使用 `xcrun simctl list devices --json`；运行时标识转换为可读版本（如 `iOS 18.5`），不可用设备同时保留错误原因；boot、shutdown 和 delete 均针对具体 UDID。不可用状态依据 isAvailable 判断。Booted 映射为“运行中”，不等同于桌面或应用已经完全就绪。

兼容旧版 Simulator.app 和 Xcode 27 的 DeviceHub.app。当前本机 Device Hub 位于 `/Applications/Xcode.app/Contents/Applications/DeviceHub.app`；程序从应用 Info.plist 的 CFBundleExecutable 判断可执行文件。

Device Hub 通过 `devices://device/open?id=<UDID>` 打开目标设备，旧版 Simulator 使用 `-CurrentDeviceUDID` 参数。运行中的 iOS 设备可点击“显示”。窗口打开结果取决于系统和对应 Xcode 应用，不对所有版本的窗口聚焦行为作保证。

### Android

通过 `emulator -list-avds` 查询 AVD，通过 `adb devices` 查询连接端点，仅接受 emulator-* serial，并使用 `adb -s SERIAL emu avd name` 关联 AVD。名称解析兼容 LF 和 CRLF 换行；启动使用 `-avd NAME`，停止使用 `emu kill`。

无法关联名称的启动中 serial 不单独生成设备行，并暂时将未关联 AVD 标记为状态未知以阻止重复启动。AndroidRegistry 保留仍出现在 adb 列表中的 serial 与已确认名称的关联；serial 从列表消失后移除缓存。连接成功但 sys.boot_completed 尚未返回 1 时标记“启动中”，返回 1 后才标记“运行中”。这仍不代表所有应用均已就绪。真正的多个运行实例仍可按 serial 分别停止。

设备详情优先显示 `Android 15 · API 35 · arm64` 这样的系统版本、API 等级和架构。停止时读取 AVD 配置及镜像的 `source.properties`、`build.prop`，支持自定义目录和小数 API 等级；运行就绪后用 getprop 校验并缓存。镜像或配置变化、设备断开后相应缓存失效。不能确认系统版本时仅显示已知的 API / 架构，不根据设备名称猜测版本；serial 保留给设备关联、停止操作和悬停详情。

### HarmonyOS

当前兼容基准是本机 DevEco Studio 26 的 `Emulator -list -details` JSON 数组，使用 name、isRunning、os.osVersion 和 instancePath 等字段；设备名称作为启动、停止和删除的命令参数，支持空格。isRunning 支持字符串 true/false、1/0 及可转换的布尔值；未知状态禁用启动、停止操作。

对不支持的列表格式显示解析错误。目前没有表格文本解析器，也没有宣称覆盖所有 DevEco 版本；新增格式需要用实际输出样本验证。

### 进程与等待

短命令的默认超时为 20 秒；iOS boot 为 120 秒，删除命令为 60 秒，HarmonyOS stop 为 45 秒。超时会先请求终止命令进程，必要时发送 SIGKILL；不会递归终止它启动的所有子进程。stdout/stderr 合并写入临时文件，避免未读取管道导致阻塞。

Android / HarmonyOS 启动器由 LaunchManager 持有，输出写独立日志，进程退出后移除引用。启动后约 0.7 秒检查已发生的非零退出；更晚的启动失败主要依靠状态查询和等待超时发现。

启动或停止命令返回后，界面开始约 120 秒的目标状态等待，超时在后续刷新中报告。因此这不是整个操作的严格总超时，命令耗时和刷新耗时还需另外计入。

SimLaunch 不修改全局 xcode-select，不主动停止 adb 服务，也不会在退出时主动关闭模拟器。

## 外观与图标

macOS 26+ 的设置导航和操作区域使用原生 Liquid Glass；较旧系统回退到系统材质，降低透明度或增强对比度时使用实色背景。设备内容卡片保持独立背景。旧系统的运行效果尚未逐版本实测。

应用采用青绿／深蓝 S 图标。源图为 `Sources/SimLaunch/Resources/SimLaunchIcon.png`，状态栏使用 `MenuBarTemplate.png`，通过 NSImage template 自动适配系统菜单栏外观。

`scripts/build-icon.sh` 生成多尺寸 ICNS；`scripts/build-app.sh` 将其写入应用包并设置 CFBundleIconFile，同时复制 Swift Package 资源包。仅修改界面中的图标不等同于为 `.app` 设置图标，正式应用包应通过该脚本生成。

## 测试与验证范围

```sh
# 基础测试；未显式启用的本机集成测试会跳过
swift test

# 可选：三平台本机查询，不启动、停止或删除设备
TRISIM_SMOKE=1 swift test --filter LocalSmokeTests

# 可选：对比三平台自动发现与手动指定路径的查询结果，并检查 iOS 界面应用路径
TRISIM_SMOKE=1 swift test --filter LocalDiscoverySmokeTests

# 可选：会启动指定的真实 iOS 模拟器，不自动停止
TRISIM_IOS_UDID=你的设备UDID swift test --filter IOSLaunchTests
```

上述 TRISIM_* 是测试代码目前保留的历史环境变量名，并非应用名称。

测试覆盖输出解析、Android 启动中的身份关联、参数传递、非零退出和超时、大输出、路径发现、手动路径校验、符号链接 SDK 的 ADB 关联、恢复自动查找、删除状态限制、冷启动参数、本地化资源等。测试通过不代表所有外部工具操作都已完成端到端验证。

本机此前已验证三平台列表查询、iOS 设备启动及 Device Hub 窗口显示，并检查过设置页、语言切换和图标显示。设备数量、SDK 版本和可用运行时取决于本机环境，不作为功能保证。完整三平台启动／停止／冷启动／删除、登录后自动启动以及跨 macOS 版本兼容性仍需进一步验证。

当前不提供模拟器创建、系统镜像管理或截图。设置 → 通用已加入软件更新入口；应用内安装更新需要已配置 Sparkle 的正式构建和可访问的 Release 更新源，默认开发包仅提供发布页下载入口。完整自动更新链路尚待首次真实发布验证。

## Release 与更新

已加入 GitHub Actions：main / PR 运行测试和打包；推送 `vX.Y.Z` 标签生成通用应用、签名更新归档，并发布 GitHub Release。需要先配置仓库密钥，操作步骤、凭据清单和验证边界见 [docs/RELEASING.md](docs/RELEASING.md)。Sparkle 2.10.1 已下载，启用 Sparkle 的 Debug 可执行文件已编译通过；正式通用包、远程工作流和跨版本升级仍需在凭据配置完成后验证。

## 源码入口

| 文件 | 职责 |
| --- | --- |
| `Sources/SimLaunch/App.swift` | 设备列表、使用记录、设置及操作协调 |
| `Sources/SimLaunch/MenuBarController.swift` | 状态栏面板、启动行为、独立设置窗口及分类折叠状态 |
| `Sources/SimLaunchCore/AndroidSystemInfo.swift` | Android 镜像与运行时版本读取及缓存 |
| `Sources/SimLaunch/WindowPresentation.swift` | 设置窗口激活、前置及初始焦点处理 |
| `Sources/SimLaunch/LoginItemController.swift` | macOS 登录项状态及注册操作 |
| `Sources/SimLaunch/Appearance.swift` | 平台图标、通用设置图标和材质适配 |
| `Sources/SimLaunch/AppBrand.swift` | 应用 Logo 和状态栏模板图标加载 |
| `Sources/SimLaunchCore/Models.swift` | 设备模型、Provider 接口、路径发现和启动参数 |
| `Sources/SimLaunchCore/Providers.swift` | 三平台 CLI 调用及列表解析 |
| `Sources/SimLaunchCore/AndroidInventory.swift` | AVD 与 serial 的关联和状态合并 |
| `Sources/SimLaunchCore/DeviceDirectories.swift` | AVD 数据路径及删除状态校验 |
| `Sources/SimLaunchCore/ProcessRunner.swift` | 短命令执行和启动器生命周期管理 |
| `Sources/SimLaunchCore/Localization.swift`、`Resources/` | 本地化字符串及语言选择 |
| `Tests/SimLaunchCoreTests/CoreTests.swift` | 基础测试与可选本机集成测试 |

## 支持开发

本项目采用 [MIT License](LICENSE)，支持自愿赞助，无需付款即可使用。应用设置 → 通用中也提供“请我喝杯咖啡”入口。许可证核查与分发声明见 [许可证说明](docs/LICENSING.md)。

如果 SimLaunch 对你有帮助，欢迎通过 [Buy Me a Coffee ☕](https://buymeacoffee.com/1239383708p) 支持后续开发与维护。

## 参考

- [Android Emulator 命令行文档](https://developer.android.com/studio/run/emulator-commandline)
- [Android avdmanager 文档](https://developer.android.com/tools/avdmanager)
- [Apple Device Hub 文档](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub)
- [Expo 的 Xcode 27 Device Hub 适配说明](https://expo.dev/blog/xcode-27-device-hub-expo-device-hub)
- HarmonyOS 的实际命令和参数以本机 `Emulator -help` 为准。
