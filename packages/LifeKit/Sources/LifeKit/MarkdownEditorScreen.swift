import SwiftUI

struct MarkdownEditorScreen: View {
  @Binding var value: String
  let label: String
  @State private var session: MarkdownEditorSession
  @State private var nativeSource = false
  @State private var finishing = false
  @Environment(\.dismiss) private var dismiss

  init(value: Binding<String>, label: String) {
    _value = value
    self.label = label
    _session = State(initialValue: MarkdownEditorSession(value: value.wrappedValue, label: label))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let failure = session.failure {
        Text(failure).font(.callout).foregroundStyle(.secondary).padding(.horizontal)
      }
      ZStack {
        MarkdownWebView(session: session)
          .opacity(session.ready && !nativeSource ? 1 : 0)
          .allowsHitTesting(session.ready && !nativeSource && !finishing)
          .accessibilityHidden(!session.ready || nativeSource)
        if nativeSource || session.failure != nil {
          VStack(alignment: .leading) {
            Text("Markdown source").font(.caption).foregroundStyle(.secondary)
            TextEditor(
              text: Binding(
                get: { session.document.value },
                set: {
                  nativeSource = true
                  session.editSource($0)
                })
            )
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel("\(label) Markdown source")
            .accessibilityIdentifier("markdown-source-fallback")
          }.padding()
        } else if !session.ready {
          VStack(spacing: 12) {
            ProgressView("Loading editor…")
            Button("Use source editor") { nativeSource = true }
          }
        }
      }
    }
    .navigationTitle(label)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") {
          finishing = true
          Task {
            do {
              if session.ready && !nativeSource {
                guard let snapshot = session.snapshot else {
                  throw WorkspaceError(message: "The editor is unavailable.", violations: [])
                }
                try session.acceptSnapshot(try await snapshot())
              }
              dismiss()
            } catch {
              session.fail("The editor could not finish. Your last received source is below.")
            }
            finishing = false
          }
        }.disabled(finishing).accessibilityIdentifier("finish-markdown")
      }
    }
    .disabled(finishing)
    .onAppear {
      session.onChange = { value = $0 }
      session.begin(value: value, label: label, readOnly: false)
    }
    .onDisappear { session.invalidate() }
  }
}
