import {regressionHub} from './workspace-regression-hub';
import {resolve} from 'node:path';

/** Existing Worker approval/session endpoints with synthetic owner context only. */
export async function enrollmentHub(source:string,origin:string) {
 const {hashToken}=await import(resolve(source,'worker/src/auth.js'));
 const requests:{path:string;method:string;authenticated:boolean}[]=[];
 const hub=await regressionHub(source,origin,0,{
  env:{LOGIN_ACCESS_AUD:'fixture-approval'},
  context:{access:{aud:'fixture-approval',async getIdentity(){return {email:'owner@example.test'};}}},
  wrap:worker=>({...worker,fetch(request:Request,env:unknown,ctx:unknown){
   requests.push({path:new URL(request.url).pathname,method:request.method,authenticated:request.headers.has('Authorization')});
   return worker.fetch(request,env,ctx);
  }})
 });
 for(const [token,name,scopes,revoked] of [
  ['fixture-restricted','device:restricted','tables:read',null],
  ['fixture-revoked','device:revoked','full','2026-01-01T00:00:00Z']
 ])await hub.auth.prepare('INSERT INTO _tokens(hash,name,scopes,revoked_at) VALUES(?,?,?,?)').bind(await hashToken(token),name,scopes,revoked).run();
 return {...hub,requests,async approve(link:string){
  const url=new URL(link);if(url.origin!==hub.server.url.origin)throw Error('Fixture approval origin mismatch');
  return fetch(new URL('/login',url),{method:'POST',headers:{Origin:url.origin,'Content-Type':'application/x-www-form-urlencoded'},body:url.searchParams.toString(),redirect:'error'});
 }};
}
