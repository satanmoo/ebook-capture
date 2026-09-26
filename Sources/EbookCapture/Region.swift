import CoreGraphics

/// A rectangle in points, top-left origin. User-given regions are relative to
/// the screen the app is on (what Cmd+Shift+4 shows); `translated(by:)` turns
/// them into global coordinates.
public struct Region: Equatable, CustomStringConvertible {
  public let x, y, w, h: Int

  public init(x: Int, y: Int, w: Int, h: Int) {
    self.x = x; self.y = y; self.w = w; self.h = h
  }

  public var description: String { "\(x) \(y) \(w) \(h)" }
  public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

  /// Global coordinates for a region measured from a screen whose top-left
  /// corner is at `origin` (global points).
  public func translated(by origin: CGPoint) -> Region {
    Region(x: x + Int(origin.x.rounded()), y: y + Int(origin.y.rounded()), w: w, h: h)
  }

  /// The window frame shrunk by `margin` on every side.
  public static func inset(_ window: CGRect, margin: Int) throws -> Region {
    let wx = Int(window.minX.rounded()), wy = Int(window.minY.rounded())
    let ww = Int(window.width.rounded()), wh = Int(window.height.rounded())
    guard ww > 2 * margin, wh > 2 * margin else {
      throw CLIError("margin \(margin) is too large for the window (\(ww)x\(wh))")
    }
    return Region(x: wx + margin, y: wy + margin, w: ww - 2 * margin, h: wh - 2 * margin)
  }

  /// This region in the pixel space of a window image. The window image
  /// covers `window` (points) at `scale` pixels per point.
  public func pixelCrop(in window: CGRect, scale: CGFloat) throws -> CGRect {
    guard w > 0, h > 0, window.contains(rect) else {
      throw CLIError("region \(self) is outside the app window "
        + "(\(Int(window.minX)) \(Int(window.minY)) \(Int(window.width)) \(Int(window.height)))")
    }
    return CGRect(
      x: (rect.minX - window.minX) * scale, y: (rect.minY - window.minY) * scale,
      width: rect.width * scale, height: rect.height * scale
    ).integral
  }
}
