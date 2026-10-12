import Foundation

/// The soma core's executor. Every NativeWorkspace, its JavaScriptCore context and its SQLite
/// connection live on this one thread, so a large request never blocks the main actor, which
/// holds UI state only. JSC values never leave the thread.
@globalActor public actor IrisCoreActor {
  public static let shared = IrisCoreActor()
  private static let executor = CoreThreadExecutor()
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    Self.executor.asUnownedSerialExecutor()
  }
}

/// One thread running a run loop. A JSContext created here (NativeWorkspace(path:) creates its
/// runtime on the core) schedules its heap timers on this run loop, so garbage collection runs
/// between jobs here instead of on the main thread, waiting for the JSC lock a request holds.
private final class CoreThreadExecutor: SerialExecutor, @unchecked Sendable {
  private let runLoop: CFRunLoop

  init() {
    let started = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var loop: CFRunLoop?
    let thread = Thread {
      loop = CFRunLoopGetCurrent()
      // A port keeps the run loop alive while no job or timer is scheduled.
      RunLoop.current.add(NSMachPort(), forMode: .default)
      started.signal()
      while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }
    thread.name = "iris.core"
    thread.qualityOfService = .userInitiated
    thread.start()
    started.wait()
    runLoop = loop!
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let executor = asUnownedSerialExecutor()
    // Blocks run in the order they were added.
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
      autoreleasepool { job.runSynchronously(on: executor) }
    }
    CFRunLoopWakeUp(runLoop)
  }
}
