import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import EbookCapture

final class OptionsTests: XCTestCase {
  func testParsesAllFlags() throws {
    let o = try Options.parse([
      "-o", "notes/책", "--pages", "120", "--app", "chrome", "--region", "10  20\t300 400", "--margin", "0", "-f",
    ])
    XCTAssertEqual(o.output, "notes/책")
    XCTAssertEqual(o.pages, 120)
    XCTAssertEqual(o.app, .chrome)
    XCTAssertEqual(o.region, .fixed(Region(x: 10, y: 20, w: 300, h: 400)))
    XCTAssertEqual(try Options.parse(["--region", "select"]).region, .select)
    XCTAssertEqual(o.margin, 0)
    XCTAssertTrue(o.force)
    XCTAssertEqual(try Options.parse(["--output", "a", "--force"]).output, "a")
    XCTAssertTrue(try Options.parse(["-o", "a", "--resume"]).resume)
  }

  func testDefaults() throws {
    let o = try Options.parse([])
    XCTAssertNil(o.output)
    XCTAssertNil(o.region)
    XCTAssertFalse(o.force)
    XCTAssertEqual(o.margin, defaultMargin)
  }

  func testUsageErrors() {
    XCTAssertThrowsError(try Options.parse(["-o"])) { XCTAssertTrue($0 is UsageError) }
    XCTAssertThrowsError(try Options.parse(["--nope", "x"])) { XCTAssertTrue($0 is UsageError) }
  }

  func testRejectsMalformedNumbers() {
    for bad in ["0", "012", "-3", "1.5", "x", ""] {
      XCTAssertThrowsError(try Validate.pages(bad), bad)
    }
    for bad in ["1 2 3", "1 2 3 4 5", "1 2 3 x", "-1 2 3 4", "1 2 0 4", ""] {
      XCTAssertThrowsError(try Validate.region(bad), bad)
    }
    XCTAssertThrowsError(try Validate.margin("-3"))
    XCTAssertEqual(try Validate.pages("7"), 7)
    XCTAssertEqual(try Validate.margin("0"), 0)
  }

  func testAppSelectors() {
    XCTAssertEqual(AppTarget.resolve("1"), .library)
    XCTAssertEqual(AppTarget.resolve("library"), .library)
    XCTAssertEqual(AppTarget.resolve("교보도서관"), .library)
    // NFD spelling (as in macOS file names) is the same string in Swift
    XCTAssertEqual(AppTarget.resolve("교보도서관".decomposedStringWithCanonicalMapping), .library)
    XCTAssertEqual(AppTarget.resolve("2"), .chrome)
    XCTAssertEqual(AppTarget.resolve("chrome"), .chrome)
    XCTAssertNil(AppTarget.resolve("ebook"))
    XCTAssertNil(AppTarget.resolve("3"))
  }
}

