import {test,expect} from 'bun:test';
import {createRequire} from 'node:module';
const resolve=createRequire(new URL('../apps/web/package.json',import.meta.url)).resolve;
const {get}=await import(resolve('svelte/store'));
import {createChangesetReview} from '../apps/web/src/lib/governance/changeset-review.ts';
const time='2099-01-01T00:00:00.000Z';
const scope={endpoint:'https://example.test',deploymentId:'d',sessionId:'s',principalId:'u'};
const proposal={id:'p',version:'v',state:'pending',input:{operations:[{kind:'create',table:'items',id:'r',expected_revision:null,values:{label:'new'}}],reads:[]},changes:[{kind:'create',table:'items',id:'r',before:null,after:{label:'new'}}],dependencies:'hash',proposedBy:{kind:'agent',principalId:'a'},claimedOrigin:null,createdAt:time,updatedAt:time};
function fixture(result:any={kind:'transport_error',code:'indeterminate'}){
  let saved:any=null,calls:any[]=[];const journal={load:async()=>saved,retain:async(e:any)=>{saved=structuredClone(e);},resolve:async(e:any)=>{expect(e).toEqual(saved);saved=null;},close(){}};
  const api={getProposal:async()=>({kind:'success',value:proposal}),previewProposal:async()=>({kind:'success',value:{changes:proposal.changes,previewToken:'token',expiresAt:time}}),approveProposal:async(...a:any[])=>{calls.push(a);return result;}};
  const model=createChangesetReview(api as never,journal,scope,()=> 'key');return {model,journal,api,calls,read:()=>saved};
}
test('retains the full review before dispatch and resolves the exact original after reopen',async()=>{
  const f=fixture();await f.model.ready;await f.model.open('p');await f.model.approve();expect(f.read()).not.toBeNull();expect(get(f.model).unresolved).toBe(true);
  await f.model.dispose();const next=createChangesetReview(f.api as never,f.journal,scope,()=> 'wrong-new-key');await next.ready;await next.approve();expect(f.calls.length).toBe(2);expect(f.calls[0]).toEqual(f.calls[1]);expect(f.calls[0][0].idempotencyKey).toBe('key');
});
test('failed durability never dispatches or overwrites another review',async()=>{
  const f=fixture();f.journal.retain=async()=>{throw Error('storage failed');};await f.model.ready;await f.model.open('p');await f.model.approve();expect(f.calls).toEqual([]);expect(get(f.model).error).toContain('Nothing was sent');
});
test('an unresolved auth response keeps the original request; a durable negative clears it',async()=>{
  const f=fixture({kind:'error',code:'permission_denied',resolution:'unresolved',conflicts:[]});await f.model.ready;await f.model.open('p');await f.model.approve();expect(f.read()).not.toBeNull();
  const g=fixture({kind:'error',code:'revision_changed',resolution:'not_committed',conflicts:[]});await g.model.ready;await g.model.open('p');await g.model.approve();expect(g.read()).toBeNull();expect(get(g.model).preview).toBeNull();
});
test('closing while retention is pending cannot dispatch and preserves the saved request',async()=>{
  const f=fixture();let release!:()=>void;const gate=new Promise<void>(r=>release=r),retain=f.journal.retain;f.journal.retain=async e=>{await gate;await retain(e);};
  await f.model.ready;await f.model.open('p');const a=f.model.approve();await Promise.resolve();const close=f.model.dispose();release();await a;await close;expect(f.calls).toEqual([]);expect(f.read()).not.toBeNull();
});
