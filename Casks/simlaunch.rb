cask "simlaunch" do
  version "0.1.4"
  sha256 "4580a47468a83a347867c9dc6dd1bdf4af38da8f88c908b0db74a6b3b6a3a4f3"

  url "https://github.com/Echo-BraveShine/SimLaunch/releases/download/v#{version}/SimLaunch-#{version}-universal.zip"
  name "SimLaunch"
  desc "Manage iOS, Android, and HarmonyOS simulators from the menu bar"
  homepage "https://github.com/Echo-BraveShine/SimLaunch"

  auto_updates true
  depends_on macos: :ventura

  app "SimLaunch.app"

  uninstall quit: "dev.ekko.simlaunch"
end
