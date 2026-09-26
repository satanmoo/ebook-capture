import CoreGraphics
import Foundation
import ImageIO

public enum PDFWriter {
  /// Merges the PNGs in `dir` (sorted by name) into one PDF, one page per
  /// image. Writes to a temp file first so a failure never leaves a partial
  /// PDF, then replaces `output` if it exists (the caller confirmed that).
  @discardableResult
  public static func merge(pngsIn dir: URL, to output: URL) throws -> Int {
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "png" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { throw CLIError("no PNG files found in \(dir.path)") }

    let temp = output.appendingPathExtension("partial")
    guard let ctx = CGContext(temp as CFURL, mediaBox: nil, nil) else {
      throw CLIError("cannot create \(output.path)")
    }
    for file in files {
      guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
      else {
        ctx.closePDF()
        try? FileManager.default.removeItem(at: temp)
        throw CLIError("cannot read \(file.lastPathComponent)")
      }
      var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
      ctx.beginPage(mediaBox: &box)
      ctx.draw(image, in: box)
      ctx.endPage()
    }
    ctx.closePDF()
    if FileManager.default.fileExists(atPath: output.path) {
      _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
    } else {
      try FileManager.default.moveItem(at: temp, to: output)
    }
    return files.count
  }
}
