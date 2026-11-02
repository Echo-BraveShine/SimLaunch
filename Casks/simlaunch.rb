cask "simlaunch" do
  version "0.1.5"
  sha256 "e7cc0a28d3687dad888f748c6a2bf6f313476e9e5ee8178941ffa81bc09f44d0"

  url "https://github.com/Echo-BraveShine/SimLaunch/releases/download/v#{version}/SimLaunch-#{version}-universal.zip"
  name "SimLaunch"
  desc "Manage iOS, Android, and HarmonyOS simulators from the menu bar"
  homepage "https://github.com/Echo-BraveShine/SimLaunch"

  auto_updates true
  depends_on macos: :ventura

  app "SimLaunch.app"

  uninstall quit: "dev.ekko.simlaunch"
end