final class OutputPathTests: XCTestCase {
  var root: URL!
  var home: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    home = root.appendingPathComponent("home")
    for dir in ["work/books", "home/Documents"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func resolve(_ input: String) throws -> OutputPath {
    try OutputPath.resolve(input, cwd: root.appendingPathComponent("work"), home: home)
  }

  func testBareNameGoesToCurrentFolderWithExtensionAdded() throws {
    let out = try resolve("linear-algebra")
    XCTAssertEqual(out.url.path, root.appendingPathComponent("work/linear-algebra.pdf").path)
    XCTAssertTrue(out.addedExtension)
    XCTAssertEqual(out.name, "linear-algebra")
  }

  func testExistingPDFExtensionIsKept() throws {
    XCTAssertFalse(try resolve("la.pdf").addedExtension)
    let upper = try resolve("la.PDF")
    XCTAssertFalse(upper.addedExtension)
    XCTAssertEqual(upper.url.lastPathComponent, "la.PDF")
  }

  func testOtherExtensionGetsPDFAppended() throws {
    let out = try resolve("la.png")
    XCTAssertEqual(out.url.lastPathComponent, "la.png.pdf")
    XCTAssertTrue(out.addedExtension)
  }

  func testRelativeAbsoluteAndTildePaths() throws {
    XCTAssertEqual(try resolve("books/la").url.path, root.appendingPathComponent("work/books/la.pdf").path)
    XCTAssertEqual(try resolve("../work/la.pdf").url.path, root.appendingPathComponent("work/la.pdf").path)
    let absolute = root.appendingPathComponent("home/Documents/x.pdf").path
    XCTAssertEqual(try resolve(absolute).url.path, absolute)
    XCTAssertEqual(try resolve("~/Documents/la").url.path, home.appendingPathComponent("Documents/la.pdf").path)
  }

  func testRejectsFoldersMissingFoldersAndStdout() {
    XCTAssertThrowsError(try resolve("books/"))
    XCTAssertThrowsError(try resolve("books"))  // an existing folder
    XCTAssertThrowsError(try resolve("~"))
    XCTAssertThrowsError(try resolve("missing/la"))
    XCTAssertThrowsError(try resolve("-"))
    XCTAssertThrowsError(try resolve(""))
  }
}

final class PrompterTests: XCTestCase {
  func prompter(_ answers: [String]) -> Prompter {
    var queue = answers[...]
    return Prompter(readLine: { queue.popFirst() })
  }

  func testNumbersRetryUntilValid() throws {
    XCTAssertEqual(try prompter(["zero", "0", "3"]).pages(), 3)
  }

  func testEmptyPageCountMeansUntilTheEnd() throws {
    XCTAssertNil(try prompter([""]).pages())
  }

  func testResumeDefaultsToYes() throws {
    let s = SessionState(
      output: URL(fileURLWithPath: "/tmp/pl.pdf"), app: .library, region: nil, margin: 10, maxPages: nil,
      savedPages: 3, keyPresses: 3)
    XCTAssertTrue(try prompter([""]).confirmResume(s))
    XCTAssertFalse(try prompter(["n"]).confirmResume(s))
  }

  func testAreaMenu() throws {
    XCTAssertEqual(try prompter(["9", "1"]).area(), .select)
    XCTAssertEqual(try prompter(["3"]).area(), .wholeWindow)
  }

  func testCustomRegionAsksEachValue() throws {
    // an invalid x, then a zero width, are asked again
    let r = try prompter(["2", "-5", "120", "80", "0", "900", "1200"]).area()
    XCTAssertEqual(r, .fixed(Region(x: 120, y: 80, w: 900, h: 1200)))
  }

  func testAppChoice() throws {
    XCTAssertEqual(try prompter(["3", " 2 "]).app(), .chrome)
  }

  func testOutputRetriesAfterBadPath() throws {
    let cwd = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let out = try prompter(["", "no/such/folder/x", "scan"]).output(in: cwd)
    XCTAssertEqual(out.url.lastPathComponent, "scan.pdf")
  }

  func testOverwriteDefaultsToNo() throws {
    let url = URL(fileURLWithPath: "/tmp/x.pdf")
    XCTAssertFalse(try prompter([""]).confirmOverwrite(url))
    XCTAssertFalse(try prompter(["n"]).confirmOverwrite(url))
    XCTAssertTrue(try prompter(["Y"]).confirmOverwrite(url))
  }

  func testEndOfInputFails() {
    XCTAssertThrowsError(try prompter([]).pages())
  }
}

final class RegionTests: XCTestCase {
  let window = CGRect(x: 100, y: 50, width: 800, height: 600)

  func testInset() throws {
    XCTAssertEqual(try Region.inset(window, margin: 10), Region(x: 110, y: 60, w: 780, h: 580))
    XCTAssertThrowsError(try Region.inset(window, margin: 300))
  }

