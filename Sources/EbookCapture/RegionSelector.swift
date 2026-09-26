import AppKit

/// Converts the selection overlay's Cocoa coordinates (bottom-left origin)
/// into CG global points (top-left origin), which window frames and
/// capture use.
public enum SelectionGeometry {
  /// `primaryHeight` is the height of the primary screen (the one at the
  /// Cocoa origin); flipping around it turns one space into the other.
  public static func cgRect(fromCocoa r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
  }
}

/// Runs the selection overlay in a child process (`ebook-capture
/// __select-area`). Once a process has become an NSApplication, bringing
/// another app forward through Launch Services (`open -b`, which every page
/// turn does) makes AppKit quit it silently with exit code 0, so the
/// capturing process must never touch AppKit.
public enum SelectionHelper {
  public static let command = "__select-area"
  /// Test hook: the helper shows the overlay briefly and answers with this
  /// "x y w h" (global points) instead of waiting for a drag.
  public static let testSelectionVariable = "EBOOK_CAPTURE_TEST_SELECTION"

  /// The selection in CG global points, or nil when cancelled with Esc.
  public static func select() throws -> CGRect? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    p.arguments = [command]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    switch p.terminationStatus {
    case 0:
      guard let rect = parse(String(decoding: data, as: UTF8.self)) else {
        throw CLIError("the area selection returned nothing usable")
      }
      return rect
    case 2: return nil
    default: throw CLIError("the area selection failed (exit code \(p.terminationStatus))")
    }
  }

  /// "x y w h" → rect.
  public static func parse(_ text: String) -> CGRect? {
    let v = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
    guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
    return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
  }

  /// The child side: show the overlay, print the selection, exit 0 (or 2
  /// when cancelled).
  @MainActor
  public static func runChild() -> Int32 {
    let preset = ProcessInfo.processInfo.environment[testSelectionVariable].flatMap(parse)
    guard let r = RegionSelector.select(preset: preset) else { return 2 }
    print("\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))")
    return 0
  }
}

/// Lets the user drag a rectangle over the page, like Cmd+Shift+4. The
/// overlay is a non-activating panel on every screen that joins every Space,
/// so it shows over a full-screen reader without switching Spaces or taking
/// focus from it. Tested over full-screen Chrome and 교보도서관.
public enum RegionSelector {
  /// The selection in CG global points, or nil when cancelled with Esc.
  /// With `preset`, the overlay is shown briefly and `preset` is returned
  /// (for automated tests). Runs in the helper process only.
  @MainActor
  public static func select(preset: CGRect? = nil) -> CGRect? {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // no Dock icon, never becomes active
    app.finishLaunching()
    guard let primary = NSScreen.screens.first else { return nil }

    let selection = Selection()
    let panels = NSScreen.screens.map { screen -> NSPanel in
      let panel = NSPanel(
        contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.level = .screenSaver
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.contentView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), selection: selection)
      panel.orderFrontRegardless()
      return panel
    }

    // Esc arrives as a global key event: the panels never become key
    let escape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 53 { selection.state = .cancelled }
    }
    let presetDeadline = Date().addingTimeInterval(0.5)
    while selection.state == .selecting {
      if preset != nil, Date() > presetDeadline {
        selection.state = .preset
        break
      }
      if let event = app.nextEvent(
        matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true)
      {
        app.sendEvent(event)
      }
    }
    if let escape { NSEvent.removeMonitor(escape) }
    panels.forEach { $0.orderOut(nil) }

    if selection.state == .preset { return preset }
    guard case .selected(let cocoa) = selection.state else { return nil }
    return SelectionGeometry.cgRect(fromCocoa: cocoa, primaryHeight: primary.frame.height).integral
  }
}

/// Shared by the overlays on all screens: one drag ends the selection.
final class Selection {
  enum State: Equatable {
    case selecting
    case selected(CGRect)  // Cocoa global coordinates
    case cancelled
    case preset  // test hook: answer with the preset selection
  }

  var state = State.selecting
}

final class SelectionView: NSView {
  private let selection: Selection
  private var start: NSPoint?
  private var current: NSPoint?
  private static let minimumSize: CGFloat = 20

  init(frame: NSRect, selection: Selection) {
    self.selection = selection
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { fatalError("unused") }

  // Take the first click as the start of the drag
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

  private var rect: NSRect? {
    guard let start, let current else { return nil }
    return NSRect(
      x: min(start.x, current.x), y: min(start.y, current.y),
      width: abs(start.x - current.x), height: abs(start.y - current.y))
  }

  override func mouseDown(with event: NSEvent) {
    start = convert(event.locationInWindow, from: nil)
    current = start
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    current = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    guard let r = rect, r.width >= Self.minimumSize, r.height >= Self.minimumSize, let window else {
      // A click or a tiny drag: keep waiting
      start = nil
      current = nil
      needsDisplay = true
      return
    }
    selection.state = .selected(window.convertToScreen(r))
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.35).setFill()
    bounds.fill()

    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white,
    ]
    let hint = "Drag over the page to capture. Esc to cancel." as NSString
    let size = hint.size(withAttributes: attrs)
    hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 60), withAttributes: attrs)

    guard let r = rect else { return }
    NSColor.clear.setFill()
    r.fill(using: .copy)
    NSColor.systemBlue.setStroke()
    let border = NSBezierPath(rect: r)
    border.lineWidth = 2
    border.stroke()
    ("\(Int(r.width)) × \(Int(r.height))" as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.minY + 6), withAttributes: attrs)
  }
}
