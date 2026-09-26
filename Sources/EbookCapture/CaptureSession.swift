import AppKit
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
  /// Total page limit; nil = until the end of the book.
  public var pages: Int?
  public var app: AppTarget
  /// Fixed areas are relative to the screen the app window is on.
  public var area: AreaChoice
  public var margin: Int
  public var pageTimeoutSeconds: Int
  public var tempRoot: URL
  /// Set when continuing an unfinished capture (`--resume`).
  public var resume: SessionState?

  /// The temporary folder holding this output's pages.
  public static func folder(for output: OutputPath, in tempRoot: URL) -> URL {
    tempRoot.appendingPathComponent(output.name)
  }

  /// Where an unfinished capture picks up, after checking that its folder
  /// still holds the pages its progress says it saved.
  public static func resumePoint(_ state: SessionState, dir: URL) throws -> CaptureStart {
    let start = try state.resumeStart()
    let pngs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
      .filter { $0.hasSuffix(".png") }
    guard pngs.count == start.savedPages else {
      throw CLIError("the unfinished capture in \(dir.path) should have \(start.savedPages) pages "
        + "but has \(pngs.count). Start over without --resume.")
    }
    return start
  }

  /// Returns the process exit code: 0, 130 when interrupted, 1 when
  /// capturing failed (the pages captured before the failure are still saved).
  /// The caller has already confirmed overwriting an existing output.
  public func run() async throws -> Int32 {
    let fm = FileManager.default
    let dir = Self.folder(for: output, in: tempRoot)
    // Come back here at the end, whatever gets clicked in the meantime
    let terminal = Launcher.terminalBundleID(frontmostAtStart: AppControl.frontmost, reader: app)

    let start = try resume.map { try Self.resumePoint($0, dir: dir) } ?? CaptureStart()

    guard let pid = AppControl.runningPID(of: app) else {
      throw CLIError("\(app.label) is not running. Open the book in it first.")
    }
    try Permissions.check()
    try AppControl.activate(app)
    try await Task.sleep(for: .milliseconds(1500))

    // The window to capture and the area in global coordinates. Fixed areas
    // are relative to the window's screen (as Cmd+Shift+4 shows them).
    let window: WindowInfo
    let captureArea: Region
    switch area {
    case .select:
      print("Drag over the page to capture (Esc to cancel)...")
      guard let selected = try SelectionHelper.select() else {
        throw CLIError("area selection cancelled. Nothing was captured.")
      }
      // Capture the window that was dragged over: with several windows (a
      // full-screen viewer next to another Chrome window) it may not be the
      // one that came to the front
      let center = CGPoint(x: selected.midX, y: selected.midY)
      guard let dragged = WindowInfo.first(containing: center, in: WindowInfo.onScreen(of: pid)) else {
        throw CLIError("the selected area isn't on a \(app.label) window")
      }
      window = dragged
      captureArea = try Self.trim(
        Region(x: Int(selected.minX), y: Int(selected.minY), w: Int(selected.width), h: Int(selected.height)),
        to: window, app: app, note: false)
    case .fixed(let region):
      guard let front = WindowInfo.front(of: pid) else { throw CLIError("cannot find a \(app.label) window") }
      window = front
      captureArea = try Self.trim(region.translated(by: Self.screenOrigin(of: window)), to: window, app: app, note: true)
    case .wholeWindow:
      guard let front = WindowInfo.front(of: pid) else { throw CLIError("cannot find a \(app.label) window") }
      window = front
      captureArea = try Region.inset(window.frame, margin: margin)
    }
    // What the user would type to get this area again, and what --resume uses
    let screen = Self.screenOrigin(of: window)
    let resolvedRegion = captureArea.translated(by: CGPoint(x: -screen.x, y: -screen.y))
    print("Capture area (x y w h): \(resolvedRegion) (reuse with --region \"\(resolvedRegion)\")")
    let capturer = try await WindowCapturer(window: window, region: captureArea)

    if resume == nil {
      // A leftover folder from an earlier run would mix its pages into this
      // PDF. It may hold the only copy of a failed run's pages, so it goes
      // to the Trash rather than being deleted.
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
    } else {
      print("Continuing from page \(start.savedPages + 1).")
    }
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
    loop.start = start
    loop.stop = { InterruptSignal.requested }
    loop.diagnose = {
      let status = WindowInfo.status(of: window.id)
      let front = AppControl.frontmost
      return FailureReason.explain(
        windowExists: status.exists, onScreen: status.onScreen,
        readerIsFrontmost: front?.processIdentifier == pid, frontmostName: front?.localizedName,
        reader: app.label)
    }
    let result = await loop.run()

    let exitCode = report(result)
    let saved: Region? = area == .wholeWindow ? nil : resolvedRegion
    let code = finish(result, exitCode: exitCode, dir: dir, region: saved)
    await Notifier.finished(success: code == 0, returnTo: terminal)
    return code
  }

  /// Top-left corner (global points) of the screen a window is on.
  static func screenOrigin(of window: WindowInfo) -> CGPoint {
    Displays.origin(containing: CGPoint(x: window.frame.midX, y: window.frame.midY))
  }

  /// The part of a global area inside the window. An area slightly past the
  /// window (a few points too far with Cmd+Shift+4) is trimmed; one that
  /// barely overlaps it is an error that says where the window is.
  static func trim(_ area: Region, to window: WindowInfo, app: AppTarget, note: Bool) throws -> Region {
    let screen = screenOrigin(of: window)
    let toScreen = CGPoint(x: -screen.x, y: -screen.y)
    guard let inside = area.clipped(to: window.frame), inside.w >= 20, inside.h >= 20 else {
      let f = window.frame.offsetBy(dx: toScreen.x, dy: toScreen.y)
      throw CLIError("capture area \(area.translated(by: toScreen)) is outside the \(app.label) window, "
        + "which spans x \(Int(f.minX))–\(Int(f.maxX)), y \(Int(f.minY))–\(Int(f.maxY)) on its screen")
    }
    if inside != area, note {
      print("Note: capture area trimmed to the \(app.label) window: \(inside.translated(by: toScreen))")
    }
    return inside
  }

  private func report(_ result: CaptureLoop<Frame>.Result) -> Int32 {
    switch result.outcome {
    case .finished:
      return 0
    case .endOfBook:
      print("Reached the end of the book: the page didn't change after 2 waits of \(pageTimeoutSeconds)s.")
      return 0
    case .interrupted:
      print("\nInterrupted.")
      return 130
    case .failed(let message):
      printError("Error: capturing stopped at page \(result.pages + 1): \(message)")
      return 1
    }
  }

  /// Turns the captured pages into the PDF. A finished run removes the
  /// temporary folder; a run that stopped early keeps it, with its progress,
  /// so it can be resumed.
  private func finish(_ result: CaptureLoop<Frame>.Result, exitCode: Int32, dir: URL, region: Region?) -> Int32 {
    let fm = FileManager.default
    let done = exitCode == 0
    guard result.pages > 0 else {
      try? fm.removeItem(at: dir)
      return exitCode
    }
    // Whatever stopped the loop, the pages captured so far become the PDF
    do {
      try PDFWriter.merge(pngsIn: dir, to: output.url)
    } catch {
      printError("Error: could not create the PDF (\(error)). The captured pages are kept in \(dir.path)")
      return 1
    }
    let count = "\(result.pages) page\(result.pages == 1 ? "" : "s")"
    if done {
      try? fm.removeItem(at: dir)
      print("PDF created with \(count): \(output.url.path)")
      print("Done: \(output.url.path)")
      return 0
    }

    let state = SessionState(
      output: output.url, app: app, region: region, margin: margin, maxPages: pages,
      savedPages: result.pages, keyPresses: result.keyPresses)
    do {
      try state.write(to: dir)
    } catch {
      print("Saved \(count) to \(output.url.path). (Could not save progress for --resume: \(error))")
      return exitCode
    }
    print("""
      Saved \(count) to \(output.url.path).
      To continue from page \(result.pages + 1), leave the reader on its current page and run:
        ebook-capture -o '\(output.url.path)' --resume
      (The captured pages wait in \(dir.path); macOS may clear it after a few days.)
      """)
    return exitCode
  }
}

func printError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}
