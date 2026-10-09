import Foundation
import Testing

@testable import IrisKit

@MainActor
struct NativeLinkIdentityStoreTests {
  private func fixture() throws -> (directory: URL, root: URL, workspace: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = directory.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = root.appendingPathComponent("local.sqlite")
    try Data("synthetic database".utf8).write(to: workspace)
    return (directory, root, workspace)
  }

  @Test func lookupNeverCreatesAndExplicitCopyPersistsPrivateOpaqueIdentity() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let store = NativeLinkIdentityStore(root: f.root, workspace: f.workspace)
    #expect(try store.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: store.file.path))
    let binding = try store.create()
    guard case .local = binding else { Issue.record("Expected local UUID"); return }
    #expect(try NativeLinkIdentityStore(root: f.root, workspace: f.workspace).load() == binding)
    let bytes = try Data(contentsOf: store.file)
    let text = try #require(String(data: bytes, encoding: .utf8))
    #expect(!text.contains(f.workspace.path) && !text.contains("synthetic database"))
    let attrs = try FileManager.default.attributesOfItem(atPath: store.file.path)
    let directoryAttrs = try FileManager.default.attributesOfItem(atPath: store.file.deletingLastPathComponent().path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(try store.create() == binding)
    #expect(try Data(contentsOf: store.file) == bytes)
  }

  @Test func independentWindowsReadLatestAndOrdinaryWritesKeepIdentity() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let first = NativeLinkIdentityStore(root: f.root, workspace: f.workspace)
    let second = NativeLinkIdentityStore(root: f.root, workspace: f.workspace)
    #expect(try first.load() == nil && second.load() == nil)
    let identities = try await withThrowingTaskGroup(of: NativeWorkspaceBinding.self) { group in
      group.addTask { try await first.create() }
      group.addTask { try await second.create() }
      var values: [NativeWorkspaceBinding] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(identities.count == 2 && identities[0] == identities[1])
    let handle = try FileHandle(forWritingTo: f.workspace)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(" plus an ordinary edit".utf8))
    try handle.close()
    #expect(try first.load() == identities[0] && second.create() == identities[0])
  }

  @Test func sameNamedFilesAndDifferentRootsNeverShareIDs() throws {
    let first = try fixture(), second = try fixture()
    defer {
      try? FileManager.default.removeItem(at: first.directory)
      try? FileManager.default.removeItem(at: second.directory)
    }
    let a = NativeLinkIdentityStore(root: first.root, workspace: first.workspace)
    let b = NativeLinkIdentityStore(root: second.root, workspace: second.workspace)
    let original = try a.create()
    #expect(try original != b.create())
    let external = first.directory.appendingPathComponent("local.sqlite")
    try FileManager.default.copyItem(at: first.workspace, to: external)
    let c = NativeLinkIdentityStore(root: first.root, workspace: external)
    let externalBinding = try c.create()
    #expect(externalBinding != original)
    #expect(try a.load() == original && c.load() == externalBinding)
  }

  @Test func replacementAtSamePathInvalidatesOldUUIDWithoutWritingDuringLookup() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let store = NativeLinkIdentityStore(root: f.root, workspace: f.workspace)
    let original = try store.create()
    let bytes = try Data(contentsOf: store.file)
    let backup = f.root.appendingPathComponent("previous.sqlite")
    try FileManager.default.moveItem(at: f.workspace, to: backup)
    try FileManager.default.copyItem(at: backup, to: f.workspace)
    #expect(try store.load() == nil)
    #expect(try Data(contentsOf: store.file) == bytes)
    let replacement = try store.create()
    #expect(replacement != original)
    #expect(try NativeLinkIdentityStore(root: f.root, workspace: f.workspace).load() == replacement)
    let oldLink = try NativeDeepLink(destination: NativeDestination(table: "notes", rowID: "same-id"), workspace: original)
    #expect(throws: WorkspaceError.self) { try oldLink.destination(matching: replacement) }
  }

  @Test func symlinkAliasAndRelocatedAppContainerKeepTheirExistingIdentity() throws {
    let f = try fixture()
    let moved = f.directory.appendingPathExtension("moved")
    defer {
      try? FileManager.default.removeItem(at: f.directory)
      try? FileManager.default.removeItem(at: moved)
    }
    let store = NativeLinkIdentityStore(root: f.root, workspace: f.workspace)
    let binding = try store.create()
    let alias = f.directory.appendingPathComponent("alias.sqlite")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.workspace)
    #expect(try NativeLinkIdentityStore(root: f.root, workspace: alias).load() == binding)
    try FileManager.default.moveItem(at: f.directory, to: moved)
    let root = moved.appendingPathComponent("state")
    #expect(try NativeLinkIdentityStore(root: root, workspace: root.appendingPathComponent("local.sqlite")).load() == binding)
  }

  @Test func corruptAndFuturePreferencesCannotBeOverwritten() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let store = NativeLinkIdentityStore(root: f.root, workspace: f.workspace)
    _ = try store.create()
    let valid = try Data(contentsOf: store.file)
    var future = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    future["version"] = 999
    for bytes in [Data("not JSON".utf8), try JSONSerialization.data(withJSONObject: future)] {
      try bytes.write(to: store.file)
      let reopened = NativeLinkIdentityStore(root: f.root, workspace: f.workspace)
      #expect(throws: WorkspaceError.self) { try reopened.load() }
      #expect(throws: WorkspaceError.self) { try reopened.create() }
      #expect(try Data(contentsOf: store.file) == bytes)
    }
  }

  @Test func inaccessiblePreferencesAreNotTreatedAsMissingOrRepaired() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let store = NativeLinkIdentityStore(root: f.root, workspace: f.workspace)
    _ = try store.create()
    let bytes = try Data(contentsOf: store.file)
    let directory = store.file.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    let reopened = NativeLinkIdentityStore(root: f.root, workspace: f.workspace)
    #expect(throws: WorkspaceError.self) { try reopened.load() }
    #expect(throws: WorkspaceError.self) { try reopened.create() }
    #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    #expect(try Data(contentsOf: store.file) == bytes)
  }

  @Test func missingOrNonFileWorkspaceCannotIssueOrRecoverABinding() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    for file in [f.directory.appendingPathComponent("missing.sqlite"), f.root] {
      let store = NativeLinkIdentityStore(root: f.root, workspace: file)
      #expect(throws: WorkspaceError.self) { try store.load() }
      #expect(throws: WorkspaceError.self) { try store.create() }
      #expect(!FileManager.default.fileExists(atPath: store.file.path))
    }
  }
}
