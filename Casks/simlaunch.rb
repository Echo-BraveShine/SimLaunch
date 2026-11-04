cask "simlaunch" do
  version "0.1.8"
  sha256 "a3a07bb2ecf33722ede82539a5cc32c6e90404832561bf4f8987bc2636b68d85"

  url "https://github.com/Echo-BraveShine/SimLaunch/releases/download/v#{version}/SimLaunch-#{version}-universal.zip"
  name "SimLaunch"
  desc "Manage iOS, Android, and HarmonyOS simulators from the menu bar"
  homepage "https://github.com/Echo-BraveShine/SimLaunch"

  auto_updates true
  depends_on macos: :ventura

  app "SimLaunch.app"

  uninstall quit: "dev.ekko.simlaunch"
end
