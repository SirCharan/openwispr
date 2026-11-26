cask "openwispr" do
  version "0.20.0"
  sha256 "e69229656edb18969fa703bb29c38bc8eac9bd65983e5edd710a14543f22647a"

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
