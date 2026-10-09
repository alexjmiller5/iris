import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {disposableOrigin} from './test-origin';
const browser=process.argv.includes('--browser');
if(browser)disposableOrigin(process.env.IRIS_TEST_URL??'http://iris-creation.localhost:5242/workspace?review');
const grid='apps/web/src/lib/record-grid.ts',page='apps/web/src/routes/workspace/+page.svelte',prepare='apps/web/src/lib/record-duplicate.ts';
// Run after formatting; exact matches refuse to silently skip a mutation.
const mutants: [string,string,string,string,string?][]=browser?[
 ['empty-intent-not-dirty',page,'explicitCreation.size > 0 || copiedCreation !== null','false','same-empty'],
 ['discard-before-read',page,'const prepared = await prepareDuplicate','if (!discard()) return false;\n\t\t\tconst prepared = await prepareDuplicate','failed permission'],
 ['stale-error-published',page,'if (current()) error = message(e);','error = message(e);','superseded'],
]:[
 ['untouched-default-submitted',grid,'!explicit.has(property.col) && !Object.hasOwn(copied, property.col)',"raw === '' && !explicit.has(property.col) && !Object.hasOwn(copied, property.col)"],
 ['empty-copy-normalized',grid,'? copied[property.col]', '? fieldValue(property, raw)'],
 ['clear-copy-ignored',grid,'!row && !explicit.has(property.col) && Object.hasOwn(copied, property.col)','!row && Object.hasOwn(copied, property.col)'],
 ['identity-accepted',prepare,'row.id !== id','false'],
 ['permission-ignored',prepare,'if (!permission.writable)', 'if (false)'],
 ['late-result-published',prepare,'if (!current()) return null;', ''],
 ['creation-immutable-dropped',grid,'(row && property.immutable)','property.immutable'],
];
for(const [name,path,before,after,filter] of mutants){
 const original=await readFile(path,'utf8');
 if(!original.includes(before))throw Error(`Mutation not found: ${name}`);
 try{
  await writeFile(path,original.replaceAll(before,after));
  const command=browser?[process.execPath,...(process.env.IRIS_CDP_PRELOAD?['--preload',process.env.IRIS_CDP_PRELOAD]:[]),'scripts/test-creation-intent.ts',process.argv[2]]:[process.execPath,'run','--cwd','apps/web','test','--','src/lib/record-grid.spec.ts','src/lib/record-duplicate.spec.ts'];
  const child=Bun.spawn(command,{env:{...process.env,IRIS_CREATION_CASE:filter??''},stdout:'pipe',stderr:'pipe'});
  const [stdout,stderr,exit]=await Promise.all([new Response(child.stdout).text(),new Response(child.stderr).text(),child.exited]);
  await writeFile(resolve('/tmp',`iris-creation-mutation-${name}.log`),stdout+stderr);
  if(exit===0)throw Error(`SURVIVED: ${name}`);
  if(browser&&!stdout.concat(stderr).includes('FAIL '+(filter==='same-empty'?'same-empty clear':filter==='failed permission'?'failed permission reply':'superseded permission failure')))throw Error(`Unexpected failure: ${name}`);
  if(!browser&&!stdout.concat(stderr).includes('AssertionError'))throw Error(`Unexpected failure: ${name}`);
  console.log('CAUGHT',name);
 }finally{await writeFile(path,original);}
}
