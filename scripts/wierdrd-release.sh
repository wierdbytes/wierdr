#!/bin/sh
# wierdrd's release: the universal binary packed for Homebrew, and its formula for the tap
# wierdbytes/apps (github.com/wierdbytes/homebrew-apps; docs/wierdrd.md).
# .github/workflows/release-wierdrd.yml runs it on a push to master that raised the version;
# by hand it's for checking.
#
#   scripts/wierdrd-release.sh version          the version (Packages/WierdrKit/Sources/wierdrd/Version.swift)
#   scripts/wierdrd-release.sh package          build arm64 + x86_64, sign, notarize → dist/wierdrd-<v>-macos.tar.gz
#                                               (prints its SHA-256)
#   scripts/wierdrd-release.sh formula <sha256> [url]
#                                               print the tap's Formula/wierdrd.rb for this version (url:
#                                               the release's asset in wierdr unless given, e.g. file://)
#
# Signing, when set: WIERDRD_SIGN_IDENTITY ("Developer ID Application: …", in the keychain);
# notarizing, when also set: NOTARY_KEY (an App Store Connect API key's .p8), NOTARY_KEY_ID,
# NOTARY_ISSUER. Without them the binary keeps the linker's ad-hoc signature: Homebrew doesn't
# quarantine what a formula downloads, so it runs.
set -eu
cd "$(dirname "$0")/.."

VERSION_FILE=Packages/WierdrKit/Sources/wierdrd/Version.swift
REPO=wierdbytes/wierdr

version() {
  v=$(sed -n 's/^let wierdrdVersion = "\(.*\)"$/\1/p' "$VERSION_FILE")
  [ -n "$v" ] || { echo "no version in $VERSION_FILE" >&2; exit 1; }
  echo "$v"
}

package() {
  V=$(version)
  BUILD="swift build -c release --arch arm64 --arch x86_64 --product wierdrd"
  (cd Packages/WierdrKit && $BUILD >&2)
  BIN=$(cd Packages/WierdrKit && $BUILD --show-bin-path)
  OUT="dist/wierdrd-$V"
  rm -rf "$OUT" && mkdir -p "$OUT"
  # The resource bundles go beside it (WierdrKit_WierdrModel.bundle: programs.json).
  cp "$BIN/wierdrd" "$OUT/"
  cp -R "$BIN"/*.bundle "$OUT/"
  got=$("$OUT/wierdrd" --version)
  [ "$got" = "$V" ] || { echo "the binary says $got, not $V" >&2; exit 1; }
  if [ -n "${WIERDRD_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --identifier pw.xff.wierdr.wierdrd \
      --sign "$WIERDRD_SIGN_IDENTITY" "$OUT/wierdrd"
    codesign --verify --strict --verbose=2 "$OUT/wierdrd" >&2
    if [ -n "${NOTARY_KEY:-}" ]; then
      # A bare Mach-O can't be stapled: Gatekeeper asks Apple online, if it ever asks.
      ZIP="dist/wierdrd-$V-notarize.zip"
      ditto -c -k --keepParent "$OUT/wierdrd" "$ZIP"
      result=$(xcrun notarytool submit "$ZIP" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER" --wait --output-format json)
      rm -f "$ZIP"
      echo "$result" >&2
      status=$(echo "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))')
      [ "$status" = "Accepted" ] || { echo "notarization: $status" >&2; exit 1; }
    fi
  else
    echo "not signed: no WIERDRD_SIGN_IDENTITY (the linker's ad-hoc signature stays)" >&2
  fi
  TAR="dist/wierdrd-$V-macos.tar.gz"
  # No AppleDouble files (._*) for extended attributes.
  (cd dist && COPYFILE_DISABLE=1 tar -czf "wierdrd-$V-macos.tar.gz" "wierdrd-$V")
  echo "$TAR" >&2
  shasum -a 256 "$TAR" | cut -d' ' -f1
}

formula() {
  V=$(version)
  SHA=$1
  URL=${2:-https://github.com/$REPO/releases/download/wierdrd-v$V/wierdrd-$V-macos.tar.gz}
  cat <<RB
# wierdrd: Wierdr's daemon on the Mac (https://github.com/$REPO/blob/master/docs/wierdrd.md).
#   brew install wierdbytes/apps/wierdrd && brew services start wierdrd
# Written for each release by Wierdr's workflow (scripts/wierdrd-release.sh in $REPO):
# changes here are overwritten.
class Wierdrd < Formula
  desc "Wierdr's daemon: Herdr's agents on your iPhone's Lock Screen"
  homepage "https://github.com/$REPO"
  url "$URL"
  version "$V"
  sha256 "$SHA"

  depends_on :macos
  on_macos do
    depends_on macos: :sequoia
  end

  def install
    # The binary finds its resource bundles beside it.
    libexec.install Dir["*"]
    bin.write_exec_script libexec/"wierdrd"
  end

  def caveats
    <<~EOS
      Wierdr sets wierdrd up by itself when it connects to this Mac. By hand:
        brew services start wierdrd
      Without ~/.config/wierdr/push.json it pushes through Wierdr's relay.
    EOS
  end

  service do
    run [opt_libexec/"wierdrd", "run"]
    keep_alive true
    process_type :background
    log_path var/"log/wierdrd.log"
    error_log_path var/"log/wierdrd.log"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/wierdrd --version").strip
  end
end
RB
  echo "wierdrd.rb: $V ($URL)" >&2
}

case "${1:-}" in
  version) version ;;
  package) package ;;
  formula) [ -n "${2:-}" ] || { echo "formula <sha256> [url]" >&2; exit 1; }; formula "$2" "${3:-}" ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
