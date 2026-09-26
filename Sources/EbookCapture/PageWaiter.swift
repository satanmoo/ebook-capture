import Foundation

public struct Interrupted: Error {
  public init() {}
}

/// Waits for a page turn by polling captures instead of a fixed delay.
public struct PageWaiter {
  public var timeout: Duration
  public var interval: Duration

  public init(timeout: Duration = .seconds(5), interval: Duration = .milliseconds(200)) {
    self.timeout = timeout
    self.interval = interval
  }

  /// Polls until a frame differs from `previous` and the next frame is the
  /// same (rendering finished). Returns the last frame and whether the page
  /// turned before the timeout. Throws `Interrupted` when `stop()` is true.
  public func waitForTurn<F>(
    from previous: F,
    same: (F, F) -> Bool,
    grab: () async throws -> F,
    stop: () -> Bool = { false }
  ) async throws -> (frame: F, turned: Bool) {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var last: F?
    var current = previous
    while clock.now < deadline {
      try await Task.sleep(for: interval)
      if stop() { throw Interrupted() }
      current = try await grab()
      if !same(current, previous), let last, same(current, last) {
        return (current, true)
      }
      last = current
    }
    return (current, false)
  }
}
