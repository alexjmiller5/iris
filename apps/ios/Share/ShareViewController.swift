import LifeExtensionSupport
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Prepares one recoverable Quick Add draft from a shared URL or text. Nothing is saved
/// here: Life UI opens the draft for an explicit Save, and the text never enters a URL.
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    let model = ShareCaptureModel(context: extensionContext)
    let host = UIHostingController(rootView: ShareCaptureView(model: model))
    addChild(host)
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    host.didMove(toParent: self)
    Task { await model.load() }
  }
}

@Observable @MainActor final class ShareCaptureModel {
  private(set) var text: String?
  private(set) var sources: [WidgetSourceDescriptor] = []
  var selected = ""
  private(set) var message: String?
  private(set) var prepared = false
  private let context: NSExtensionContext?
  // One identity per share sheet: a repeated tap retries the same handoff.
  private let id = UUID()

  init(context: NSExtensionContext?) { self.context = context }

  func load() async {
    do {
      sources = try WidgetLibrary.installed()?.sources().filter {
        $0.kind == .list && $0.allowsQuickAdd && $0.openURL != nil && $0.displayColumn != nil
      } ?? []
    } catch { message = "Open Life UI to review its enabled tables." }
    selected = sources.first?.id ?? ""
    if sources.isEmpty, message == nil {
      message = "Enable a writable table in Life UI's Widgets and Search settings first."
    }
    text = await sharedText()
    if text == nil { message = "Share a link or text." }
  }

  func prepare() {
    guard let text, let source = sources.first(where: { $0.id == selected }) else { return }
    do {
      _ = try WidgetLibrary.installed()?.store(workspaceID: source.workspaceID)
        .stageQuickAdd(id: id, sourceID: source.id, text: text, column: source.displayColumn)
      prepared = true
      message = "Draft ready. Open Life UI to review and save it."
    } catch {
      message =
        text.utf8.count > 65536
        ? "This text is too long for a draft." : "Finish the pending Quick Add in Life UI first."
    }
  }

  func close() { context?.completeRequest(returningItems: nil) }

  private func sharedText() async -> String? {
    let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    for type in [UTType.url, UTType.plainText] {
      for provider in providers where provider.hasItemConformingToTypeIdentifier(type.identifier) {
        let item = try? await provider.loadItem(forTypeIdentifier: type.identifier)
        if let url = item as? URL, !url.isFileURL { return url.absoluteString }
        if let value = item as? String, !value.isEmpty { return value }
      }
    }
    return nil
  }
}

struct ShareCaptureView: View {
  @Bindable var model: ShareCaptureModel

  var body: some View {
    NavigationStack {
      Form {
        if let text = model.text {
          Section("Shared") {
            Text(text.prefix(500)).lineLimit(6).accessibilityIdentifier("share-text")
          }
        }
        if !model.sources.isEmpty, !model.prepared {
          Section {
            Picker("Table", selection: $model.selected) {
              ForEach(model.sources) { Text($0.title).tag($0.id) }
            }
          } footer: {
            Text("Life UI opens a draft with this text in the title field. Nothing is saved until you choose Save.")
          }
        }
        if let message = model.message {
          Section { Text(message).accessibilityIdentifier("share-message") }
        }
      }
      .navigationTitle("Quick Add")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.prepared ? "Done" : "Cancel") { model.close() }
        }
        if !model.prepared {
          ToolbarItem(placement: .confirmationAction) {
            Button("Prepare Draft") { model.prepare() }
              .disabled(model.text == nil || model.selected.isEmpty)
              .accessibilityIdentifier("share-prepare")
          }
        }
      }
    }
  }
}
