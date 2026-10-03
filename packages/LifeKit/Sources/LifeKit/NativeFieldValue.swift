import Foundation

enum NativeDateKind: String { case date, datetime }

enum NativeDateValue {
  static func parse(_ raw: String, kind: NativeDateKind) -> Date? {
    let formatter = formatter(kind)
    guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
      return nil
    }
    return date
  }

  static func format(_ date: Date, kind: NativeDateKind) -> String {
    formatter(kind).string(from: date)
  }

  private static func formatter(_ kind: NativeDateKind) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.isLenient = false
    formatter.dateFormat = kind == .date ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
  }
}

enum NativeFieldLink {
  static func destination(type: String, value: String) -> URL? {
    guard !value.isEmpty,
      value.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
    else { return nil }
    if type == "url" {
      guard let components = URLComponents(string: value),
        ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
        components.host?.isEmpty == false
      else { return nil }
      return components.url
    }
    var components = URLComponents()
    if type == "email" {
      guard value.contains("@"), value.rangeOfCharacter(from: .whitespaces) == nil else {
        return nil
      }
      components.scheme = "mailto"
      components.path = value
    } else if type == "phone" {
      let number = value.filter { !" ()-.".contains($0) }
      let digits = number.hasPrefix("+") ? number.dropFirst() : number[...]
      guard !digits.isEmpty, digits.allSatisfy({ "0123456789".contains($0) }) else { return nil }
      components.scheme = "tel"
      components.path = number
    } else {
      return nil
    }
    return components.url
  }
}
