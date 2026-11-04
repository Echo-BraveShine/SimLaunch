cask "simlaunch" do
  version "0.1.9"
  sha256 "7b7aa0dacaa99174e5da9012e6c6c8b36afc50c46e0809477c694391befc2a0c"

  url "https://github.com/Echo-BraveShine/SimLaunch/releases/download/v#{version}/SimLaunch-#{version}-universal.zip"
  name "SimLaunch"
  desc "Manage iOS, Android, and HarmonyOS simulators from the menu bar"
  homepage "https://github.com/Echo-BraveShine/SimLaunch"

  auto_updates true
  depends_on macos: :ventura

  app "SimLaunch.app"

  uninstall quit: "dev.ekko.simlaunch"
end
