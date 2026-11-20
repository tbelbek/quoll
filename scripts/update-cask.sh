#!/bin/bash
# Writes Casks/quoll.rb for a released version into a clone of the tap
# (github.com/tbelbek/homebrew-quoll). Usage: update-cask.sh <version> <sha256> <tap-dir>
set -euo pipefail
VERSION="$1"; SHA="$2"; TAP="$3"
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/quoll.rb" <<RUBY
cask "quoll" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/tbelbek/quoll/releases/download/v#{version}/Quoll-#{version}-macos-universal.zip"
  name "Quoll"
  desc "Instant filename search with a global hotkey"
  homepage "https://github.com/tbelbek/quoll"

  depends_on macos: :ventura

  app "Quoll.app"
  binary "#{appdir}/Quoll.app/Contents/MacOS/quoll-cli", target: "quoll"

  zap trash: [
    "~/Library/Application Support/Quoll",
    "~/Library/Preferences/com.quoll.search.plist",
  ]

  caveats <<~EOS
    Quoll is not notarized. If macOS refuses to open it the first time:
      xattr -dr com.apple.quarantine #{appdir}/Quoll.app
    Then grant Full Disk Access (System Settings > Privacy & Security) so the
    first scan does not stop at every protected folder.
  EOS
end
RUBY
echo "wrote $TAP/Casks/quoll.rb ($VERSION)"
