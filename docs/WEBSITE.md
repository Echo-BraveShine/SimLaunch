# 中英文官网与 GitHub Pages

官网源码在 `website/`，使用 HTML、CSS 和原生 JavaScript，没有 npm 依赖、外部字体或第三方统计。当前包含产品介绍、真实应用截图、功能、下载、Homebrew 安装、首次打开的安全提示和常见问题。

## 本地预览

在项目根目录运行：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

访问 `http://127.0.0.1:4173/`。中文和英文链接分别为 `?lang=zh` 和 `?lang=en`。语言选择按 URL 参数、本机已保存偏好、浏览器语言的顺序决定；切换后保存在本机。页面不依赖 JavaScript 即可阅读默认中文内容。

导航栏提供跟随系统、浅色、深色三种外观。默认跟随系统，并实时响应系统深浅色变化；手动选择保存在浏览器本地。可以使用 `?lang=zh&theme=dark` 分享指定语言和主题的页面，`theme` 支持 `system`、`light`、`dark`，URL 参数优先于已保存偏好。页面加载时在样式绘制前解析外观，避免深色模式先闪出浅色背景。禁用 JavaScript 时提供默认中文浅色页面。

设备列表和通用设置各有中英文、深浅色四个真实截图，共八张，存放在 `website/assets/{devices|settings}-{zh|en}-{light|dark}.png`。页面主题和语言改变时，同步切换截图、替代文本及查看原图的链接。截图来自应用实际切换后的界面，更新应用 UI 后应同步重新拍摄。

截图使用带透明通道的 PNG。设备面板保留圆角和定位箭头，尺寸为 `800×1249`；设置截图裁去系统标题栏及屏幕共享标记，保留完整应用内容，尺寸为 `1760×1240`。只裁去外围系统区域并处理窗口轮廓以外的透明度，不改绘界面内容。网页不再给图片叠加边框或另一套圆角，使用 `drop-shadow()` 沿透明轮廓投影，避免深色背景下的白色边角和二次裁切。更新时保持同类截图的尺寸一致，并同步更新 `index.html` 中图片的 `width`、`height`，以便图片载入前预留正确比例。不要把 JPEG 文件直接改成 `.png` 后缀。

## 部署到 GitHub

1. 提交并推送官网源码和 `.github/workflows/pages.yml`。
2. 在 GitHub 仓库 **Settings → Pages → Build and deployment → Source** 中选择 **GitHub Actions**。
3. 在 **Actions → Website → Run workflow** 中选择 `main` 运行。之后向 `main` 推送官网改动会自动检查和部署；PR 只检查，不上线。
4. 查看工作流中 `github-pages` 环境返回的实际地址。默认项目站点预期为 `https://echo-braveshine.github.io/SimLaunch/`，以 GitHub 返回结果为准。

使用工作流自带的 `GITHUB_TOKEN`，无需额外 Secret。Pages 尚未启用、仓库策略限制 Pages，或环境要求人工审批时，需要在 GitHub 中完成对应设置。实现依据 [GitHub 官方工作流文档](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。

应用 Release 工作流和网站部署独立运行。官网只上传 `website/`，安装包仍由 GitHub Releases 提供；源码、构建产物和密钥不随网站上传。

### configure-pages 报 Not Found

如果 `actions/configure-pages@v5` 报 `Get Pages site failed` / `Not Found`，先打开 [仓库 Pages 设置](https://github.com/Echo-BraveShine/SimLaunch/settings/pages)，将 **Build and deployment → Source** 设置为 **GitHub Actions**，然后重跑失败的 Website 工作流。已有发布工作流，无需再添加 GitHub 推荐的模板。

当前工作流已经配置 `contents: read`、`pages: write` 和 `id-token: write`。这些权限用于部署，不表示仓库已启用 Pages。不要只添加 `enablement: true`：根据 [configure-pages v5 的参数说明](https://github.com/actions/configure-pages/blob/v5/action.yml)，自动启用 Pages 需要额外提供非 `GITHUB_TOKEN` 的合适令牌；当前方案在仓库设置中手动启用一次即可，无需新增 Secret。

如果 Pages 设置不可见或无法修改，检查当前账号的仓库管理权限、组织策略，以及私有仓库所用套餐是否支持 Pages。启用后仍报错时，检查是否禁用了 Pages，或发布来源是否仍为分支部署。

## 内容与维护

- `index.html`：页面内容、无脚本时的中文内容和初始元信息。
- `styles.css`：桌面和手机布局、视觉效果及减少动态效果支持。
- `themes.css`：外观切换按钮与深色配色，包含卡片、下载区、安全提示和手机导航适配。
- `appearance.js`：页面绘制前的主题初始化、外观选择记忆与系统主题监听。
- `app.js`：完整中英文文案、语言选择与安装命令复制。
- `assets/`：沿用项目 Logo，以及运行真实应用截取的设备列表、设置界面。
- `scripts/check-website.py`：检查本地资源、锚点和双语文案覆盖。

网站不维护独立应用版本号。下载按钮指向 GitHub 最新正式 Release 页面，避免应用发版后网站仍链接旧归档。Homebrew 需要先成功发布并同步 Cask；在准备完成前，网站保留相应说明。未来完成 Apple 签名及公证后，需要同步更新首页和 README 的首次打开提示。

检查页面：

```sh
python3 scripts/check-website.py
node --check website/app.js
node --check website/appearance.js
node --test scripts/tests/test_website_theme.js
```

网站路径均使用相对地址，可以部署在 `/SimLaunch/` 子路径下，也支持以后绑定自定义域名。

## 赞助入口

赞助地址为 `https://buymeacoffee.com/1239383708p`，已加入官网页脚和 README。GitHub 仓库的 Sponsor 按钮由 `.github/FUNDING.yml` 配置，其中 `buy_me_a_coffee` 只填写账号标识 `1239383708p`，不要填写完整 URL。将该文件推送到默认分支后生效，无需添加 API Key 或 Secret。若仓库未显示按钮，可在仓库 Settings → General → Features 中检查 Sponsorships 是否启用。
