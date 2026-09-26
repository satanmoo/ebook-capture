# Template for satanmoo/homebrew-tap (Formula/ebook-capture.rb).
# .github/workflows/release.yml fills in {{VERSION}} and {{SHA256}} and commits
# the result to the tap on every release; don't edit the tap's copy by hand.
class EbookCapture < Formula
  desc "Capture ebook pages from 교보도서관 or a Chrome web viewer into a PDF"
  homepage "https://github.com/satanmoo/ebook-capture"
  url "https://github.com/satanmoo/ebook-capture/releases/download/v{{VERSION}}/ebook-capture-v{{VERSION}}-macos.tar.gz"
  version "{{VERSION}}"
  sha256 "{{SHA256}}"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "ebook-capture"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/ebook-capture --version").strip
  end
end
