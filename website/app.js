(() => {
  "use strict";

  const translations = {
    zh: {
      pageTitle: "SimLaunch — 三个平台，一个启动入口",
      pageDescription: "SimLaunch 是 macOS 菜单栏中的模拟器管理工具，支持 iOS、Android、HarmonyOS 与 MuMu，提供设备管理、实时日志和运行中设备的应用管理。",
      skip: "跳到内容", navigation: "主导航", language: "语言", platforms: "支持的平台",
      appearance: "网页外观", themeSystem: "跟随系统外观", themeLight: "浅色外观", themeDark: "深色外观",
      lightScreenshot: "浅色界面", darkScreenshot: "深色界面",
      support: "支持作者 ☕",
      navFeatures: "功能", navInstall: "安装", heroEyebrow: "为 macOS 开发者而作",
      heroLineOne: "三个平台。", heroLineTwo: "一个启动入口。",
      heroDescription: "iOS、Android、HarmonyOS。把分散的模拟器收进菜单栏，让启动、切换与日常管理都顺手一点。",
      download: "下载 macOS 版", installGuide: "安装指南", macos: "macOS 13+", swiftui: "原生 SwiftUI",
      screenshotCaption: "真实应用截图 · 设备与状态取决于本机环境",
      screenshotsEyebrow: "直接看看，真实界面", screenshotsTitle: "你的工具，你的设置。",
      screenshotsDescription: "截图来自实际运行的 SimLaunch。\n切换语言与外观，可查看对应的真实应用界面。",
      settingsScreenshotCaption: "通用设置 · 外观、语言与应用偏好",
      devicesAlt: "SimLaunch 中文设备面板，展示可折叠的平台分类和 Android 系统版本", settingsAlt: "SimLaunch 中文通用设置，包含外观、语言与应用偏好",
      platformIntro: "你的设备，不必分散管理。", featuresEyebrow: "少一点切换，多一点专注",
      featuresTitle: "日常要用的，刚刚好。", featuresDescription: "不必为每一次启动打开一整套开发工具。\n从设备列表开始，专注眼前的开发。",
      featureOneTitle: "从菜单栏，直达设备。", featureOneDescription: "在菜单栏中启动、停止模拟器。最近使用的设备最多显示 5 项，分类可折叠并记住状态，不可用设备单独归类。",
      featureTwoTitle: "顺手的事，一次右键。", featureTwoDescription: "右键查看设备信息、复制名称或标识符，定位可访问的设备目录。支持的设备可冷启动，删除操作需再次确认。",
      featureThreeTitle: "跟随你的开发环境。", featureThreeDescription: "自动发现或手动配置工具路径。中英文、深浅色外观与登录时启动，在同一个设置窗口完成。",
      featureFourTitle: "应用管理，触手可及。",
      featureFourDescription: "设备运行后，查看已安装应用及可获取的名称、图标、包名和版本信息。打开详情或卸载用户应用，操作前再次确认。",
      featureFiveTitle: "实时日志，安心追踪。",
      featureFiveDescription: "在独立面板中查看设备日志，筛选、搜索、复制或导出。向上滚动时暂停自动跟随，方便停留检查历史日志。",
      featureSixTitle: "MuMu，也在列表里。",
      featureSixDescription: "支持发现和管理 macOS 上的 MuMu 模拟器实例。与 Android 设备一起查看，运行后可使用日志和应用管理。",
      nativeEyebrow: "像 macOS 本来就有的一样", nativeTitle: "原生体验，安静陪伴。",
      nativeDescription: "使用 SwiftUI 构建，常驻菜单栏。在 macOS 26 及更新系统上，部分界面采用 Liquid Glass；较旧系统使用原生材质。",
      installEyebrow: "下一次开发，从这里开始", installTitle: "准备好，启动。", installDescription: "选择适合你的安装方式。\n开发工具与系统镜像需自行准备。",
      downloadCardTitle: "直接下载", downloadCardDescription: "前往 GitHub Releases，下载通用版 ZIP，解压并将 SimLaunch 移入“应用程序”。",
      viewRelease: "查看最新发布", downloadFootnote: "支持 Apple Silicon 与 Intel 的通用构建",
      copy: "复制命令", copied: "已复制", copySuccess: "安装命令已复制", copyFailure: "未能复制，请选中终端中的命令手动复制。",
      brewComment: "# 添加安装源并安装", brewNote: "需先发布包含 Cask 的版本。可用性及维护说明请查看仓库。", brewGuide: "Homebrew 安装与升级说明",
      securityTitle: "首次打开，需要你确认。", securityDescription: "当前发布版未使用 Apple Developer ID 签名，也未通过 Apple 公证。如果 macOS 阻止打开，请先确认下载来源，再到“系统设置 → 隐私与安全性”中点击“仍要打开”，并按提示确认。", appleHelp: "查看 Apple 官方说明",
      faqEyebrow: "开始之前", faqTitle: "你可能想知道。",
      faqOneTitle: "需要先安装哪些开发工具？", faqOneAnswer: "管理 iOS 设备需要完整 Xcode 和已安装的模拟器运行时；Android 需要 Android SDK 中的 emulator、adb 及已创建的 AVD；HarmonyOS 需要 DevEco Studio 及已创建的模拟器。SimLaunch 不包含这些工具。",
      faqTwoTitle: "能创建模拟器或下载系统镜像吗？", faqTwoAnswer: "目前专注于已有设备的查询、启动、停止与管理。创建虚拟设备和下载系统镜像，请使用对应平台的开发工具。",
      faqThreeTitle: "安装后为什么没有出现在 Dock 中？", faqThreeAnswer: "SimLaunch 常驻菜单栏，不显示 Dock 图标。启动时展开锚定状态栏图标的设备面板，之后点击该图标即可再次展开或收起。",
      faqFourTitle: "支持哪些 macOS 版本？", faqFourAnswer: "应用部署目标为 macOS 13 及以上，尚未在全部支持版本上完成实机验证。具体设备的可用性也取决于开发工具版本、系统镜像和电脑架构。",
      faqFiveTitle: "为什么有些应用信息或图标没有显示？",
      faqFiveAnswer: "应用管理仅对运行中的设备开放。名称、图标和版本取决于平台工具与资源访问权限；受保护资源可能显示占位图。系统应用不提供卸载操作，具体能力以所安装版本为准。",
      closingEyebrow: "让工具归位，让思路向前", closingTitle: "少找窗口。多写一点。", viewSource: "在 GitHub 查看源码", footerNote: "为更顺手的开发日常。", feedback: "问题反馈", releases: "发布记录", backToTop: "回到顶部 ↑"
    },
    en: {
      pageTitle: "SimLaunch — Three platforms. One place to launch.",
      pageDescription: "SimLaunch manages iOS, Android, HarmonyOS and MuMu simulators from the macOS menu bar, with device controls, live logs and application management for running devices.",
      skip: "Skip to content", navigation: "Main navigation", language: "Language", platforms: "Supported platforms",
      appearance: "Website appearance", themeSystem: "Follow system appearance", themeLight: "Light appearance", themeDark: "Dark appearance",
      lightScreenshot: "Light appearance", darkScreenshot: "Dark appearance",
      support: "Buy me a coffee ☕",
      navFeatures: "Features", navInstall: "Install", heroEyebrow: "Made for developers on macOS",
      heroLineOne: "Three platforms.", heroLineTwo: "One place to launch.",
      heroDescription: "iOS, Android, HarmonyOS. Bring your simulators to the menu bar, with a convenient place to launch, switch, and manage your devices.",
      download: "Download for macOS", installGuide: "Installation guide", macos: "macOS 13+", swiftui: "Native SwiftUI",
      screenshotCaption: "Actual app screenshot · Devices and states depend on your setup",
      screenshotsEyebrow: "A closer look at the real app", screenshotsTitle: "Your tools. Your settings.",
      screenshotsDescription: "Captured from a running copy of SimLaunch.\nSwitch language and appearance to see the matching interface.",
      settingsScreenshotCaption: "General settings · Appearance, language, and app preferences",
      devicesAlt: "SimLaunch device panel in English, showing collapsible platform groups and Android versions", settingsAlt: "SimLaunch general settings in English, with appearance, language, and app preferences",
      platformIntro: "Your devices. All in one place.", featuresEyebrow: "Less switching. More focus.",
      featuresTitle: "Everyday essentials, within reach.", featuresDescription: "Skip opening a full IDE just to launch a device.\nStart with your device list. Get back to building.",
      featureOneTitle: "Your menu bar. Your devices.", featureOneDescription: "Start and stop simulators from the menu bar. Keep up to five recent devices at the top, remember collapsed groups, and list unavailable devices separately.",
      featureTwoTitle: "A right click goes a long way.", featureTwoDescription: "Right-click to inspect device information, copy names or identifiers, and reveal accessible device folders. Supported devices offer cold boot; deletion requires confirmation.",
      featureThreeTitle: "At home in your setup.", featureThreeDescription: "Discover tools or set custom paths. Choose English or Chinese, light or dark appearance, and launch at login in one settings window.",
      featureFourTitle: "Applications, within reach.",
      featureFourDescription: "On running devices, browse installed apps and available names, icons, identifiers and versions. Open app details or uninstall user apps after confirmation.",
      featureFiveTitle: "Follow the logs. Keep your place.",
      featureFiveDescription: "Read device logs in a dedicated panel. Filter, search, copy or export them. Scroll up to pause automatic following while you inspect earlier messages.",
      featureSixTitle: "MuMu joins the list.",
      featureSixDescription: "Discover and manage MuMu instances on macOS alongside Android devices. Running instances also support logs and application management.",
      nativeEyebrow: "Feels right at home on your Mac", nativeTitle: "Native by design. Quiet by nature.",
      nativeDescription: "Built with SwiftUI, right in your menu bar. Selected surfaces use Liquid Glass on macOS 26 and later, with native materials on older systems.",
      installEyebrow: "Your next session starts here", installTitle: "Ready. Set. Launch.", installDescription: "Choose how you want to install.\nDeveloper tools and system images are installed separately.",
      downloadCardTitle: "Download the app", downloadCardDescription: "Get the universal ZIP from GitHub Releases, extract it, and move SimLaunch to your Applications folder.",
      viewRelease: "View latest release", downloadFootnote: "Universal builds for Apple Silicon and Intel",
      copy: "Copy commands", copied: "Copied", copySuccess: "Installation commands copied", copyFailure: "Copy failed. Select the commands in the terminal and copy them manually.",
      brewComment: "# Add the tap and install", brewNote: "Requires a release with a published Cask. See the repository for availability and maintenance details.", brewGuide: "Homebrew installation and updates",
      securityTitle: "Your first launch needs a confirmation.", securityDescription: "Current releases do not have Apple Developer ID signing or Apple notarization. If macOS blocks the app, verify the download source, then go to System Settings → Privacy & Security → Open Anyway and follow the prompts.", appleHelp: "Read Apple's instructions",
      faqEyebrow: "Before you begin", faqTitle: "A few things to know.",
      faqOneTitle: "Which developer tools do I need?", faqOneAnswer: "iOS devices require a full Xcode installation and simulator runtimes. Android requires the Android SDK emulator, adb, and an existing AVD. HarmonyOS requires DevEco Studio and an existing simulator. These tools are not included in SimLaunch.",
      faqTwoTitle: "Can I create devices or download system images?", faqTwoAnswer: "SimLaunch currently focuses on listing, launching, stopping, and managing existing devices. Use each platform's developer tools to create devices and download system images.",
      faqThreeTitle: "Why isn't SimLaunch in my Dock?", faqThreeAnswer: "SimLaunch lives in the menu bar and has no Dock icon. Launching opens the device panel anchored to its status icon. Click that icon to show or hide the panel again.",
      faqFourTitle: "Which macOS versions are supported?", faqFourAnswer: "The app targets macOS 13 and later; it has not been tested on every supported version. Device availability also depends on your developer tools, system images, and computer architecture.",
      faqFiveTitle: "Why are some app details or icons missing?",
      faqFiveAnswer: "Application management is available on running devices. Names, icons and versions depend on platform tools and resource permissions; protected resources may use placeholders. System apps cannot be uninstalled. Available features depend on your installed version.",
      closingEyebrow: "Tools in place. Ideas in motion.", closingTitle: "Less window hunting. More building.", viewSource: "Explore the source on GitHub", footerNote: "For a smoother development day.", feedback: "Report an issue", releases: "Releases", backToTop: "Back to top ↑"
    }
  };

  const commands = "brew tap echo-braveshine/simlaunch https://github.com/Echo-BraveShine/SimLaunch.git\nbrew install --cask echo-braveshine/simlaunch/simlaunch";
  let language = "zh";
  let toastTimeout;
  let copyTimeout;

  function updateScreenshots() {
    const theme = document.documentElement.dataset.theme === "dark" ? "dark" : "light";
    const strings = translations[language];
    document.querySelectorAll("[data-screenshot]").forEach(image => {
      const name = image.dataset.screenshot;
      const path = `./assets/${name}-${language}-${theme}.png`;
      if (image.getAttribute("src") !== path) image.src = path;
      image.alt = `${strings[`${name}Alt`]} · ${strings[`${theme}Screenshot`]}`;
    });
    document.querySelectorAll("[data-screenshot-link]").forEach(link => {
      link.href = `./assets/${link.dataset.screenshotLink}-${language}-${theme}.png`;
    });
  }

  function setLanguage(next, persist = false) {
    language = next === "en" ? "en" : "zh";
    const strings = translations[language];
    document.documentElement.lang = language === "en" ? "en" : "zh-CN";
    document.title = strings.pageTitle;
    document.querySelector('meta[name="description"]').content = strings.pageDescription;
    document.querySelector('meta[property="og:title"]').content = strings.pageTitle;
    document.querySelector('meta[property="og:description"]').content = strings.pageDescription;
    document.querySelectorAll("[data-i18n]").forEach(element => {
      const value = strings[element.dataset.i18n];
      if (value !== undefined) element.textContent = value;
    });
    document.querySelectorAll("[data-i18n-aria]").forEach(element => {
      element.setAttribute("aria-label", strings[element.dataset.i18nAria]);
    });
    document.querySelectorAll("[data-i18n-title]").forEach(element => {
      element.setAttribute("title", strings[element.dataset.i18nTitle]);
    });
    document.querySelectorAll("[data-language]").forEach(button => {
      button.setAttribute("aria-pressed", String(button.dataset.language === language));
    });
    updateScreenshots();
    document.getElementById("apple-help").href = language === "en"
      ? "https://support.apple.com/en-us/102445" : "https://support.apple.com/zh-cn/102445";
    clearTimeout(copyTimeout);
    if (persist) {
      try { localStorage.setItem("simlaunch-site-language", language); } catch { /* Storage is optional. */ }
      try {
        const url = new URL(location.href);
        url.searchParams.set("lang", language);
        history.replaceState(null, "", url);
      } catch { /* Local file previews may not support history updates. */ }
    }
  }

  function showToast(message) {
    const toast = document.getElementById("toast");
    toast.textContent = message;
    toast.classList.add("visible");
    clearTimeout(toastTimeout);
    toastTimeout = setTimeout(() => toast.classList.remove("visible"), 4000);
  }

  document.querySelectorAll("[data-language]").forEach(button => {
    button.addEventListener("click", () => setLanguage(button.dataset.language, true));
  });
  document.addEventListener("simlaunch:appearancechange", updateScreenshots);

  document.getElementById("copy-command").addEventListener("click", async () => {
    const button = document.getElementById("copy-command");
    button.disabled = true;
    try {
      if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
      await navigator.clipboard.writeText(commands);
      button.querySelector("span").textContent = translations[language].copied;
      showToast(translations[language].copySuccess);
      clearTimeout(copyTimeout);
      copyTimeout = setTimeout(() => {
        button.querySelector("span").textContent = translations[language].copy;
      }, 2500);
    } catch {
      showToast(translations[language].copyFailure);
      const range = document.createRange();
      range.selectNodeContents(document.getElementById("brew-command"));
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    } finally {
      button.disabled = false;
    }
  });

  const requested = new URLSearchParams(location.search).get("lang");
  let saved;
  try { saved = localStorage.getItem("simlaunch-site-language"); } catch { /* Storage is optional. */ }
  const preferred = [requested, saved].find(value => value === "zh" || value === "en");
  setLanguage(preferred || ((navigator.language || "en").toLowerCase().startsWith("zh") ? "zh" : "en"));
  document.querySelector(".hero-copy").classList.add("reveal");
})();
