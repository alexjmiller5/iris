import IrisWidgetSupport
import SwiftUI
import WidgetKit

@main
struct IrisWidgetBundle: WidgetBundle {
  var body: some Widget {
    IrisTableWidget()
    IrisTodayWidget()
    IrisCountWidget()
    IrisQuickAddWidget()
    if #available(iOS 18.0, *) {
      IrisQuickAddControl()
    }
  }
}
