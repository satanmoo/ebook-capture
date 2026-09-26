import Foundation

/// Asks for whatever was not given as a flag. Every question repeats until
/// the answer is valid.
public struct Prompter {
  private let readLine: () -> String?

  public init(readLine: @escaping () -> String? = { Swift.readLine() }) {
    self.readLine = readLine
  }

  private func ask(_ question: String) throws -> String {
    print(question, terminator: "")
    fflush(stdout)
    guard let answer = readLine() else { throw CLIError("input ended before all questions were answered") }
    return answer.trimmingCharacters(in: .whitespaces)
  }

  public func output(in cwd: URL) throws -> OutputPath {
    while true {
      let answer = try ask("Output PDF name or path (a bare name is saved in \(cwd.path)): ")
      do {
        return try OutputPath.resolve(answer, cwd: cwd)
      } catch let e as CLIError {
        print("Error: \(e)")
      }
    }
  }

  /// nil = until the end of the book.
  public func pages() throws -> Int? {
    while true {
      let answer = try ask("Number of pages to capture (press Enter to go until the end of the book): ")
      if answer.isEmpty { return nil }
      if let n = Validate.wholeNumber(answer), n > 0 { return n }
      print("Enter a whole number greater than 0, or press Enter.")
    }
  }

  /// nil = the whole window minus the margin.
  public func region() throws -> Region? {
    while true {
      print("Capture area:")
      print("  1) Custom (x, y, width, height)")
      print("  2) Whole window")
      switch try ask("Choose 1 or 2: ") {
      case "1": return try customRegion()
      case "2": return nil
      default: print("Choose 1 or 2.")
      }
    }
  }

  private func customRegion() throws -> Region {
    print("""

      Tip: Press Cmd+Shift+4 to see screen coordinates.
        - The crosshair shows the cursor position (x, y). Hover over the top-left corner of the page.
        - Drag to the bottom-right corner to see the width and height.
        - Press Esc to cancel without taking a screenshot.

      """)
    let x = try number("x (distance from the left edge): ", minimum: 0)
    let y = try number("y (distance from the top edge): ", minimum: 0)
    let w = try number("Width: ", minimum: 1)
    let h = try number("Height: ", minimum: 1)
    return Region(x: x, y: y, w: w, h: h)
  }

  private func number(_ question: String, minimum: Int) throws -> Int {
    while true {
      if let n = Validate.wholeNumber(try ask(question)), n >= minimum { return n }
      print(minimum == 0 ? "Enter a whole number (0 or more)." : "Enter a whole number greater than 0.")
    }
  }

  public func app() throws -> AppTarget {
    while true {
      switch try ask("Reader app — 1) 교보도서관  2) Chrome: ") {
      case "1": return .library
      case "2": return .chrome
      default: print("Choose 1 or 2.")
      }
    }
  }

  /// Default yes: continuing is what an interrupted user usually wants.
  public func confirmResume(_ state: SessionState) throws -> Bool {
    let answer = try ask(
      "Found \(state.savedPages) pages from an unfinished capture of \(state.output). "
        + "Continue from page \(state.savedPages + 1)? [Y/n] ")
    return !["n", "no"].contains(answer.lowercased())
  }

  /// ffmpeg-style: anything but y/yes keeps the existing file.
  public func confirmOverwrite(_ url: URL) throws -> Bool {
    let answer = try ask("File '\(url.path)' already exists. Overwrite? [y/N] ")
    return ["y", "yes"].contains(answer.lowercased())
  }

  /// Chrome has many windows and tabs; the page-turn key goes to whatever
  /// has focus. Waits for Enter only on a terminal (automated runs pipe stdin).
  public func chromeNotice(waitForEnter: Bool) {
    print("""
      Before capturing from Chrome:
        1) Make the viewer the active tab of your most recently used Chrome window.
        2) Click once on the page. If the address bar has focus, → won't turn pages.
        3) Whole-window capture includes the tab bar and address bar;
           choose a custom area (or --region) to capture only the page.
        4) Don't touch the keyboard or mouse while capturing.
      """)
    if waitForEnter {
      print("Press Enter when ready... ", terminator: "")
      fflush(stdout)
      _ = readLine()
    }
  }
}
