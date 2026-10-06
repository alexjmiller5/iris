import Foundation

struct WorkspaceFilter: Identifiable, Equatable {
  let id = UUID()
  var column: String
  var operation: CoreFilterOp = .eq
  var value = ""
  var today = false
  private var imported: CoreFilter?
  private var importedText: String?

  init(column: String, operation: CoreFilterOp = .eq, value: String = "") {
    self.column = column
    self.operation = operation
    self.value = value
  }

  init(_ filter: CoreFilter, field: CatalogField? = nil) {
    today = filter.relative == .today
    column = filter.column
    operation = filter.op
    switch filter.value {
    case .string(let text): value = text
    case .number(let number):
      value =
        field?.type == "bool" && [0, 1].contains(number)
        ? (number == 1 ? "true" : "false") : String(number)
    case .bool(let bool): value = bool ? "true" : "false"
    case .null, nil: value = ""
    }
    imported = filter
    importedText = value
  }

  static func operations(for type: String) -> [CoreFilterOp] {
    switch type {
    case "int", "number": [.eq, .ne, .gt, .gte, .lt, .lte, .empty, .notEmpty]
    case "bool", "ref": [.eq, .ne, .empty, .notEmpty]
    case "multi_ref", "multi_select": [.contains, .empty, .notEmpty]
    default: Array(CoreFilterOp.allCases)
    }
  }

  func coreFilter(field: CatalogField?) throws -> CoreFilter {
    if let imported, imported.column == column, imported.op == operation, importedText == value,
      (imported.relative == .today) == today
    {
      return imported
    }
    if operation == .empty || operation == .notEmpty {
      return CoreFilter(column: column, op: operation)
    }
    if today {
      guard ["date", "datetime"].contains(field?.type ?? ""), operation != .contains else {
        throw WorkspaceError(message: "Today requires a date comparison.", violations: [])
      }
      return CoreFilter(column: column, op: operation, relative: .today)
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

struct WorkspaceFilterGroup: Identifiable, Equatable {
  let id = UUID()
  var match: String = "any"
  var filters: [WorkspaceFilter] = []
  init(match: String = "any", filters: [WorkspaceFilter] = []) {
    self.match = match
    self.filters = filters
  }
  init(_ group: CoreFilterGroup, fields: [CatalogField]) {
    match = group.match
    filters = group.filters.map { filter in
      WorkspaceFilter(filter, field: fields.first { $0.id == filter.column })
    }
  }
  func core(fields: [CatalogField]) throws -> CoreFilterGroup {
    CoreFilterGroup(
      match: match,
      filters: try filters.map { filter in
        try filter.coreFilter(field: fields.first { $0.id == filter.column })
      })
  }
}
