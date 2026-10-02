import Foundation

struct WorkspaceFilter: Identifiable, Equatable {
  let id = UUID()
  var column: String
  var operation: CoreFilterOp = .eq
  var value = ""

  static func operations(for type: String) -> [CoreFilterOp] {
    switch type {
    case "int", "number": [.eq, .ne, .gt, .gte, .lt, .lte, .empty, .notEmpty]
    case "bool", "ref": [.eq, .ne, .empty, .notEmpty]
    case "multi_ref", "multi_select": [.contains, .empty, .notEmpty]
    default: Array(CoreFilterOp.allCases)
    }
  }

  func coreFilter(field: CatalogField?) throws -> CoreFilter {
    if operation == .empty || operation == .notEmpty {
      return CoreFilter(column: column, op: operation)
    }
    let typed: CoreFilterValue
    if ["int", "number"].contains(field?.type ?? "") {
      guard let number = Double(value), number.isFinite else {
        throw WorkspaceError(
          message: "Enter a number for \(field?.label ?? column).", violations: [])
      }
      typed = .number(number)
    } else if field?.type == "bool" {
      guard ["true", "false"].contains(value) else {
        throw WorkspaceError(
          message: "Choose True or False for \(field?.label ?? column).", violations: [])
      }
      typed = .bool(value == "true")
    } else {
      typed = .string(value)
    }
    return CoreFilter(column: column, op: operation, value: typed)
  }
}

extension CoreFilterOp {
  var label: String {
    switch self {
    case .eq: "Equals"
    case .ne: "Does not equal"
    case .contains: "Contains"
    case .gt: "Greater than"
    case .gte: "At least"
    case .lt: "Less than"
    case .lte: "At most"
    case .empty: "Is empty"
    case .notEmpty: "Is not empty"
    }
  }
}
