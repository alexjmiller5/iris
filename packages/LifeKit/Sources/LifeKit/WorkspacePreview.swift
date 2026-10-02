import SwiftUI

public struct WorkspacePreview: View {
  @State private var title = "Sample note"
  @State private var priority = "2"
  @State private var result: [Violation]?
  @State private var failure = false

  public init() {}

  public var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Sample workspace", bundle: .module).font(.headline)
          Text("Example data. No account connected.", bundle: .module)
            .foregroundStyle(.secondary)
        }
        Section {
          LabeledContent {
            TextField(text: $title) { Text("Title", bundle: .module) }
              .multilineTextAlignment(.trailing)
              .accessibilityIdentifier("draft-title")
          } label: {
            Text("Title", bundle: .module)
          }
          LabeledContent {
            TextField(text: $priority) { Text("Priority", bundle: .module) }
              .multilineTextAlignment(.trailing)
              .accessibilityIdentifier("draft-priority")
          } label: {
            Text("Priority", bundle: .module)
          }
        } header: {
          Text("Sample note", bundle: .module)
        } footer: {
          Text("Title is required. Priority is an optional whole number.", bundle: .module)
        }
        Section {
          Button(action: checkDraft) { Text("Check draft", bundle: .module) }
            .accessibilityIdentifier("check-draft")
          if failure {
            Text("Unable to check this draft. Try again.", bundle: .module)
              .foregroundStyle(.red)
          } else if let result {
            if result.isEmpty {
              Label {
                Text("This draft follows the rules.", bundle: .module)
              } icon: {
                Image(systemName: "checkmark.circle")
              }
              .foregroundStyle(.green)
            } else {
              ForEach(result, id: \.col) { violation in
                Text(verbatim: violation.message).foregroundStyle(.red)
              }
            }
          }
        } footer: {
          Text("Preview only. Changes stay in this window.", bundle: .module)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(Text("Life UI", bundle: .module))
    }
    .onChange(of: title) {
      result = nil
      failure = false
    }
    .onChange(of: priority) {
      result = nil
      failure = false
    }
  }

  private func checkDraft() {
    do {
      let data = try JSONSerialization.data(withJSONObject: ["title": title, "priority": priority])
      result = try LifeCoreRuntime().validate(
        propertiesJSON:
          #"[{"col":"title","label":"Title","type":"text","required":1},{"col":"priority","label":"Priority","type":"int"}]"#,
        afterJSON: String(decoding: data, as: UTF8.self))
      failure = false
    } catch {
      result = nil
      failure = true
    }
  }
}

#Preview { WorkspacePreview() }
