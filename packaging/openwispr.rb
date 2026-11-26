cask "openwispr" do
  version "0.20.1"
  sha256 "f8215e055e2d17cf3dfcc80a39c8deccc60be569e38024b0f019ab9e1b9fec72"

  url "https://github.com/SirCharan/openwispr/releases/download/v#{version}/OpenWispr.zip"
  name "OpenWispr"
  desc "On-device dictation and meeting notes for macOS"
  homepage "https://charandeepkapoor.com/openwispr"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "OpenWispr.app"
  binary "#{appdir}/OpenWispr.app/Contents/Helpers/openwispr"

  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/OpenWispr.app"]
  end

  zap trash: [
    "~/Library/Application Support/OpenWispr",
    "~/Library/Preferences/org.openwispr.app.plist",
  ]
end
