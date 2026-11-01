# 许可证与自愿支持

核查日期：2026-11-02。

## 当前项目

根目录 `LICENSE` 是 MIT License，版权声明为 `Copyright (c) 2026 BraveShine`。许可证允许使用、修改、分发及销售软件副本，要求在副本或实质性部分中保留版权及许可声明；没有禁止自愿赞助的条款。参见 [项目许可证](../LICENSE) 与 [MIT 官方文本](https://opensource.org/license/mit)。

因此，就当前仓库的许可证文本而言，在应用、官网和 README 放置自愿支持链接不需要更换许可证。支持款项不改变用户已获得的 MIT 许可权利，当前项目不将付款作为使用功能或获取许可证的条件。

## Buy Me a Coffee

已检查平台的 [Terms of Use](https://buymeacoffee.com/terms) 与 [Community Guidelines](https://buymeacoffee.com/community-guidelines)。相关条款要求发布者拥有所需权利、如实说明提供的内容，不指定必须采用某种开源许可证。当前入口只跳转到作者的支持页面；按自愿支持开发这一用途，未发现与 MIT 的直接冲突。

这项核查只覆盖仓库许可证文本和该链接用途，不代表平台已经审核账户，也未核实全部代码、素材的权利来源或账户收款资格。未来若增加付费商品、会员权益或交付承诺，应另行检查对应要求。

## 发布包与第三方声明

- 打包脚本将根目录 `LICENSE` 复制到 `SimLaunch.app/Contents/Resources/LICENSE.txt`，保留完整版权与许可文本。
- 默认开发构建没有第三方 Swift 包依赖；正式构建可启用 Sparkle 2.10.1。
- 已检查本地 Sparkle 的 `LICENSE`：包含其 MIT 许可及 BSD、zlib 等组件声明。现有打包脚本复制完整文件至 `Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE.txt`，这些声明应继续随包含 Sparkle 的应用分发。
- Xcode、Android SDK、DevEco Studio 通过用户本机的命令行工具调用；项目打包脚本不将这些 SDK 或系统镜像打进应用。它们自身的使用许可由相应工具提供。

本次保留原有 MIT 许可证及版权署名，没有更改项目授权方式。
