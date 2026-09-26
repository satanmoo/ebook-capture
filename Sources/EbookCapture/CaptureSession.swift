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
  /// nil = until the end of the book.
  public var pages: Int?
  public var app: AppTarget
  /// Relative to the screen the app window is on; nil = whole window.
  public var region: Region?
  public var margin: Int
  public var pageTimeoutSeconds: Int
  public var tempRoot: URL

  /// Returns the process exit code: 0, 130 when interrupted, 1 when
  /// capturing failed (the pages captured before the failure are still saved).
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

    // A leftover folder from an earlier run would mix its pages into this
    // PDF. It may hold the only copy of a failed run's pages, so it goes to
    // the Trash rather than being deleted.
    let dir = tempRoot.appendingPathComponent(output.name)
    if fm.fileExists(atPath: dir.path) {
      do {
        try fm.trashItem(at: dir, resultingItemURL: nil)
      } catch {
        throw CLIError("a leftover capture folder is in the way and could not be moved to the Trash: "
          + "\(dir.path). Move or delete it, then try again.")
      }
      print("Moved a leftover capture folder to the Trash: \(dir.path)")
    }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    InterruptSignal.install()

    var loop = CaptureLoop<Frame>(
      maxPages: pages, waiter: PageWaiter(timeout: .seconds(pageTimeoutSeconds)),
      same: { $0.sameContent(as: $1) }, grab: capturer.capture,
      turnPage: {
        try AppControl.activate(app)
        AppControl.pressNextPage()
      },
      save: { frame, n in
        try frame.writePNG(to: dir.appendingPathComponent(String(format: "page-%05d.png", n)))
      })
    loop.stop = { InterruptSignal.requested }
    let result = await loop.run()

    let exitCode: Int32
    switch result.outcome {
    case .finished:
      exitCode = 0
    case .endOfBook:
      print("Reached the end of the book: the page didn't change after 2 waits of \(pageTimeoutSeconds)s.")
      exitCode = 0
    case .interrupted:
      print("\nInterrupted.")
      exitCode = 130
    case .failed(let message):
      printError("Error: capturing stopped at page \(result.pages + 1): \(message)")
      exitCode = 1
    }

    guard result.pages > 0 else {
      try? fm.removeItem(at: dir)
      return exitCode
    }
    // Whatever stopped the loop, the pages captured so far become the PDF
    do {
      try PDFWriter.merge(pngsIn: dir, to: pdf)
    } catch {
      printError("Error: could not create the PDF (\(error)). The captured pages are kept in \(dir.path)")
      return 1
    }
    try? fm.removeItem(at: dir)
    print("PDF created with \(result.pages) page\(result.pages == 1 ? "" : "s"): \(pdf.path)")
    if exitCode == 0 { print("Done: \(pdf.path)") }
    return exitCode
  }
}

func printError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}
