cask "helge-launcher" do
  version "@VERSION@"
  sha256 "@SHA256@"
  url "https://github.com/HelgeSverre/helge-launcher/releases/download/v#{version}/HelgeLauncher-#{version}-universal.zip"
  name "Helge Launcher"
  desc "Keyboard launcher for apps, CleanShot, clipboard, snippets, 1Password and AI"
  homepage "https://github.com/HelgeSverre/helge-launcher"

  livecheck do
    url "https://github.com/HelgeSverre/helge-launcher/releases"
    regex(/^v?(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  depends_on macos: :sonoma

  app "Helge Launcher.app"

  uninstall quit: "no.helgesverre.launcher"

  zap trash: [
    "~/.config/hl",
    "~/Library/Application Support/HelgeLauncher",
    "~/Library/Caches/no.helgesverre.launcher",
    "~/Library/HTTPStorages/no.helgesverre.launcher",
    "~/Library/Preferences/no.helgesverre.launcher.plist",
  ]
end