  func testScreenRelativeToGlobal() {
    // A second screen placed left of and below the main one
    let r = Region(x: 10, y: 20, w: 300, h: 400)
    XCTAssertEqual(r.translated(by: CGPoint(x: -1512, y: 98)), Region(x: -1502, y: 118, w: 300, h: 400))
    XCTAssertEqual(r.translated(by: .zero), r)
  }

  func testPixelCropIsWindowRelativeAndScaled() throws {
    let r = Region(x: 110, y: 60, w: 200, h: 100)
    XCTAssertEqual(try r.pixelCrop(in: window, scale: 2), CGRect(x: 20, y: 20, width: 400, height: 200))
    XCTAssertEqual(try r.pixelCrop(in: window, scale: 1), CGRect(x: 10, y: 10, width: 200, height: 100))
  }

  func testClippedToWindow() {
    // 3 points past the bottom of a full-screen window on a notch MacBook
    let notch = CGRect(x: 0, y: 33, width: 1512, height: 949)
    XCTAssertEqual(Region(x: 90, y: 95, w: 1330, h: 890).clipped(to: notch), Region(x: 90, y: 95, w: 1330, h: 887))
    XCTAssertEqual(Region(x: 90, y: 95, w: 100, h: 100).clipped(to: notch), Region(x: 90, y: 95, w: 100, h: 100))
    XCTAssertNil(Region(x: 2000, y: 0, w: 10, h: 10).clipped(to: notch))
  }

  func testTrimKeepsAreasInsideAndRejectsOnesOutside() throws {
    let window = WindowInfo(id: 1, frame: CGRect(x: 0, y: 33, width: 1512, height: 949))
    XCTAssertEqual(
      try CaptureSession.trim(Region(x: 90, y: 95, w: 1330, h: 890), to: window, app: .chrome, note: false),
      Region(x: 90, y: 95, w: 1330, h: 887))
    XCTAssertThrowsError(
      try CaptureSession.trim(Region(x: 1500, y: 40, w: 100, h: 100), to: window, app: .chrome, note: false))
  }

  func testSelectionFromCocoaToScreenPoints() {
    // Cocoa: bottom-left origin. A selection 91 from the left and 105 from
    // the top of a 982-point-high screen, 877 high, starts at y = 0 in Cocoa.
    let cocoa = CGRect(x: 91, y: 0, width: 1330, height: 877)
    XCTAssertEqual(
      SelectionGeometry.cgRect(fromCocoa: cocoa, primaryHeight: 982), CGRect(x: 91, y: 105, width: 1330, height: 877))
  }

  func testDraggedWindowIsTheOneUnderTheSelection() {
    // Front to back: a normal Chrome window, then the viewer elsewhere
    let other = WindowInfo(id: 1, frame: CGRect(x: 0, y: 33, width: 700, height: 949))
    let viewer = WindowInfo(id: 2, frame: CGRect(x: 0, y: 33, width: 1512, height: 949))
    XCTAssertEqual(WindowInfo.first(containing: CGPoint(x: 1000, y: 500), in: [other, viewer])?.id, 2)
    XCTAssertEqual(WindowInfo.first(containing: CGPoint(x: 300, y: 500), in: [other, viewer])?.id, 1)
    XCTAssertNil(WindowInfo.first(containing: CGPoint(x: 3000, y: 500), in: [other, viewer]))
  }

  func testRegionOutsideWindowFails() {
    XCTAssertThrowsError(try Region(x: 0, y: 0, w: 50, h: 50).pixelCrop(in: window, scale: 1))
    XCTAssertThrowsError(try Region(x: 850, y: 60, w: 100, h: 100).pixelCrop(in: window, scale: 1))
  }
}

final class PageWaiterTests: XCTestCase {
  let waiter = PageWaiter(timeout: .milliseconds(500), interval: .milliseconds(10))

  func run(_ frames: [String], from previous: String = "A") async throws -> (String, Bool, Int) {
    var n = 0
    let r = try await waiter.waitForTurn(from: previous, same: ==) { () async -> String in
      defer { n += 1 }
      return frames[min(n, frames.count - 1)]
    }
    return (r.frame, r.turned, n)
  }

