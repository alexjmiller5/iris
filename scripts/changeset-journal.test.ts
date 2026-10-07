import {test,expect} from 'bun:test';
import {encodeChangesetApproval,decodeChangesetApproval} from '../apps/web/src/lib/governance/changeset-journal.ts';
const time='2030-01-01T00:00:00.000Z';
const scope={endpoint:'https://example.test',deploymentId:'d',sessionId:'s',principalId:'p'};
const proposal={id:'a',version:'v',state:'pending',input:{operations:[{kind:'create',table:'items',id:'row',expected_revision:null,values:{label:'x'}}],reads:[]},changes:[{table:'items',id:'row',kind:'create',before:null,after:{label:'x'}}],dependencies:'digest',proposedBy:{kind:'agent',principalId:'agent'},claimedOrigin:null,createdAt:time,updatedAt:time};
const entry={version:1,scope,proposal,request:{proposalId:'a',expectedVersion:'v',previewToken:'opaque',idempotencyKey:'original'}};
test('retains the exact original whole-set request and scope',()=>{const encoded=encodeChangesetApproval(entry as never,scope);expect(decodeChangesetApproval(encoded,scope)).toEqual(entry);});
test('a different connection/principal cannot adopt another pending approval',()=>{for(const key of Object.keys(scope)){expect(()=>decodeChangesetApproval(JSON.stringify(entry),{...scope,[key]:'different'})).toThrow();}});
test('malformed, partial and mismatched proposal recovery fails closed',()=>{for(const e of [{...entry,version:2},{...entry,proposal:{...proposal,changes:[]}},{...entry,request:{...entry.request,expectedVersion:'other'}}])expect(()=>decodeChangesetApproval(JSON.stringify(e),scope)).toThrow();});
