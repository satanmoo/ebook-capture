import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public enum Permissions {
  /// Both are granted to the terminal app that launches this tool.
  public static func check() throws {
    guard AXIsProcessTrusted() else {
      throw CLIError("Accessibility permission is required to turn pages. Grant it to your "
        + "terminal app in System Settings > Privacy & Security > Accessibility, then retry.")
    }
    guard CGPreflightScreenCaptureAccess() else {
      CGRequestScreenCaptureAccess()
      throw CLIError("Screen Recording permission is required to capture pages. Grant it to your "
        + "terminal app in System Settings > Privacy & Security > Screen Recording, then retry.")
    }
  }
}

public enum AppControl {
  public static func runningPID(of app: AppTarget) -> pid_t? {
    NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == app.bundleID && $0.activationPolicy == .regular
    }?.processIdentifier
  }

  /// Brings the app to the front via Launch Services (`open -b`), which works
  /// from a CLI process where NSRunningApplication.activate may be refused.
  public static func activate(_ app: AppTarget) throws {
    guard activate(bundleID: app.bundleID) else { throw CLIError("cannot activate \(app.label)") }
  }

  @discardableResult
  public static func activate(bundleID: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-b", bundleID]
    do {
      try p.run()
    } catch {
      return false
    }
    p.waitUntilExit()
    return p.terminationStatus == 0
  }

  /// The app in front right now.
  public static var frontmost: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

  /// Presses → in the frontmost app. Keys posted to a background app's pid
  /// were ignored by every tested reader, so callers activate first.
  public static func pressNextPage() {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
      guard let e = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: down) else { continue }
      e.flags = [.maskNumericPad, .maskSecondaryFn]  // as a hardware arrow key reports
      e.post(tap: .cghidEventTap)
    }
  }
}

public struct WindowInfo {
  public let id: CGWindowID
  /// Points, top-left origin.
  public let frame: CGRect

  /// The app's frontmost normal window. Tiny windows are skipped: on macOS 26
  /// each app's menu bar strip shows up as a layer-0 window (e.g. 1920x30).
  public static func front(of pid: pid_t) -> WindowInfo? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    for w in list {  // front to back
      guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
        (w[kCGWindowLayer as String] as? Int) == 0,
        let id = w[kCGWindowNumber as String] as? CGWindowID,
        let dict = w[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: dict),
        frame.width >= 200, frame.height >= 200
      else { continue }
      return WindowInfo(id: id, frame: frame)
    }
    return nil
  }

  /// Whether a window still exists, and whether it's on the visible screen
  /// (a minimized window, or one in a full-screen Space that was left, isn't).
  public static func status(of id: CGWindowID) -> (exists: Bool, onScreen: Bool) {
    func ids(_ options: CGWindowListOption) -> Set<CGWindowID> {
      let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
      return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }
    return (ids(.optionAll).contains(id), ids(.optionOnScreenOnly).contains(id))
  }
}

/// The terminal to come back to when capturing ends: the first regular app
/// among our parent processes (shell → terminal app), so it doesn't matter
/// what was clicked in the meantime.
public enum Launcher {
  /// Walks up from `pid` and returns the first ancestor that `isApp`
  /// accepts. Stops at launchd (pid 1) or after too many steps.
  public static func appAncestor(of pid: pid_t, parent: (pid_t) -> pid_t?, isApp: (pid_t) -> Bool) -> pid_t? {
    var current = parent(pid)
    var steps = 0
    while let p = current, p > 1, steps < 64 {
      if isApp(p) { return p }
      current = parent(p)
      steps += 1
    }
    return nil
  }

  static func parentPID(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
  }

  /// Bundle ID of the terminal that ran us. Under tmux the chain ends at
  /// the tmux server instead, so fall back to the app in front at start
  /// (unless that is the reader itself).
  public static func terminalBundleID(frontmostAtStart: NSRunningApplication?, reader: AppTarget) -> String? {
    let isApp: (pid_t) -> Bool = {
      NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular
    }
    if let pid = appAncestor(of: getpid(), parent: parentPID, isApp: isApp),
      let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    {
      return id
    }
    guard let front = frontmostAtStart?.bundleIdentifier, front != reader.bundleID else { return nil }
    return front
  }
}

/// End-of-run signal: a sound, then the terminal comes back to the front.
public enum Notifier {
  public static func finished(success: Bool, returnTo terminal: String?) async {
    if let sound = NSSound(named: success ? "Glass" : "Basso") {
      sound.play()
      try? await Task.sleep(for: .seconds(max(sound.duration, 0.3)))
    }
    if let terminal { AppControl.activate(bundleID: terminal) }
  }
}

public enum Displays {
  /// Top-left corner (global points) of the screen containing `point`.
  /// The main screen is at (0, 0); others are offset from it.
  public static func origin(containing point: CGPoint) -> CGPoint {
    var id = CGDirectDisplayID()
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return .zero }
    return CGDisplayBounds(id).origin
  }
}

/// One captured page: the image and its exact pixel bytes for comparison.
public struct Frame {
  public let image: CGImage
  public let pixels: Data

  public func sameContent(as other: Frame) -> Bool { pixels == other.pixels }

  /// Redraws into an owned buffer so `pixels` covers only this image
  /// (a cropped CGImage can still reference its parent's whole buffer).
  init(copying image: CGImage) throws {
    let w = image.width, h = image.height
    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CLIError("cannot allocate a \(w)x\(h) image") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let copy = ctx.makeImage(), let data = ctx.data else {
      throw CLIError("cannot copy the captured image")
    }
    self.image = copy
    self.pixels = Data(bytes: data, count: w * h * 4)
  }

  public func writePNG(to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CLIError("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CLIError("cannot write \(url.path)") }
  }
}

/// Captures one window with ScreenCaptureKit, so other windows or
/// notifications on top of it never end up in the page.
public final class WindowCapturer {
  private let filter: SCContentFilter
  private let config: SCStreamConfiguration
  private let window: CGRect
  private let region: Region

  public init(window: WindowInfo, region: Region) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
      throw CLIError("cannot capture the app window (id \(window.id))")
    }
    filter = SCContentFilter(desktopIndependentWindow: scWindow)
    let scale = CGFloat(filter.pointPixelScale)
    config = SCStreamConfiguration()
    config.width = Int(window.frame.width * scale)
    config.height = Int(window.frame.height * scale)
    config.showsCursor = false
    self.window = window.frame
    self.region = region
    _ = try region.pixelCrop(in: window.frame, scale: scale)  // fail fast if outside
  }

  public func capture() async throws -> Frame {
    let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let scale = CGFloat(full.width) / window.width
    let crop = try region.pixelCrop(in: window, scale: scale)
    guard let cropped = full.cropping(to: crop) else { throw CLIError("cannot crop the captured image") }
    return try Frame(copying: cropped)
  }
}