  func testTurnsAfterDelayThenSettles() async throws {
    let (frame, turned, polls) = try await run(["A", "A", "B", "B"])
    XCTAssertEqual(frame, "B")
    XCTAssertTrue(turned)
    XCTAssertEqual(polls, 4)
  }

  func testSkipsMidAnimationFrame() async throws {
    let (frame, turned, _) = try await run(["X", "B", "B"])
    XCTAssertEqual(frame, "B")
    XCTAssertTrue(turned)
  }

  func testTimesOutWhenPageNeverTurns() async throws {
    let (frame, turned, _) = try await run(["A"])
    XCTAssertEqual(frame, "A")
    XCTAssertFalse(turned)
  }

  func testStopThrowsInterrupted() async {
    do {
      _ = try await waiter.waitForTurn(from: "A", same: ==, grab: { "A" }, stop: { true })
      XCTFail("expected Interrupted")
    } catch {
      XCTAssertTrue(error is Interrupted)
    }
  }
}

final class CaptureLoopTests: XCTestCase {
  /// A fake reader: `pages` are the book; each turn shows the next page,
  /// or nothing new past the end. `failAt` makes that capture throw.
  final class FakeReader {
    let pages: [String]
    var index: Int
    var failAt: Int?
    var grabs = 0
    var turns = 0
    var saved: [(String, Int)] = []
    init(_ pages: [String], showing index: Int = 0, failAt: Int? = nil) {
      self.pages = pages
      self.index = index
      self.failAt = failAt
    }

    func loop(maxPages: Int?, start: CaptureStart = CaptureStart()) -> CaptureLoop<String> {
      var loop = CaptureLoop<String>(
        maxPages: maxPages, waiter: PageWaiter(timeout: .milliseconds(60), interval: .milliseconds(5)),
        same: ==,
        grab: { [self] in
          grabs += 1
          if grabs == failAt { throw CLIError("capture failed") }
          return pages[index]
        },
        turnPage: { [self] in
          turns += 1
          index = min(index + 1, pages.count - 1)
        },
        save: { [self] frame, n in saved.append((frame, n)) })
      loop.start = start
      loop.log = { _ in }
      return loop
    }

    var savedFrames: [String] { saved.map(\.0) }
    var savedNumbers: [Int] { saved.map(\.1) }
  }

  func testStopsAtThePageLimit() async {
    let reader = FakeReader(["1", "2", "3", "4"])
    let result = await reader.loop(maxPages: 2).run()
    XCTAssertEqual(result, .init(pages: 2, keyPresses: 1, outcome: .finished))
    XCTAssertEqual(reader.savedFrames, ["1", "2"])
    XCTAssertEqual(reader.savedNumbers, [1, 2])
  }

  func testStopsAtTheEndOfTheBookWithoutDuplicates() async {
    let reader = FakeReader(["1", "2", "3"])
    let result = await reader.loop(maxPages: 10).run()
    // The third press changed nothing, so it isn't counted
    XCTAssertEqual(result, .init(pages: 3, keyPresses: 2, outcome: .endOfBook))
    XCTAssertEqual(reader.savedFrames, ["1", "2", "3"])
  }

  func testNoLimitGoesUntilTheEnd() async {
    let result = await FakeReader(["1", "2", "3"]).loop(maxPages: nil).run()
    XCTAssertEqual(result, .init(pages: 3, keyPresses: 2, outcome: .endOfBook))
  }

  func testUnchangedPageWithAProblemIsAFailureNotTheEnd() async {
    let reader = FakeReader(["1", "2", "3"])
    var loop = reader.loop(maxPages: 10)
    loop.diagnose = { reader.saved.count == 3 ? "You switched to WezTerm while capturing." : nil }
    let result = await loop.run()
    XCTAssertEqual(result, .init(pages: 3, keyPresses: 2, outcome: .failed("You switched to WezTerm while capturing.")))
  }

