import Foundation

public let version = "1.0.0"

public enum CLI {
  public static func run(_ args: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)  // progress lines show up even when piped
    do {
      let o = try Options.parse(args)
      if o.help {
        print(usage)
        return 0
      }
      if o.version {
        print(version)
        return 0
      }

      let fm = FileManager.default
      let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
      let env = ProcessInfo.processInfo.environment
      let interactive = isatty(STDIN_FILENO) != 0
      let prompt = Prompter()

      let output = try o.output.map { try OutputPath.resolve($0, cwd: cwd) } ?? prompt.output(in: cwd)
      if output.addedExtension {
        print("Note: added .pdf extension (\(output.input) → \(output.url.lastPathComponent))")
      }
      let pages = try o.pages ?? prompt.pages()
      // Flag runs (--app given) default to the whole window without asking
      let region = try o.region ?? (o.app == nil ? prompt.region() : nil)
      var app = try o.app ?? prompt.app()

      // Test hook: drive another reader (scripts/e2e.sh uses Preview)
      if let name = env["EBOOK_CAPTURE_APP"], !name.isEmpty {
        guard let target = AppTarget.running(named: name) else {
          throw CLIError("app not running: \(name)")
        }
        app = target
      }

      // Decide about an existing file before spending minutes capturing
      if fm.fileExists(atPath: output.url.path), !o.force {
        guard interactive else {
          throw CLIError("\(output.url.path) already exists. Use -f (--force) to overwrite it.")
        }
        guard try prompt.confirmOverwrite(output.url) else {
          print("Not overwriting. Nothing was captured.")
          return 1
        }
      }
      print("Saving to: \(output.url.path)")

      if app.isChrome {
        prompt.chromeNotice(waitForEnter: interactive)
      }

      let session = CaptureSession(
        output: output, pages: pages, app: app, region: region, margin: o.margin,
        pageTimeoutSeconds: env["EBOOK_CAPTURE_PAGE_TIMEOUT"].flatMap { Int($0) } ?? 5,
        tempRoot: fm.temporaryDirectory.appendingPathComponent("ebook-capture"))
      return try await session.run()
    } catch let e as UsageError {
      printError("Error: \(e)")
      printError(usage)
      return 1
    } catch {
      printError("Error: \(error)")
      return 1
    }
  }

  private static func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}
