import SwiftUI

/// Asks to download a skipped table: why it is read-only, its size, the suggested setting (which
/// the user may adjust) and a way to stop asking for this table on this device.
struct DownloadPromptView: View {
  let model: WorkspaceModel
  let prompt: DownloadPromptRequest
  private enum Kind: Hashable { case include, limit }
  @State private var kind = Kind.include
  @State private var limit: String
  @State private var hide = false
  @State private var busy = false
  @State private var failure: String?

  init(model: WorkspaceModel, prompt: DownloadPromptRequest) {
    self.model = model
    self.prompt = prompt
    _limit = State(initialValue: Self.minimum(prompt).map(String.init) ?? "")
  }

  private static func minimum(_ prompt: DownloadPromptRequest) -> Int? {
    for case .limit(let rows) in prompt.choices { return rows }
    return nil
  }

  private var approved: DownloadChoice? {
    switch kind {
    case .include: return .include
    case .limit:
      guard let minimum = Self.minimum(prompt),
        let rows = Int(limit.trimmingCharacters(in: .whitespaces)), rows >= minimum
      else { return nil }
      return .limit(rows)
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Its records here are read-only and may be incomplete. Download it to edit them.")
          if let waiting = SkippedTableText.waiting(prompt.detail) { Text(waiting) }
          LabeledContent("Size", value: SkippedTableText.size(prompt.detail))
            .accessibilityIdentifier("download-prompt-size")
        } header: {
          Text("Not synced on this device")
        }
        Section {
          Picker("Suggested setting", selection: $kind) {
            Text("Download this table on this device").tag(Kind.include)
            if Self.minimum(prompt) != nil { Text("Raise the automatic row limit").tag(Kind.limit) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          .accessibilityIdentifier("download-prompt-choice")
          if kind == .limit, let minimum = Self.minimum(prompt) {
            LabeledContent("Row limit") {
              TextField("Row limit", text: $limit)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                  .keyboardType(.numberPad)
                #endif
                .accessibilityIdentifier("download-prompt-limit")
            }
            Text("At least \(minimum.formatted()) to include this table.")
              .font(.caption).foregroundStyle(approved == nil ? .red : .secondary)
          }
        } header: {
          Text("Suggested setting")
        } footer: {
          Text(
            kind == .include
              ? "Syncs this table whatever its size."
              : "Tables up to this many rows sync, including others.")
        }
        Section {
          Toggle("Don't show this again for this table", isOn: $hide)
            .accessibilityIdentifier("download-prompt-hide")
        }
        if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
      }
      .formStyle(.grouped)
      .navigationTitle(prompt.detail.table)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Not now") { model.dismissDownloadPrompt(hide: hide) }
            .accessibilityIdentifier("download-prompt-dismiss")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Download") { approve() }
            .disabled(busy || approved == nil)
            .accessibilityIdentifier("download-prompt-approve")
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 420)
    #endif
  }

  private func approve() {
    guard let approved, !busy else { return }
    busy = true
    failure = nil
    Task {
      defer { busy = false }
      do { try await model.approveDownload(approved, for: prompt) } catch {
        failure = error.localizedDescription
      }
    }
  }
}

/// Settings beside Search: tables whose download prompt this device hides, to show it again.
struct DownloadPromptsSection: View {
  let model: WorkspaceModel

  var body: some View {
    if model.isReplica, !model.hiddenDownloadPrompts.isEmpty {
      Section {
        ForEach(model.hiddenDownloadPrompts, id: \.self) { table in
          LabeledContent(table) {
            Button("Show prompt") { model.showDownloadPrompt(for: table) }
              .accessibilityLabel("Show prompt for \(table)")
              .accessibilityIdentifier("show-download-prompt-" + table)
          }
        }
      } header: {
        Text("Download prompts")
      } footer: {
        Text(
          "Tables this device does not sync stay read-only. Show the prompt again to download one when you open it."
        )
      }
    }
  }
}
