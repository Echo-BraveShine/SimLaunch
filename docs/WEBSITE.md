# 中英文官网与 GitHub Pages

官网源码在 `website/`，使用 HTML、CSS 和原生 JavaScript，没有 npm 依赖、外部字体或第三方统计。当前包含产品介绍、真实应用截图、功能、下载、Homebrew 安装、首次打开的安全提示和常见问题。

## 本地预览

在项目根目录运行：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

访问 `http://127.0.0.1:4173/`。中文和英文链接分别为 `?lang=zh` 和 `?lang=en`。语言选择按 URL 参数、本机已保存偏好、浏览器语言的顺序决定；切换后保存在本机。页面不依赖 JavaScript 即可阅读默认中文内容。

## 部署到 GitHub

1. 提交并推送官网源码和 `.github/workflows/pages.yml`。
2. 在 GitHub 仓库 **Settings → Pages → Build and deployment → Source** 中选择 **GitHub Actions**。
3. 在 **Actions → Website → Run workflow** 中选择 `main` 运行。之后向 `main` 推送官网改动会自动检查和部署；PR 只检查，不上线。
4. 查看工作流中 `github-pages` 环境返回的实际地址。默认项目站点预期为 `https://echo-braveshine.github.io/SimLaunch/`，以 GitHub 返回结果为准。

使用工作流自带的 `GITHUB_TOKEN`，无需额外 Secret。Pages 尚未启用、仓库策略限制 Pages，或环境要求人工审批时，需要在 GitHub 中完成对应设置。实现依据 [GitHub 官方工作流文档](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。

应用 Release 工作流和网站部署独立运行。官网只上传 `website/`，安装包仍由 GitHub Releases 提供；源码、构建产物和密钥不随网站上传。

## 内容与维护

- `index.html`：页面内容、无脚本时的中文内容和初始元信息。
- `styles.css`：桌面和手机布局、视觉效果及减少动态效果支持。
- `app.js`：完整中英文文案、语言选择与安装命令复制。
- `assets/`：沿用项目 Logo，以及运行真实应用截取的设备列表、设置界面。
- `scripts/check-website.py`：检查本地资源、锚点和双语文案覆盖。

网站不维护独立应用版本号。下载按钮指向 GitHub 最新正式 Release 页面，避免应用发版后网站仍链接旧归档。Homebrew 需要先成功发布并同步 Cask；在准备完成前，网站保留相应说明。未来完成 Apple 签名及公证后，需要同步更新首页和 README 的首次打开提示。

检查页面：

```sh
python3 scripts/check-website.py
node --check website/app.js
```

网站路径均使用相对地址，可以部署在 `/SimLaunch/` 子路径下，也支持以后绑定自定义域名。
