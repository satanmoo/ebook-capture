import Foundation

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
      let tempRoot = fm.temporaryDirectory.appendingPathComponent("ebook-capture")

      // An unfinished capture of this file: --resume continues it; without
      // the flag a terminal is asked, and other runs start over
      var resume: SessionState?
      let unfinished = SessionState.read(from: CaptureSession.folder(for: output, in: tempRoot))
      let mine = unfinished.flatMap { $0.output == output.url.path ? $0 : nil }
      if o.resume {
        guard let mine else {
          throw CLIError(unfinished.map { "the unfinished capture with that name belongs to \($0.output)" }
            ?? "nothing to resume for \(output.url.path)")
        }
        resume = mine
      } else if let mine {
        if interactive {
          if try prompt.confirmResume(mine) { resume = mine }
        } else {
          print("Found an unfinished capture of \(mine.output); starting over. Use --resume to continue it instead.")
        }
      }

      if let resume {
        // Fail before any prompts or notices if it can't be continued
        _ = try CaptureSession.resumePoint(resume, dir: CaptureSession.folder(for: output, in: tempRoot))
      }

      let pages: Int?
      let area: AreaChoice
      let margin: Int
      var app: AppTarget
      if let resume {
        // Same settings as the run being continued, unless overridden
        pages = o.pages ?? resume.maxPages
        // A selection was saved as coordinates, so it isn't asked again
        area = o.region.map(Self.choice) ?? resume.captureRegion.map { .fixed($0) } ?? .wholeWindow
        margin = resume.margin
        app = o.app ?? resume.app
      } else {
        // Flag runs (--app given) default to the end of the book and the
        // whole window without asking
        pages = try o.pages ?? (o.app == nil ? prompt.pages() : nil)
        area = try o.region.map(Self.choice) ?? (o.app == nil ? prompt.area() : .wholeWindow)
        margin = o.margin
        app = try o.app ?? prompt.app()
      }

      // Test hook: drive another reader (scripts/e2e.sh uses Preview)
      if let name = env["EBOOK_CAPTURE_APP"], !name.isEmpty {
        guard let target = AppTarget.running(named: name) else {
          throw CLIError("app not running: \(name)")
        }
        app = target
      }

      // Decide about an existing file before spending minutes capturing.
      // A resumed run rebuilds its own partial PDF, so it doesn't ask.
      if resume == nil, fm.fileExists(atPath: output.url.path), !o.force {
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
        output: output, pages: pages, app: app, area: area, margin: margin,
        pageTimeoutSeconds: env["EBOOK_CAPTURE_PAGE_TIMEOUT"].flatMap { Int($0) } ?? 5,
        tempRoot: tempRoot, resume: resume)
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

  private static func choice(_ option: AreaOption) -> AreaChoice {
    switch option {
    case .fixed(let r): return .fixed(r)
    case .select: return .select
    }
  }
}
