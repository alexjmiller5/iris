/** Real HTTP writer + real browser journal. Synthetic state only; caller owns tab. */
import {parseArgs} from 'node:util';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const {values}=parseArgs({args:Bun.argv.slice(2),options:{target:{type:'string'},port:{type:'string',default:'9222'},helper:{type:'string'},shot:{type:'string'},mobile:{type:'boolean',default:false}}});
if(!values.target||!values.helper||!process.env.SOMA_CONTRACT_ROOT)throw Error('Explicit owned target, helper and SOMA_CONTRACT_ROOT required');
const root=process.env.SOMA_CONTRACT_ROOT;
const {default:worker}=await import(pathToFileURL(resolve(root,'worker/src/main.js')).href);
const {default:hub}=await import(pathToFileURL(resolve(root,'worker/src/index.js')).href);
const {D1Shim}=await import(pathToFileURL(resolve(root,'worker/test/d1shim.js')).href);
const {hashToken}=await import(pathToFileURL(resolve(root,'worker/src/auth.js')).href);
const env={DB:new D1Shim(),AUTH_DB:new D1Shim(),HUB_TOKEN:'synthetic-operator',LOGIN_ACCESS_AUD:'aud',GOVERNANCE_DEPLOYMENT_ID:'synthetic-browser',GOVERNANCE_PREVIEW_KEY:Buffer.alloc(32,9).toString('base64url')};
await hub.fetch(new Request('https://fixture.test/login',{method:'POST',headers:{Origin:'https://fixture.test','Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({key:await hashToken('synthetic-user'),name:'Synthetic browser'})}),env,{access:{aud:'aud',getIdentity:async()=>({email:'user@example.test'})},waitUntil(){}});
const old='2020-01-01T00:00:00.000Z';
env.DB.db.exec(`CREATE TABLE catalog_tables(id TEXT PRIMARY KEY,kind TEXT,deleted_at TEXT);
CREATE TABLE catalog_properties(id TEXT PRIMARY KEY,tbl TEXT,col TEXT,type TEXT,sort INTEGER,required INTEGER,options TEXT,options_sql TEXT,ref_table TEXT,default_value TEXT,derived_by TEXT,inputs TEXT,deleted_at TEXT);
CREATE TABLE catalog_rules(id TEXT PRIMARY KEY,tbl TEXT,kind TEXT,enforce INTEGER,scope TEXT,sql TEXT,deleted_at TEXT);
CREATE TABLE items(id TEXT PRIMARY KEY,label TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT);
INSERT INTO catalog_tables VALUES('items','table',NULL);
INSERT INTO catalog_properties(id,tbl,col,type) VALUES('label','items','label','text');
INSERT INTO items VALUES('existing','Before','${old}',NULL,NULL);`);
async function invoke(request:Request){const pending:Promise<unknown>[]=[];const r=await worker.fetch(request,env,{waitUntil:p=>pending.push(p)});await Promise.all(pending);return r;}
async function call(path:string,body:object){return (await invoke(new Request('https://fixture.test/v1/'+path,{method:'POST',headers:{Authorization:'Bearer synthetic-user','Content-Type':'application/json'},body:JSON.stringify(body)}))).json();}
await call('schema/pull',{});
const input={operations:[{kind:'patch',table:'items',id:'existing',expected_revision:{updated_at:old,hub_at:null},values:{label:'Updated'}},{kind:'create',table:'items',id:'new',expected_revision:null,values:{label:'New record'}}],reads:[]};
const preview=await call('governance/changesets/preview',input);assert.equal(preview.kind,'success');
const created=await call('governance/changesets/proposals/create',{previewToken:preview.value.previewToken,idempotencyKey:'create-browser'});assert.equal(created.kind,'success');
const dependency=createRequire(new URL('../apps/web/package.json',import.meta.url)).resolve;
const {compile}=await import(dependency('svelte/compiler'));
const build=await Bun.build({entrypoints:['scripts/changeset-browser.fixture.ts'],target:'browser',conditions:['browser'],plugins:[{name:'svelte',setup(b){b.onLoad({filter:/\.svelte$/},async({path})=>({contents:compile(await Bun.file(path).text(),{filename:path,generate:'client',css:'injected'}).js.code,loader:'js'}));}}]});
if(!build.success)throw Error(build.logs.join('\n'));
const script=await build.outputs[0].text();
const theme=(await Bun.file('apps/web/src/theme.css').text()).replace('@theme static',':root');
let lost=false,approvals=0;
const server=Bun.serve({hostname:'127.0.0.1',port:0,async fetch(request){const path=new URL(request.url).pathname;
if(path.startsWith('/v1/')){const r=await invoke(request);if(path.endsWith('/proposals/approve')){approvals++;if(!lost){lost=true;assert.equal(r.status,200);return new Response('Synthetic lost response',{status:503});}}return r;}
if(path==='/fixture.js')return new Response(script,{headers:{'Content-Type':'text/javascript'}});
return new Response(`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Synthetic changeset review</title><style>${theme}</style><script type="module" src="/fixture.js"></script>`,{headers:{'Content-Type':'text/html'}});
}});
async function evaluate(expression:string){const p=Bun.spawn(['node',values.helper!,values.port!,'-','--target',values.target!],{stdin:new Blob([`(async()=>JSON.stringify({value:await (${expression})}))()`]),stdout:'pipe',stderr:'pipe'});const [out,err,code]=await Promise.all([new Response(p.stdout).text(),new Response(p.stderr).text(),p.exited]);if(code)throw Error(err);return JSON.parse(out).value;}
async function wait(expression:string){for(let i=0;i<80;i++){if(await evaluate(expression))return;await Bun.sleep(50);}throw Error('Browser condition timed out: '+expression);}
async function click(label:string){await evaluate(`(()=>{const b=[...document.querySelectorAll('button')].find(b=>b.textContent.trim()===${JSON.stringify(label)});if(!b||b.disabled)throw Error('Button unavailable');b.click();return true;})()`);}
let viewport:WebSocket|null=null;
if(values.mobile){
  const targets=await (await fetch(`http://127.0.0.1:${values.port}/json/list`)).json();
  const target=targets.find(t=>t.id===values.target);if(!target)throw Error('Owned target missing');
  viewport=new WebSocket(target.webSocketDebuggerUrl);
  await new Promise(r=>viewport!.addEventListener('open',r,{once:true}));
  const ready=new Promise((yes,no)=>viewport!.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id===1)m.error?no(Error(JSON.stringify(m.error))):yes(m.result);}));
  viewport.send(JSON.stringify({id:1,method:'Emulation.setDeviceMetricsOverride',params:{width:390,height:844,deviceScaleFactor:1,mobile:true}}));await ready;
}
try{
await evaluate(`(setTimeout(()=>location.assign(${JSON.stringify(server.url+'?proposal='+created.value.id)}),100),true)`);await Bun.sleep(250);await wait("!!document.querySelector('button')");
await click('Review changes');await wait("!!document.querySelector('#changeset-id')");await click('Open review');await wait("document.body.textContent.includes('Approve 2 changes')");
assert.equal(env.DB.db.query("SELECT label FROM items WHERE id='existing'").get().label,'Before');
if(values.mobile){assert.equal(await evaluate('innerWidth'),390);assert.equal(await evaluate('document.querySelector("dialog").scrollWidth <= document.querySelector("dialog").clientWidth'),true);}
assert.equal(await evaluate("!![...document.querySelectorAll('td')].find(c=>c.textContent==='Updated')"),true);
if(values.shot){const p=Bun.spawn(['node',values.helper!,values.port!,'--shot',values.shot,'--target',values.target!]);if(await p.exited)throw Error('Screenshot failed');}
await click('Approve 2 changes');await wait("document.body.textContent.includes('Resolve previous approval')");
assert.equal(approvals,1);assert.equal(env.DB.db.query('SELECT count(*) n FROM items').get().n,2);
const history=env.DB.db.query('SELECT count(*) n FROM _governance_history').get().n;
await evaluate('(setTimeout(()=>location.reload(),100),true)');await Bun.sleep(250);await wait("!!document.querySelector('button')");await click('Review changes');await wait("document.body.textContent.includes('Resolve previous approval')");await click('Resolve previous approval');await wait("document.body.textContent.includes('Saved all 2 changes')");
assert.equal(approvals,2);assert.equal(env.DB.db.query('SELECT count(*) n FROM _governance_history').get().n,history);assert.equal(env.DB.db.query('SELECT count(*) n FROM items').get().n,2);
console.log('PASS rendered review, inert preview, atomic save, lost response, reload, original-key retry and no duplicate history');
}finally{
try{await evaluate(`(async()=>{document.querySelector('dialog')?.close();await new Promise(r=>setTimeout(r,100));await new Promise((yes,no)=>{const r=indexedDB.deleteDatabase('iris-changesets');r.onsuccess=yes;r.onerror=no;r.onblocked=()=>no(Error('blocked'));});setTimeout(()=>location.assign('about:blank'),100);return true;})()`);}finally{viewport?.close();server.stop(true);env.DB.db.close();env.AUTH_DB.db.close();}
}
