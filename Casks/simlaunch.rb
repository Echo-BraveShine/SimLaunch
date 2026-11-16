cask "simlaunch" do
  version "0.2.1"
  sha256 "879ea3875da2cd0552899a81b6d7ea3d4ec535aa30f2d4b1fb858160d85c5ec0"

  url "https://github.com/Echo-BraveShine/SimLaunch/releases/download/v#{version}/SimLaunch-#{version}-universal.zip"
  name "SimLaunch"
  desc "Manage iOS, Android, and HarmonyOS simulators from the menu bar"
  homepage "https://github.com/Echo-BraveShine/SimLaunch"

  auto_updates true
  depends_on macos: :ventura

  app "SimLaunch.app"

  uninstall quit: "dev.ekko.simlaunch"
end
