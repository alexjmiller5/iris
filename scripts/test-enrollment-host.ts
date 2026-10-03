import {expect} from 'bun:test';
import {createCoreHandlers} from '../packages/core/client';
import {DeviceEnrollment,type EnrollmentState,sessionRequest} from '../apps/web/src/lib/device-enrollment';
import {enrollmentHub} from './enrollment-hub';
const source=process.argv[2];if(!source)throw Error('Provide the life-data fixture source checkout');
const hub=await enrollmentHub(source,'http://life-ui-enrollment.localhost:5230');
const endpoint=hub.server.url.href.replace(/\/$/,'');
const core=createCoreHandlers({} as never,()=>{throw Error();},'fixture');
const states:EnrollmentState[]=[];
const coreHost={request:async(method:string,args:never)=>method==='enrollmentEndpoint'?endpoint:(core as any)[method](args)};
let installed:{endpoint:string;token:string}|undefined;
const model=new DeviceEnrollment({core:coreHost,changed(s){states.push(s);},install:async(connection,current)=>{if(current())installed=connection;}});
const wait=async(predicate:()=>boolean)=>{const end=performance.now()+10000;while(!predicate()){if(performance.now()>end)throw Error('Fixture timeout');await Bun.sleep(10);}};
try {
 for(const token of ['fixture-root','fixture-restricted','fixture-revoked']) {
  await model.manual({endpoint,token});expect(installed).toBeUndefined();expect(states.at(-1)?.phase).toBe('failed');
 }
 await model.manual({endpoint,token:'fixture'});expect(installed?.token).toBe('fixture');installed=undefined;
 const run=model.start(endpoint,'Example browser');await wait(()=>states.at(-1)?.phase==='pending');
 const approval=states.at(-1)!.approval!;expect((await hub.approve(approval.url)).status).toBe(200);await run;
 expect(installed?.token).toMatch(/^lt_[a-f0-9]{48}$/);expect(states.at(-1)?.phase).toBe('connected');
 expect((await sessionRequest(installed!,'POST',new AbortController().signal)).data).toEqual({logged_out:true});
 expect((await sessionRequest(installed!,'GET',new AbortController().signal)).status).toBe(401);
 installed=undefined;
 const stopped=model.start(endpoint,'Cancelled browser');await wait(()=>states.at(-1)?.phase==='pending');const abandoned=states.at(-1)!.approval!;
 await model.cancel();expect(states.at(-1)?.message).toContain('may still be approved');expect((await hub.approve(abandoned.url)).status).toBe(200);await stopped;expect(installed).toBeUndefined();
 console.log('PASS: actual Worker approval, dedicated manual token, admin/restricted/revoked rejection, revocation and late cancelled approval');
} finally {await model.cancel();hub.server.stop(true);hub.db.db.close();hub.auth.db.close();}
