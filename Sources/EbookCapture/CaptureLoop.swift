import Foundation

/// The page loop, with screen access passed in as closures so its stopping
/// rules can be tested: capture the first page, then turn and capture until
/// the page limit, the end of the book, Ctrl-C, or an error.
public struct CaptureLoop<Frame> {
  public enum Outcome: Equatable {
    case finished      // captured `maxPages` pages
    case endOfBook     // a turn left the page unchanged twice in a row
    case interrupted
    case failed(String)
  }

  public struct Result: Equatable {
    public let pages: Int
    public let outcome: Outcome
  }

  /// nil = keep going until the end of the book.
  public var maxPages: Int?
  public var waiter: PageWaiter
  public var same: (Frame, Frame) -> Bool
  public var grab: () async throws -> Frame
  public var turnPage: () throws -> Void
  /// Called with each new page and its 1-based number.
  public var save: (Frame, Int) throws -> Void
  public var stop: () -> Bool = { false }
  public var log: (String) -> Void = { print($0) }

  public init(
    maxPages: Int?, waiter: PageWaiter, same: @escaping (Frame, Frame) -> Bool,
    grab: @escaping () async throws -> Frame, turnPage: @escaping () throws -> Void,
    save: @escaping (Frame, Int) throws -> Void
  ) {
    self.maxPages = maxPages
    self.waiter = waiter
    self.same = same
    self.grab = grab
    self.turnPage = turnPage
    self.save = save
  }

  public func run() async -> Result {
    var saved = 0
    var previous: Frame?
    let total = maxPages.map(String.init) ?? "?"
    do {
      while saved < (maxPages ?? .max) {
        if stop() { throw Interrupted() }
        let frame: Frame
        if let previous {
          try turnPage()
          var result = try await waiter.waitForTurn(from: previous, same: same, grab: grab, stop: stop)
          if !result.turned {
            // A slow page gets a second wait. Pressing again instead could
            // skip a page that was only late, so the key is not repeated.
            log("Page \(saved + 1) hasn't changed yet; waiting once more...")
            result = try await waiter.waitForTurn(from: previous, same: same, grab: grab, stop: stop)
            // Still the same page: nothing left to turn. The duplicate is
            // not saved.
            guard result.turned else { return Result(pages: saved, outcome: .endOfBook) }
          }
          frame = result.frame
        } else {
          frame = try await grab()
        }
        try save(frame, saved + 1)
        saved += 1
        previous = frame
        log("[\(saved)/\(total)]")
      }
      return Result(pages: saved, outcome: .finished)
    } catch {
      // Ctrl-C also hits child processes (open), so any failure after the
      // signal counts as an interruption
      if error is Interrupted || stop() { return Result(pages: saved, outcome: .interrupted) }
      return Result(pages: saved, outcome: .failed("\(error)"))
    }
  }
}
