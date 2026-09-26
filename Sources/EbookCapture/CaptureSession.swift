import CoreGraphics
import Foundation

private var interruptFlag: sig_atomic_t = 0

/// Ctrl-C / SIGTERM set a flag; the page loop stops at the next check and
/// merges what it has, instead of dying mid-write.
public enum InterruptSignal {
  public static func install() {
    signal(SIGINT) { _ in interruptFlag = 1 }
    signal(SIGTERM) { _ in interruptFlag = 1 }
  }

  public static var requested: Bool { interruptFlag != 0 }
}

public struct CaptureSession {
  public var output: OutputPath
  public var pages: Int
  public var app: AppTarget
  /// Relative to the screen the app window is on; nil = whole window.
  public var region: Region?
  public var margin: Int
  public var pageTimeoutSeconds: Int
  public var tempRoot: URL

  /// Returns the process exit code (0, or 130 when interrupted).
  /// The caller has already confirmed overwriting an existing output.
  public func run() async throws -> Int32 {
    let pdf = output.url
    let fm = FileManager.default

    guard let pid = AppControl.runningPID(of: app) else {
      throw CLIError("\(app.label) is not running. Open the book in it first.")
    }
    try Permissions.check()
    try AppControl.activate(app)
    try await Task.sleep(for: .milliseconds(1500))

    guard let window = WindowInfo.front(of: pid) else {
      throw CLIError("cannot find a \(app.label) window")
    }
    // Regions are given relative to the window's screen (as Cmd+Shift+4
    // shows them); window frames and capture use global coordinates
    let screen = Displays.origin(containing: CGPoint(x: window.frame.midX, y: window.frame.midY))
    let area: Region
    if let region {
      area = region.translated(by: screen)
      guard window.frame.contains(area.rect) else {
        let w = try Region.inset(window.frame, margin: 0).translated(by: CGPoint(x: -screen.x, y: -screen.y))
        throw CLIError("capture area \(region) is outside the \(app.label) window (\(w) on its screen)")
      }
    } else {
      area = try Region.inset(window.frame, margin: margin)
      print("Capture area (x y w h): \(area.translated(by: CGPoint(x: -screen.x, y: -screen.y)))")
    }
    let capturer = try await WindowCapturer(window: window, region: area)

    // A leftover folder from an earlier run would mix its pages into this PDF
    let dir = tempRoot.appendingPathComponent(output.name)
    if fm.fileExists(atPath: dir.path) {
      print("Removing leftover capture folder: \(dir.path)")
      try fm.removeItem(at: dir)
    }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    InterruptSignal.install()

    let waiter = PageWaiter(timeout: .seconds(pageTimeoutSeconds))
    var previous: Frame?
    do {
      for i in 1...pages {
        if InterruptSignal.requested { throw Interrupted() }
        let frame: Frame
        if let previous {
          try AppControl.activate(app)
          AppControl.pressNextPage()
          let result = try await waiter.waitForTurn(
            from: previous, same: { $0.sameContent(as: $1) }, grab: capturer.capture,
            stop: { InterruptSignal.requested })
          if !result.turned {
            print("Warning: page \(i) did not change within \(pageTimeoutSeconds)s (captured anyway)")
          }
          frame = result.frame
        } else {
          frame = try await capturer.capture()
        }
        try frame.writePNG(to: dir.appendingPathComponent(String(format: "page-%05d.png", i)))
        previous = frame
        print("[\(i)/\(pages)]")
      }
    } catch {
      // Ctrl-C also hits child processes (open), so any failure after the
      // signal counts as an interruption
      guard error is Interrupted || InterruptSignal.requested else { throw error }
      return finishInterrupted(dir: dir, pdf: pdf)
    }

    try PDFWriter.merge(pngsIn: dir, to: pdf)
    print("PDF created: \(pdf.path)")
    try? fm.removeItem(at: dir)
    print("Done: \(pdf.path)")
    return 0
  }

  /// Merges whatever pages were captured so far into a partial PDF,
  /// then cleans up the temporary directory.
  private func finishInterrupted(dir: URL, pdf: URL) -> Int32 {
    print("\nInterrupted.")
    let fm = FileManager.default
    let hasPages = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".png") }
    if hasPages {
      print("Merging captured pages into a partial PDF...")
      do {
        try PDFWriter.merge(pngsIn: dir, to: pdf)
        print("PDF created: \(pdf.path)")
        try? fm.removeItem(at: dir)
      } catch {
        print("Warning: partial merge failed. PNG files are kept in \(dir.path)")
      }
    } else {
      try? fm.removeItem(at: dir)
    }
    return 130
  }
}
