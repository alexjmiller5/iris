import LifeWidgets
import SwiftUI
import WidgetKit

@main
struct LifeUIWidgetBundle: WidgetBundle {
  var body: some Widget {
    LifeTableWidget()
    LifeTodayWidget()
    LifeCountWidget()
  }
}