  func testSlowPageGetsASecondWait() async {
    // The turn shows up only once the first wait has timed out, which the
    // loop announces in its log; no timing assumptions.
    var turns = 0
    var shown = "1"
    var loop = CaptureLoop<String>(
      maxPages: 2, waiter: PageWaiter(timeout: .milliseconds(60), interval: .milliseconds(5)),
      same: ==,
      grab: { shown },
      turnPage: { turns += 1 },
      save: { _, _ in })
    loop.log = { if $0.contains("waiting once more") { shown = "2" } }
    let result = await loop.run()
    XCTAssertEqual(result, .init(pages: 2, keyPresses: 1, outcome: .finished))
    XCTAssertEqual(turns, 1, "the key must not be pressed again")
  }

  func testFailureKeepsCountsAndExplainsIt() async {
    // grabs: 1 = page 1, 2-3 = page 2 settles, 4-5 = page 3 settles, 6 fails
    let reader = FakeReader(["1", "2", "3", "4"], failAt: 6)
    var loop = reader.loop(maxPages: 4)
    loop.diagnose = { "The Chrome window was closed." }
    let result = await loop.run()
    XCTAssertEqual(result.pages, 3)
    XCTAssertEqual(result.keyPresses, 3, "the press before the failed capture counts")
    XCTAssertEqual(result.outcome, .failed("The Chrome window was closed. (capture failed)"))
  }

  func testStopRequestInterrupts() async {
    let reader = FakeReader(["1", "2", "3"])
    var loop = reader.loop(maxPages: 3)
    loop.stop = { reader.saved.count == 1 }
    let result = await loop.run()
    XCTAssertEqual(result, .init(pages: 1, keyPresses: 0, outcome: .interrupted))
  }

  func testResumeTurnsFirstWhenTheLastSavedPageIsShown() async {
    // 2 pages saved, 1 press: page 2 is on screen
    let reader = FakeReader(["1", "2", "3", "4"], showing: 1)
    let result = await reader.loop(maxPages: 4, start: .init(savedPages: 2, keyPresses: 1, turnFirst: true)).run()
    XCTAssertEqual(reader.savedFrames, ["3", "4"])
    XCTAssertEqual(reader.savedNumbers, [3, 4])
    XCTAssertEqual(result, .init(pages: 4, keyPresses: 3, outcome: .finished))
  }

  func testResumeCapturesDirectlyWhenTheNextPageIsShown() async {
    // 2 pages saved, 2 presses: page 3 is already on screen
    let reader = FakeReader(["1", "2", "3", "4"], showing: 2)
    let result = await reader.loop(maxPages: nil, start: .init(savedPages: 2, keyPresses: 2)).run()
    XCTAssertEqual(reader.savedFrames, ["3", "4"])
    XCTAssertEqual(reader.savedNumbers, [3, 4])
    XCTAssertEqual(reader.turns, 2, "one turn to page 4, one that finds the end")
    XCTAssertEqual(result, .init(pages: 4, keyPresses: 3, outcome: .endOfBook))
  }

  func testFailureReasons() {
    func explain(_ exists: Bool, _ onScreen: Bool, _ front: Bool) -> String? {
      FailureReason.explain(
        windowExists: exists, onScreen: onScreen, readerIsFrontmost: front, frontmostName: "WezTerm", reader: "Chrome")
    }
    XCTAssertNil(explain(true, true, true))
    XCTAssertEqual(explain(false, false, false), "The Chrome window was closed.")
    XCTAssertEqual(explain(true, true, false), "You switched to WezTerm while capturing.")
    XCTAssertEqual(
      explain(true, false, true),
      "The Chrome window is no longer on screen (minimized, or its full-screen Space was left).")
    XCTAssertEqual(
      explain(true, false, false),
      "You switched to WezTerm while capturing. "
        + "The Chrome window is no longer on screen (minimized, or its full-screen Space was left).")
  }
}

final class SessionStateTests: XCTestCase {
  func state(saved: Int, presses: Int) -> SessionState {
    SessionState(
      output: URL(fileURLWithPath: "/tmp/pl.pdf"), app: .chrome, region: Region(x: 1, y: 2, w: 3, h: 4),
      margin: 10, maxPages: nil, savedPages: saved, keyPresses: presses)
  }

