# Template for the tap repository satanmoo/homebrew-tap (Formula/ebook-capture.rb).
# On each release, update `url` and `sha256` from the release's checksums.txt.
class EbookCapture < Formula
  desc "Capture ebook pages from 교보도서관 or a Chrome web viewer into a PDF"
  homepage "https://github.com/satanmoo/ebook-capture"
  url "https://github.com/satanmoo/ebook-capture/releases/download/v1.0.0/ebook-capture-v1.0.0-macos.tar.gz"
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_FROM_CHECKSUMS_TXT"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "ebook-capture"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/ebook-capture --version").strip
  end
end
