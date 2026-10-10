import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// Select option chip colors: the Notion palette, matching the web theme tokens.
enum OptionPalette {
  static let names = [
    "default", "gray", "brown", "orange", "yellow", "green", "blue", "purple", "pink", "red",
  ]
  /// (light, dark) chip backgrounds; chip text stays legible on every tint.
  private static let tints: [String: (UInt32, UInt32)] = [
    "default": (0xf1f0ef, 0x373737), "gray": (0xe3e2e0, 0x5a5a5a),
    "brown": (0xeee0da, 0x603b2c), "orange": (0xfadec9, 0x854c1d),
    "yellow": (0xfdecc8, 0x89632a), "green": (0xdbeddb, 0x2b593f),
    "blue": (0xd3e5ef, 0x28456c), "purple": (0xe8deee, 0x492f64),
    "pink": (0xf5e0e9, 0x69314c), "red": (0xffe2dd, 0x6e3630),
  ]
  static let ink = Color(light: 0x32302c, dark: 0xffffff)

  static func background(_ name: String?) -> Color? {
    name.flatMap { tints[$0] }.map { Color(light: $0.0, dark: $0.1) }
  }

  /// A new option's starting color: the palette in order, skipping default.
  static func newColor(index: Int) -> String { names[1 + index % (names.count - 1)] }

  static func title(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }

  /// A colored dot that system menus keep in color (they template ordinary symbols).
  static func dot(_ name: String?) -> Image? {
    guard let name, let tint = tints[name] else { return nil }
    // The saturated (dark appearance) tint reads on light and dark menus alike.
    #if canImport(UIKit)
      let color = UIColor(hex: tint.1)
      return UIImage(systemName: "circle.fill")
        .map { Image(uiImage: $0.withTintColor(color, renderingMode: .alwaysOriginal)) }
    #else
      let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [NSColor(hex: tint.1)]))
      image?.isTemplate = false
      return image.map(Image.init(nsImage:))
    #endif
  }
}

/// One select or multi-select value. Uncolored options stay neutral.
struct OptionChip: View {
  let value: String
  let color: String?
  var trailingSymbol: String?

  var body: some View {
    let tint = OptionPalette.background(color)
    HStack(spacing: 4) {
      Text(value.isEmpty ? "Empty value" : value).lineLimit(1)
      if let trailingSymbol {
        Image(systemName: trailingSymbol).imageScale(.small).accessibilityHidden(true)
      }
    }
    .font(.subheadline)
    .padding(.horizontal, 6)
    .padding(.vertical, 1)
    .foregroundStyle(tint == nil ? Color.primary : OptionPalette.ink)
    .background(tint ?? .clear, in: RoundedRectangle(cornerRadius: 4))
    .overlay {
      if tint == nil {
        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.45))
      }
    }
  }
}

/// A field's values as chips, in source order.
struct OptionChips: View {
  let field: CatalogField
  let values: [String]

  var body: some View {
    HStack(spacing: 4) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        OptionChip(value: value, color: field.optionColor(value))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(values.joined(separator: ", "))
  }
}

extension CatalogField {
  /// The catalog's palette color for one value, or nil (neutral).
  func optionColor(_ value: String) -> String? {
    guard case .array(let options) = property["options"] else { return nil }
    for case .object(let option) in options where option["v"]?.text == value {
      guard let color = option["color"]?.text, OptionPalette.names.contains(color) else {
        return nil
      }
      return color
    }
    return nil
  }
}

extension Color {
  init(light: UInt32, dark: UInt32) {
    #if canImport(UIKit)
      self.init(
        uiColor: UIColor {
          $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
      )
    #else
      self.init(
        nsColor: NSColor(name: nil) {
          $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(hex: dark) : NSColor(hex: light)
        })
    #endif
  }
}

#if canImport(UIKit)
  extension UIColor {
    fileprivate convenience init(hex: UInt32) {
      self.init(
        red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
  }
#else
  extension NSColor {
    fileprivate convenience init(hex: UInt32) {
      self.init(
        srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
  }
#endif
