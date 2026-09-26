import AppKit

/// A reader app, identified by bundle ID. Names are unreliable: 교보도서관
/// runs as process "KEL", and display names change with the system language.
public struct AppTarget: Equatable {
  public let bundleID: String
  public let label: String

  public static let library = AppTarget(bundleID: "kr.co.kyobobook.KEL", label: "교보도서관")
  public static let chrome = AppTarget(bundleID: "com.google.Chrome", label: "Chrome")

  public var isChrome: Bool { bundleID == AppTarget.chrome.bundleID }

  /// Maps a user-facing selector. Swift string comparison is canonical, so
  /// NFC and NFD spellings of 교보도서관 both match.
  public static func resolve(_ selector: String) -> AppTarget? {
    switch selector {
    case "1", "library", "교보도서관": return .library
    case "2", "chrome", "Google Chrome": return .chrome
    default: return nil
    }
  }

  /// Test hook (EBOOK_CAPTURE_APP): a running app's name or bundle ID.
  public static func running(named name: String) -> AppTarget? {
    let app = NSWorkspace.shared.runningApplications.first {
      $0.activationPolicy == .regular && ($0.bundleIdentifier == name || $0.localizedName == name)
    }
    guard let app, let id = app.bundleIdentifier else { return nil }
    return AppTarget(bundleID: id, label: app.localizedName ?? name)
  }
}
