import Foundation

/// Where a capture run starts. A fresh run has saved nothing and pressed
/// nothing; a resumed one continues the counts.
public struct CaptureStart: Equatable {
  public var savedPages = 0
  public var keyPresses = 0
  /// Resume only: the last saved page is still on screen, so turn first.
  public var turnFirst = false

  public init(savedPages: Int = 0, keyPresses: Int = 0, turnFirst: Bool = false) {
    self.savedPages = savedPages
    self.keyPresses = keyPresses
    self.turnFirst = turnFirst
  }
}

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
    /// Pages saved in total, including those saved before a resume.
    public let pages: Int
    /// → presses in total, including those before a resume.
    public let keyPresses: Int
    public let outcome: Outcome
  }

  /// Total page limit (counting pages saved before a resume); nil = until
  /// the end of the book.
  public var maxPages: Int?
  public var start = CaptureStart()
  public var waiter: PageWaiter
  public var same: (Frame, Frame) -> Bool
  public var grab: () async throws -> Frame
  public var turnPage: () throws -> Void
  /// Called with each new page and its 1-based number.
  public var save: (Frame, Int) throws -> Void
  /// Why capturing can't go on (window closed, off screen, another app in
  /// front), or nil when the reader looks fine. Asked when a capture throws
  /// and before an unchanged page is taken as the end of the book.
  public var diagnose: () -> String? = { nil }
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
    var saved = start.savedPages
    var presses = start.keyPresses
    var previous: Frame?
    let total = maxPages.map(String.init) ?? "?"
    do {
      if start.turnFirst {
        // The last saved page is on screen; it becomes the frame the next
        // turn is measured against.
        previous = try await grab()
      }
      while saved < (maxPages ?? .max) {
        if stop() { throw Interrupted() }
        let frame: Frame
        if let previous {
          try turnPage()
          presses += 1
          var result = try await waiter.waitForTurn(from: previous, same: same, grab: grab, stop: stop)
          if !result.turned {
            // A slow page gets a second wait. Pressing again instead could
            // skip a page that was only late, so the key is not repeated.
            log("Page \(saved + 1) hasn't changed yet; waiting once more...")
            result = try await waiter.waitForTurn(from: previous, same: same, grab: grab, stop: stop)
          }
          if !result.turned {
            // The page never turned, so that press didn't count
            presses -= 1
            // A reader that lost focus or went off screen also shows the
            // same page forever; that's a failure, not the end of the book.
            if let problem = diagnose() {
              return Result(pages: saved, keyPresses: presses, outcome: .failed(problem))
            }
            // Nothing left to turn. The duplicate is not saved.
            return Result(pages: saved, keyPresses: presses, outcome: .endOfBook)
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
      return Result(pages: saved, keyPresses: presses, outcome: .finished)
    } catch {
      // Ctrl-C also hits child processes (open), so any failure after the
      // signal counts as an interruption
      if error is Interrupted || stop() {
        return Result(pages: saved, keyPresses: presses, outcome: .interrupted)
      }
      let message = diagnose().map { "\($0) (\(error))" } ?? "\(error)"
      return Result(pages: saved, keyPresses: presses, outcome: .failed(message))
    }
  }
}

/// Why a capture probably failed, from what can be observed afterwards.
public enum FailureReason {
  public static func explain(
    windowExists: Bool, onScreen: Bool, readerIsFrontmost: Bool, frontmostName: String?, reader: String
  ) -> String? {
    guard windowExists else { return "The \(reader) window was closed." }
    var reasons: [String] = []
    if !readerIsFrontmost {
      reasons.append("You switched to \(frontmostName ?? "another app") while capturing.")
    }
    if !onScreen {
      reasons.append("The \(reader) window is no longer on screen (minimized, or its full-screen Space was left).")
    }
    return reasons.isEmpty ? nil : reasons.joined(separator: " ")
  }
}
