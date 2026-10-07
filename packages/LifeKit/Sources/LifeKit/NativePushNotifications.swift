import Foundation
import Observation
import UserNotifications

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@MainActor protocol PushNotificationDevice: AnyObject {
  var token: Data? { get }
  var error: String? { get }
  var platform: CorePushPlatform { get }
  func register()
  func observe(_ observer: @escaping (Data) -> Void) -> UUID
  func removeObserver(_ id: UUID)
}

@Observable @MainActor final class NativePushNotifications: PushNotificationDevice {
  static let shared = NativePushNotifications()
  private(set) var token: Data?
  private(set) var error: String?
  private var observers: [UUID: (Data) -> Void] = [:]
  var platform: CorePushPlatform {
    #if os(macOS)
      .macos
    #else
      .ios
    #endif
  }
  func observe(_ observer: @escaping (Data) -> Void) -> UUID {
    let id = UUID()
    observers[id] = observer
    return id
  }
  func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
  func received(_ token: Data) {
    self.token = token
    error = nil
    for observer in observers.values { observer(token) }
  }
  func failed() {
    error = "Apple push registration failed. Foreground alerts remain available."
  }
  func register() {
    error = nil
    // This does not request notification permission. The production Enable
    // action must already have succeeded before the services owner calls it.
    #if os(macOS)
      NSApplication.shared.registerForRemoteNotifications()
    #else
      UIApplication.shared.registerForRemoteNotifications()
    #endif
  }
}

@MainActor public final class LifePushAppDelegate: NSObject, UNUserNotificationCenterDelegate {
  public override init() { super.init() }
  private func installPresentationDelegate() {
    UNUserNotificationCenter.current().delegate = self
  }
  public nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
}

#if os(macOS)
  extension LifePushAppDelegate: NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
      installPresentationDelegate()
    }
    public func application(
      _ application: NSApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      NativePushNotifications.shared.received(deviceToken)
    }
    public func application(
      _ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
      NativePushNotifications.shared.failed()
    }
  }
#else
  extension LifePushAppDelegate: UIApplicationDelegate {
    public func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      installPresentationDelegate()
      return true
    }
    public func application(
      _ application: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      NativePushNotifications.shared.received(deviceToken)
    }
    public func application(
      _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
      NativePushNotifications.shared.failed()
    }
  }
#endif
