import ImageIO
import Observation
import SwiftUI

@MainActor @Observable
final class ImagePreviewState {
  private(set) var image: CGImage?
  private(set) var error: String?
  private var generation = UUID()

  func invalidate() {
    generation = UUID()
    image = nil
    error = nil
  }

  func load(_ operation: () async throws -> CGImage) async {
    invalidate()
    let request = generation
    do {
      let result = try await operation()
      guard request == generation, !Task.isCancelled else { return }
      image = result
    } catch {
      guard request == generation, !Task.isCancelled, !(error is CancellationError) else { return }
      self.error = "Image unavailable"
    }
  }
}

struct NativeImageField: View {
  let field: CatalogField
  let focus: FocusState<String?>.Binding
  @Binding var value: String
  let transport: HubTransport?

  var body: some View {
    let references = ImageReference.previews(type: field.type, value: value)
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(Array(references.prefix(8)), id: \.self) {
            reference in
            NativeImagePreview(reference: reference, label: field.label, transport: transport)
          }
        }
      }
      .accessibilityIdentifier("image-previews-\(field.id)")
      if references.count > 8 {
        Text("+\(references.count - 8) more in source").font(.caption).foregroundStyle(.secondary)
      }
      DisclosureGroup {
        TextField(field.label, text: $value, axis: .vertical)
          .fixedSize(horizontal: false, vertical: true)
          .focused(focus, equals: field.id)
          .autocorrectionDisabled()
          .accessibilityIdentifier("field-\(field.id)")
      } label: {
        Text("Image source").accessibilityIdentifier("image-source-\(field.id)")
      }
    }
  }
}

struct NativeImagePreview: View {
  let reference: ImageReference
  let label: String
  let transport: HubTransport?
  var size: CGFloat = 96
  @State private var state = ImagePreviewState()

  private struct RequestID: Hashable {
    let reference: ImageReference
    let connection: ObjectIdentifier?
  }

  var body: some View {
    Group {
      if let svg = reference.embeddedSVG {
        NativeSVGPreview(data: svg).accessibilityLabel(label)
      } else if let image = state.image {
        Image(decorative: image, scale: 1)
          .resizable()
          .scaledToFit()
          .accessibilityLabel(label)
          .accessibilityAddTraits(.isImage)
      } else if let error = state.error {
        Label(error, systemImage: "photo.badge.exclamationmark")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ProgressView().accessibilityLabel("Loading image")
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .task(id: RequestID(reference: reference, connection: transport?.imageRequestIdentity)) {
      guard reference.embeddedSVG == nil else {
        state.invalidate()
        return
      }
      let loader = ImagePreviewLoader()
      await state.load { try await loader.load(reference, transport: transport) }
    }
    .onDisappear { state.invalidate() }
  }
}
