import Foundation

// Generated wire models; these aliases keep presentation call sites stable.
typealias UsageSummary = CoreUsageSummary
typealias HubNotification = CoreHubNotification
typealias NotificationFeed = CoreNotificationFeed
typealias NotificationPresentation = CoreNotificationPresentation
typealias NotificationReadResult = CoreNotificationReadResult

extension CoreUsageSummary {
  typealias Period = CoreUsagePeriod
  typealias Metric = CoreUsageMetric
  typealias Cap = CoreUsageCap
  typealias Principal = CoreUsagePrincipal
}
extension CoreUsagePrincipal: Identifiable {
  var byteExactID: Data { Data(id.utf8) }
}
extension CoreHubNotification: Identifiable {
  var byteExactID: Data { Data(id.utf8) }
}
