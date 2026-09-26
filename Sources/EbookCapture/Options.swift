import Foundation

public struct CLIError: Error, CustomStringConvertible, Equatable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// A malformed command line: printed together with the usage text.
public struct UsageError: Error, CustomStringConvertible, Equatable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

public let defaultMargin = 10

/// `--region`: a fixed area, or `select` to drag one with the mouse.
public enum AreaOption: Equatable {
  case fixed(Region)
  case select
}

/// The capture area a run uses.
public enum AreaChoice: Equatable {
  case wholeWindow
  case fixed(Region)
  case select
}

/// Validation rules shared by flags and interactive prompts.
public enum Validate {
  public static func pages(_ text: String) throws -> Int {
    guard let n = wholeNumber(text), n > 0 else {
      throw CLIError("page count must be a whole number greater than 0 (got: \(text))")
    }
    return n
  }

  public static func region(_ text: String) throws -> Region {
    let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    let v = parts.compactMap(wholeNumber)
    guard parts.count == 4, v.count == 4, v[2] > 0, v[3] > 0 else {
      throw CLIError("region must be four whole numbers \"x y w h\" with w and h above 0 (got: \(text))")
    }
    return Region(x: v[0], y: v[1], w: v[2], h: v[3])
  }

  public static func margin(_ text: String) throws -> Int {
    guard let n = wholeNumber(text) else {
      throw CLIError("margin must be a whole number, 0 or more (got: \(text))")
    }
    return n
  }

  /// Digits only: no sign, no leading zero (except "0" itself).
  static func wholeNumber(_ s: String) -> Int? {
    guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }),
      s == "0" || !s.hasPrefix("0")
    else { return nil }
    return Int(s)
  }
}

/// Where the PDF goes. Follows the usual `-o` conventions (a path relative
/// to the current directory; missing folders are an error), except that
/// `.pdf` is appended when missing: without it Finder and iPad note apps
/// don't recognize the file as a PDF.
public struct OutputPath: Equatable {
  public let input: String
  public let url: URL
  public let addedExtension: Bool

  /// File name without the extension; names the temporary folder.
  public var name: String { url.deletingPathExtension().lastPathComponent }

  public static func resolve(
    _ input: String, cwd: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> OutputPath {
    guard !input.isEmpty else { throw CLIError("output file name cannot be empty") }
    guard input != "-" else { throw CLIError("writing the PDF to standard output is not supported") }
    guard !input.hasSuffix("/") else { throw CLIError("output must be a file, not a folder: \(input)") }

    // Flags get ~ expanded by the shell; interactive answers don't
    var path = input
    if path == "~" || path.hasPrefix("~/") { path = home.path + path.dropFirst() }
    var url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : cwd.appendingPathComponent(path))
      .standardizedFileURL

    let fm = FileManager.default
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
      throw CLIError("output must be a file, not a folder: \(url.path)")
    }
    let added = url.pathExtension.lowercased() != "pdf"
    if added { url.appendPathExtension("pdf") }

    let folder = url.deletingLastPathComponent()
    guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
      throw CLIError("folder does not exist: \(folder.path)")
    }
    return OutputPath(input: input, url: url, addedExtension: added)
  }
}

public struct Options: Equatable {
  public var output: String?
  public var pages: Int?
  public var app: AppTarget?
  public var region: AreaOption?
  public var margin = defaultMargin
  public var force = false
  public var resume = false
  public var help = false
  public var version = false

  public init() {}

  /// Parses and validates flags up front (fail fast, before any prompts).
  public static func parse(_ args: [String]) throws -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) throws -> String {
      guard i + 1 < args.count else { throw UsageError("\(flag) needs a value") }
      i += 1
      return args[i]
    }
    while i < args.count {
      let flag = args[i]
      switch flag {
      case "-o", "--output": o.output = try value(flag)
      case "--pages": o.pages = try Validate.pages(try value(flag))
      case "--region":
        let v = try value(flag)
        o.region = v == "select" ? .select : .fixed(try Validate.region(v))
      case "--margin": o.margin = try Validate.margin(try value(flag))
      case "--app":
        let v = try value(flag)
        guard let app = AppTarget.resolve(v) else {
          throw CLIError("unknown app: \(v) (use 1 or library, 2 or chrome)")
        }
        o.app = app
      case "-f", "--force": o.force = true
      case "--resume": o.resume = true
      case "-h", "--help": o.help = true
      case "--version": o.version = true
      default: throw UsageError("unknown option: \(flag)")
      }
      i += 1
    }
    return o
  }
}

public let usage = """
  ebook-capture: capture ebook pages from 교보도서관 or a Chrome web viewer into one PDF

  Usage:
    ebook-capture -o FILE --app APP [--pages N] [--region select | "x y w h" | --margin PX] [-f]
    ebook-capture -o FILE --resume

  Options:
    -o, --output FILE   PDF to write: a name or a path (.pdf is added if missing)
    --pages N           stop after N captures. Default: until the end of the book
                        (the page stops changing). In two-page view one capture
                        holds two pages, so N is half the page count
    --app APP           1 or library (교보도서관), 2 or chrome (Chrome web viewer)
    --region select     drag over the page with the mouse to choose the area
    --region "x y w h"  capture area, measured from the top-left corner of the
                        screen the app is on (Cmd+Shift+4 shows these numbers).
                        An area slightly past the window is trimmed to it.
                        Default: the whole app window minus --margin
    --margin PX         inset for whole-window capture (default 10)
    -f, --force         overwrite FILE without asking
    --resume            continue an unfinished capture of FILE (after Ctrl-C or
                        an error) from the next page. Leave the reader on its
                        page until then
    --version           print the version
    -h, --help          show this help

  Anything not given as a flag is asked interactively.

  Environment:
    EBOOK_CAPTURE_APP           capture another running app (name or bundle ID)
    EBOOK_CAPTURE_PAGE_TIMEOUT  seconds to wait for each page turn (default 5)
  """