  func testRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = state(saved: 328, presses: 328)
    try s.write(to: dir)
    let read = try XCTUnwrap(SessionState.read(from: dir))
    XCTAssertEqual(read, s)
    XCTAssertEqual(read.app, .chrome)
    XCTAssertEqual(read.captureRegion, Region(x: 1, y: 2, w: 3, h: 4))
    XCTAssertNil(SessionState.read(from: dir.appendingPathComponent("missing")))
  }

  func testResumePointFromCounts() throws {
    XCTAssertEqual(try state(saved: 328, presses: 327).resumeStart(), CaptureStart(savedPages: 328, keyPresses: 327, turnFirst: true))
    XCTAssertEqual(try state(saved: 328, presses: 328).resumeStart(), CaptureStart(savedPages: 328, keyPresses: 328, turnFirst: false))
    XCTAssertThrowsError(try state(saved: 328, presses: 300).resumeStart())
    XCTAssertThrowsError(try state(saved: 328, presses: 329).resumeStart())
  }
}

final class LauncherTests: XCTestCase {
  func testFindsTheFirstAppAmongParents() {
    // 500 ebook-capture → 400 zsh → 300 wezterm-gui (app) → 1 launchd
    let parents: [pid_t: pid_t] = [500: 400, 400: 300, 300: 1]
    XCTAssertEqual(Launcher.appAncestor(of: 500, parent: { parents[$0] }, isApp: { $0 == 300 }), 300)
  }

  func testNoAppUnderTmux() {
    // 500 ebook-capture → 400 zsh → 350 tmux server → 1 launchd
    let parents: [pid_t: pid_t] = [500: 400, 400: 350, 350: 1]
    XCTAssertNil(Launcher.appAncestor(of: 500, parent: { parents[$0] }, isApp: { _ in false }))
  }
}

final class PDFWriterTests: XCTestCase {
  var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  func testMergesPNGsInNameOrder() throws {
    // Written out of order; widths encode the expected page order
    for (name, width) in [("page-00002.png", 20), ("page-00001.png", 10), ("page-00003.png", 30)] {
      try writePNG(width: width, to: dir.appendingPathComponent(name))
    }
    let out = dir.appendingPathComponent("out.pdf")
    XCTAssertEqual(try PDFWriter.merge(pngsIn: dir, to: out), 3)
    XCTAssertEqual(try pageWidths(out), [10, 20, 30])
    XCTAssertFalse(FileManager.default.fileExists(atPath: out.path + ".partial"))
  }

  func testReplacesExistingOutput() throws {
    try writePNG(width: 10, to: dir.appendingPathComponent("page-00001.png"))
    let out = dir.appendingPathComponent("out.pdf")
    try Data("old".utf8).write(to: out)
    try PDFWriter.merge(pngsIn: dir, to: out)
    XCTAssertEqual(try pageWidths(out), [10])
  }

  func testEmptyFolderFails() {
    XCTAssertThrowsError(try PDFWriter.merge(pngsIn: dir, to: dir.appendingPathComponent("x.pdf")))
  }

  private func pageWidths(_ url: URL) throws -> [CGFloat] {
    let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))
    return (0..<doc.numberOfPages).map { doc.page(at: $0 + 1)!.getBoxRect(.mediaBox).width }
  }

  private func writePNG(width: Int, to url: URL) throws {
    let ctx = CGContext(
      data: nil, width: width, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
  }
}
