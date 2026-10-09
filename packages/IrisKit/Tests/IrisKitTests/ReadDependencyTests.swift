import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

private final class DependencyFixture: NSObject {}

@MainActor
struct ReadDependencyTests {
  @Test func canonicalCompilerDependencyFixtureRunsThroughRealJavaScriptCoreAndGRDB() throws {
    #if SWIFT_PACKAGE
      let bundle = Bundle.module
    #else
      let bundle = Bundle(for: DependencyFixture.self)
    #endif
    let url = try #require(
      bundle.url(forResource: "read-dependencies", withExtension: "json", subdirectory: "Fixtures")
        ?? bundle.url(forResource: "read-dependencies", withExtension: "json"))
    let fixture = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let setup = try #require(fixture["setup"] as? [String])
    let cases = try #require(fixture["cases"] as? [[String: Any]])
    for test in cases {
      let name = try #require(test["name"] as? String)
      let context = try #require(JSContext())
      let bridge = try SQLiteBridge(path: ":memory:")
      try bridge.install(in: context)
      context.setObject(
        setup + (test["setup"] as? [String] ?? []), forKeyedSubscript: "setup" as NSString)
      context.setObject(test["statements"], forKeyedSubscript: "statements" as NSString)
      context.setObject(
        test["context"] ?? fixture["context"], forKeyedSubscript: "ownership" as NSString)
      let result = context.evaluateScript(
        #"""
        IrisSql.begin();
        for (const sql of setup) IrisSql.run(sql);
        const dataSnapshot = () => JSON.stringify(IrisSql.all('SELECT * FROM main.items').map(r => [r.id,r.parent_id,r.body]));
        const schemaSnapshot = () => JSON.stringify(IrisSql.all('SELECT type,name,sql FROM main.sqlite_schema ORDER BY name').map(r => [r.type,r.name,r.sql]));
        const before = dataSnapshot();
        const schema = schemaSnapshot();
        let result;
        try { result = {value: IrisSql.readDependencies(statements, ownership)}; }
        catch(e) { result = {error: String(e)}; }
        result.unchanged = before === dataSnapshot() && schema === schemaSnapshot();
        IrisSql.rollback();
        JSON.stringify(result);
        """#)
      #expect(context.exception == nil, "\(name): \(context.exception?.toString() ?? "")")
      let json = try #require(result?.toString())
      let actual = try #require(
        JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
      #expect(actual["unchanged"] as? Bool == true, "\(name) changed the database")
      if test["error"] as? Bool == true {
        #expect(actual["error"] != nil, "\(name) accepted unsafe SQL")
      } else {
        #expect(actual["error"] == nil, "\(name): \(actual["error"] ?? "")")
        if let expected = test["expected"] as? [String: [String]] {
          let value = actual["value"] as? [String: [String]]
          #expect(value?["tables"]?.sorted() == expected["tables"]?.sorted(), "\(name): \(json)")
        } else {
          #expect(actual["value"] is NSNull, "\(name): \(json)")
        }
      }
      try bridge.close()
    }
  }

  @Test func caseFoldingAmbiguityFailsClosedAndCanonicalUnicodeSpellingSurvives() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    let result = context.evaluateScript(
      #"""
      IrisSql.begin();
      IrisSql.run('CREATE TABLE "Ä" (id TEXT)');
      const canonical = IrisSql.readDependencies([{sql:'SELECT id FROM "Ä"'}], {ownedTempTables:[]});
      IrisSql.run('CREATE TABLE "ä" (id TEXT)');
      const ambiguous = IrisSql.readDependencies([{sql:'SELECT id FROM "Ä"'}], {ownedTempTables:[]});
      IrisSql.rollback();
      JSON.stringify([canonical, ambiguous]);
      """#)
    #expect(context.exception == nil)
    #expect(result?.toString() == #"[{"tables":["Ä"]},null]"#)
  }

  @Test func engineContextsRequireTheExplicitCoreSnapshotAndAnActiveTransaction() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    let result = context.evaluateScript(
      #"""
      const statements = ['changed','before','now'].map(name => ({
        sql: `WITH ${name} AS (VALUES(1),(2)) SELECT count(*) FROM ${name}`
      }));
      IrisSql.begin();
      IrisSql.run('CREATE TEMP TABLE unrelated_snapshot(id TEXT)');
      const unrelated = IrisSql.readDependencies(statements, {ownedTempTables:['unrelated_snapshot']});
      IrisSql.run('DROP TABLE temp.unrelated_snapshot');
      IrisSql.run('CREATE TEMP TABLE _core_write_before(id TEXT)');
      const trusted = IrisSql.readDependencies(statements, {ownedTempTables:['_core_write_before']});
      IrisSql.commit();
      const outside = IrisSql.readDependencies(statements, {ownedTempTables:['_core_write_before']});
      JSON.stringify([unrelated, trusted, outside]);
      """#)
    #expect(context.exception == nil)
    #expect(result?.toString() == #"[null,{"tables":[]},null]"#)
  }

  @Test func freshPreparationSeesChangedViewAndNeverLosesForeignKeyProtection() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    let result = context.evaluateScript(
      #"""
      IrisSql.run('CREATE TABLE first_table(id TEXT PRIMARY KEY)');
      IrisSql.run('CREATE TABLE second_table(id TEXT REFERENCES first_table(id))');
      IrisSql.begin();
      IrisSql.run('CREATE VIEW chosen AS SELECT id FROM first_table');
      const first = IrisSql.readDependencies([{sql:'SELECT * FROM chosen'}], {ownedTempTables:[]});
      IrisSql.run('DROP VIEW chosen');
      IrisSql.run('CREATE VIEW chosen AS SELECT id FROM second_table');
      const second = IrisSql.readDependencies([{sql:'SELECT * FROM chosen'}], {ownedTempTables:[]});
      let blocked = false;
      try { IrisSql.readDependencies([{sql:"SELECT 1 --\r'\n; PRAGMA foreign_keys=OFF; --'\n"}], {ownedTempTables:[]}); }
      catch { blocked = true; }
      let protectedFK = false;
      try { IrisSql.run("INSERT INTO second_table VALUES ('absent')"); } catch { protectedFK = true; }
      IrisSql.rollback();
      JSON.stringify([first, second, blocked, protectedFK]);
      """#)
    #expect(context.exception == nil)
    #expect(
      result?.toString() == #"[{"tables":["first_table"]},{"tables":["second_table"]},true,true]"#)
  }
}
