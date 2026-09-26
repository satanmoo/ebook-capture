import Foundation

/// Progress of an unfinished capture, kept next to its pages so that
/// `--resume` can carry on. Written only when a run stops early (Ctrl-C or
/// an error); a finished run deletes the whole folder.
public struct SessionState: Codable, Equatable {
  public var output: String
  public var appBundleID: String
  public var appLabel: String
  /// Screen-relative "x y w h"; nil = whole window minus `margin`.
  public var region: [Int]?
  public var margin: Int
  public var maxPages: Int?
  public var savedPages: Int
  public var keyPresses: Int

  public static let fileName = "session.json"

  public init(
    output: URL, app: AppTarget, region: Region?, margin: Int, maxPages: Int?, savedPages: Int, keyPresses: Int
  ) {
    self.output = output.path
    self.appBundleID = app.bundleID
    self.appLabel = app.label
    self.region = region.map { [$0.x, $0.y, $0.w, $0.h] }
    self.margin = margin
    self.maxPages = maxPages
    self.savedPages = savedPages
    self.keyPresses = keyPresses
  }

  public var app: AppTarget { AppTarget(bundleID: appBundleID, label: appLabel) }

  public var captureRegion: Region? {
    guard let r = region, r.count == 4 else { return nil }
    return Region(x: r[0], y: r[1], w: r[2], h: r[3])
  }

  public static func read(from dir: URL) -> SessionState? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
    return try? JSONDecoder().decode(SessionState.self, from: data)
  }

  public func write(to dir: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName))
  }

  /// Where to pick up, from the counts alone. Counting from the page the
  /// capture started on, the reader shows page `1 + keyPresses`:
  /// - one press fewer than pages saved: the last saved page is on screen,
  ///   so turn first;
  /// - as many presses as pages: the next page is already on screen.
  /// Anything else means the numbers don't add up.
  public func resumeStart() throws -> CaptureStart {
    switch keyPresses {
    case savedPages - 1: return .init(savedPages: savedPages, keyPresses: keyPresses, turnFirst: true)
    case savedPages: return .init(savedPages: savedPages, keyPresses: keyPresses, turnFirst: false)
    default:
      throw CLIError("the unfinished capture's progress doesn't add up (\(savedPages) pages saved, "
        + "\(keyPresses) page turns). Start over without --resume.")
    }
  }
}
