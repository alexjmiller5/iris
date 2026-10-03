import { Database } from 'bun:sqlite';
import { expect,test } from 'bun:test';
import { enrollmentEndpoint } from '../apps/web/src/lib/enrollment-binding';

test('enrollment preflight uses both durable bindings without modifying storage',async()=>{
 const db=new Database(':memory:');
 db.exec('CREATE TABLE _core_state(key TEXT PRIMARY KEY,value TEXT);CREATE TABLE _sync_state(key TEXT PRIMARY KEY,value TEXT)');
 const driver={all:async(sql:string)=>db.query(sql).all() as any[]};
 const endpoint='https://hub.example.test';
 expect(await enrollmentEndpoint(driver,endpoint)).toBe(endpoint);
 db.query("INSERT INTO _sync_state VALUES('hub_url',?)").run(endpoint);
 expect(await enrollmentEndpoint(driver,endpoint)).toBe(endpoint);
 await expect(enrollmentEndpoint(driver,'https://other.example.test')).rejects.toThrow('fresh replica');
 db.query("INSERT INTO _core_state VALUES('hub',?)").run('https://other.example.test');
 await expect(enrollmentEndpoint(driver,endpoint)).rejects.toThrow('fresh replica');
 db.exec("CREATE TEMP TABLE _sync_state(key,value);INSERT INTO temp._sync_state VALUES('hub_url','https://other.example.test')");
 await expect(enrollmentEndpoint(driver,'https://other.example.test')).rejects.toThrow('fresh replica');
 expect(db.query('SELECT * FROM main._sync_state').all()).toEqual([{key:'hub_url',value:endpoint}]);
 db.close();
});
