// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "ebook-capture",
  platforms: [.macOS(.v14)],  // SCScreenshotManager
  targets: [
    .target(name: "EbookCapture"),
    .executableTarget(name: "ebook-capture", dependencies: ["EbookCapture"]),
    .testTarget(name: "EbookCaptureTests", dependencies: ["EbookCapture"]),
  ]
)
