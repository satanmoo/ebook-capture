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
    XCTAssertEqual(o.region, Region(x: 10, y: 20, w: 300, h: 400))
    XCTAssertEqual(o.margin, 0)
    XCTAssertTrue(o.force)
    XCTAssertEqual(try Options.parse(["--output", "a", "--force"]).output, "a")
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

  func testWholeWindowChoice() throws {
    XCTAssertNil(try prompter(["9", "2"]).region())
  }

  func testCustomRegionAsksEachValue() throws {
    // an invalid x, then a zero width, are asked again
    let r = try prompter(["1", "-5", "120", "80", "0", "900", "1200"]).region()
    XCTAssertEqual(r, Region(x: 120, y: 80, w: 900, h: 1200))
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
    var index = 0
    var failAt: Int?
    var grabs = 0
    var saved: [String] = []
    init(_ pages: [String], failAt: Int? = nil) { self.pages = pages; self.failAt = failAt }

    func loop(maxPages: Int?) -> CaptureLoop<String> {
      var loop = CaptureLoop<String>(
        maxPages: maxPages, waiter: PageWaiter(timeout: .milliseconds(60), interval: .milliseconds(5)),
        same: ==,
        grab: { [unowned self] in
          grabs += 1
          if grabs == failAt { throw CLIError("capture failed") }
          return pages[index]
        },
        turnPage: { [unowned self] in index = min(index + 1, pages.count - 1) },
        save: { [unowned self] frame, n in
          XCTAssertEqual(n, saved.count + 1)
          saved.append(frame)
        })
      loop.log = { _ in }
      return loop
    }
  }

  func testStopsAtThePageLimit() async {
    let reader = FakeReader(["1", "2", "3", "4"])
    let result = await reader.loop(maxPages: 2).run()
    XCTAssertEqual(result, .init(pages: 2, outcome: .finished))
    XCTAssertEqual(reader.saved, ["1", "2"])
  }

  func testStopsAtTheEndOfTheBookWithoutDuplicates() async {
    let reader = FakeReader(["1", "2", "3"])
    let result = await reader.loop(maxPages: 10).run()
    XCTAssertEqual(result, .init(pages: 3, outcome: .endOfBook))
    XCTAssertEqual(reader.saved, ["1", "2", "3"])
  }

  func testNoLimitGoesUntilTheEnd() async {
    let reader = FakeReader(["1", "2", "3"])
    let result = await reader.loop(maxPages: nil).run()
    XCTAssertEqual(result, .init(pages: 3, outcome: .endOfBook))
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
    XCTAssertEqual(result, .init(pages: 2, outcome: .finished))
    XCTAssertEqual(turns, 1, "the key must not be pressed again")
  }

  func testFailureKeepsTheCountOfSavedPages() async {
    let reader = FakeReader(["1", "2", "3", "4"], failAt: 6)
    let result = await reader.loop(maxPages: 4).run()
    XCTAssertEqual(result.pages, reader.saved.count)
    XCTAssertGreaterThan(result.pages, 0)
    XCTAssertEqual(result.outcome, .failed("capture failed"))
  }

  func testStopRequestInterrupts() async {
    let reader = FakeReader(["1", "2", "3"])
    var loop = reader.loop(maxPages: 3)
    loop.stop = { reader.saved.count == 1 }
    let result = await loop.run()
    XCTAssertEqual(result, .init(pages: 1, outcome: .interrupted))
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
