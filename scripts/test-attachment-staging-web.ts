import { expect } from "@playwright/test";
import { sourceNavigationCDP, js } from "./source-navigation-cdp";
const url = process.env.LIFE_UI_TEST_URL;
if (!url) throw Error("Provide an owned synthetic workspace URL");
const cdp = await sourceNavigationCDP(url);
const scope = "interrupted-staging-" + crypto.randomUUID();
try {
  await cdp.evaluate("window.stagingTestEpoch=true");
  await cdp.navigate(url + "&start=" + scope);
  await cdp.until(
    "window.stagingTestEpoch===undefined",
    "fresh initial document",
  );
  await cdp.evaluate(`(async()=>{
    const {AttachmentOutbox}=await import('/src/lib/attachments.ts');
    const box=await AttachmentOutbox.open(${js(scope)},()=>null);
    await box.stage(new File([new Uint8Array([1,2,3])],'healthy.bin'));
    if(box.entries.length!==1) throw Error('Healthy stage was not published');
    window.stagingTestEpoch=true;
    const original=FileSystemDirectoryHandle.prototype.getFileHandle;
    FileSystemDirectoryHandle.prototype.getFileHandle=function(name,options){
      if(options?.create && (name==='metadata.json'||name.startsWith('.stage-'))){
        window.stagingHeld=true;
        return new Promise(()=>{});
      }
      return original.call(this,name,options);
    };
    void box.stage(new File(['unfinished'],'interrupted.bin')).catch(()=>{});
  })()`);
  await cdp.until(
    "window.stagingHeld===true",
    "actual metadata publication admission",
  );
  const during = await cdp.evaluate(`(async()=>{
    const {AttachmentOutbox}=await import('/src/lib/attachments.ts');
    const box=await AttachmentOutbox.open(${js(scope)},()=>null);
    const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(${js(scope)}))),b=>b.toString(16).padStart(2,'0')).join('');
    const root=await (await (await navigator.storage.getDirectory()).getDirectoryHandle('life-ui-attachments')).getDirectoryHandle(hash);
    const names=[];for await(const [name,handle] of root) if(handle.kind==='directory') names.push(name);
    box.dispose();return {count:box.entries.length,retainedDirectories:names.length};
  })()`);
  expect(during).toEqual({ count: 1, retainedDirectories: 2 });
  await cdp.navigate(url + "&stagingReopen=" + scope);
  await cdp.until(
    "window.stagingTestEpoch===undefined",
    "fresh reopened document",
  );
  const result = await cdp.evaluate(`(async()=>{
    try {
      const {AttachmentOutbox}=await import('/src/lib/attachments.ts');
      const box=await AttachmentOutbox.open(${js(scope)},()=>null);
      const file=await box.resolve(box.entries[0]?.key);
      const bytes=file ? Array.from(new Uint8Array(await (await fetch(file.url)).arrayBuffer())) : [];
      file?.dispose();box.dispose();
      const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(${js(scope)}))),b=>b.toString(16).padStart(2,'0')).join('');
      const root=await (await (await navigator.storage.getDirectory()).getDirectoryHandle('life-ui-attachments')).getDirectoryHandle(hash);
      const names=[];for await(const [name,handle] of root) if(handle.kind==='directory') names.push(name);
      return {count:box.entries.length,bytes,retainedDirectories:names.length};
    } catch(error) { return {error:String(error)}; }
  })()`);
  console.log(JSON.stringify(result));
  expect(result).toEqual({
    count: 1,
    bytes: [1, 2, 3],
    retainedDirectories: 1,
  });
  const corrupt = await cdp.evaluate(`(async()=>{
    const {AttachmentOutbox}=await import('/src/lib/attachments.ts');
    let connected=false;
    const box=await AttachmentOutbox.open(${js(scope)},()=>connected?{endpoint:'https://synthetic.invalid',token:'synthetic'}:null);
    const entry=box.entries[0];
    const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(${js(scope)}))),b=>b.toString(16).padStart(2,'0')).join('');
    const root=await (await (await navigator.storage.getDirectory()).getDirectoryHandle('life-ui-attachments')).getDirectoryHandle(hash);
    const writer=await (await root.getFileHandle(entry.id+'.json')).createWritable();await writer.write('{}');await writer.close();
    let blocked=false;try {await AttachmentOutbox.open(${js(scope)},()=>null);} catch {blocked=true;}
    try {await box.stage(new File(['another retained file'],'another.bin'));} catch {}
    connected=true;
    let rejected=false;try {await box.retry();} catch {rejected=true;}
    const retryError=box.error, busy=box.busy;
    box.dispose();
    const names=[];for await(const [name,handle] of root) if(handle.kind==='directory') names.push(name);
    return {blocked,retainedDirectories:names.length,rejected,retryError:!!retryError,busy};
  })()`);
  expect(corrupt).toEqual({
    blocked: true,
    retainedDirectories: 2,
    rejected: false,
    retryError: true,
    busy: false,
  });
  console.log(
    "Interrupted copies stay private, live staging is retained, abandoned staging reclaimed, published corruption remains visible",
  );
} finally {
  await cdp.evaluate(
    `(async()=>{
    const root=await (await navigator.storage.getDirectory()).getDirectoryHandle('life-ui-attachments');
    const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(${js(scope)}))),b=>b.toString(16).padStart(2,'0')).join('');
    await root.removeEntry(hash,{recursive:true});
  })()`,
  );
  cdp.close();
}
