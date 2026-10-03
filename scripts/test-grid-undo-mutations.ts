import {resolve} from 'node:path';
import {disposableOrigin} from './test-origin';
disposableOrigin(process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-grid-enrollment.localhost:5234/workspace?review');
const source=process.argv[2]; if(!source)throw Error('Provide the life-data checkout');
const path=resolve(import.meta.dir,'../apps/web/src/routes/workspace/+page.svelte');
const original=await Bun.file(path).text();
const mutations=[
 ['missing-promotion', 'if (cell.raw !== rawValue(cell.baseline[cell.cell.column]))', 'if (false)', 'dirty same-row'],
 ['raw-overwritten', '{ ...before, [cell.cell.column]: cell.raw }', 'before', 'dirty same-row'],
 ['old-baseline', 'before,\n\t\t\t\t\t\trowDraft(receipt)', 'before, before', 'dirty same-row'],
 ['old-revision', 'selected = receipt;\n\t\t\t\tundoPaused = false;', 'selected = cell.baseline;\n\t\t\t\tundoPaused = false;', 'dirty same-property'],
 ['retained-cell', 'gridDraft = null;\n\t\t\t\tselected = receipt;', 'selected = receipt;', 'dirty same-row'],
 ['other-row-promoted', 'gridDraft.cell.rowId === action.rowId', 'true', 'other-row'],
 ['clean-promoted', 'if (cell.raw !== rawValue(cell.baseline[cell.cell.column]))', 'if (true)', 'clean same-row'],
 ['autosave-resumed', '\t\t\t\t\tundoPaused = reconciled.dirty;', '\t\t\t\t\tundoPaused = false;', 'Markdown cell'],
 ['restore-loses-draft', 'const preserveDraft = restoring && undoPaused;', 'const preserveDraft = false;', 'creation undo']
];
for(const [name,before,after,scenario] of mutations){
 if(original.split(before).length!==2)throw Error('Mutation target moved: '+name);
 if(process.argv.includes('--check')){console.log('MATCHED: '+name);continue;}
 try{
  await Bun.write(path,original.replace(before,after));
  await Bun.sleep(1000);
  const child=Bun.spawn(['bun','scripts/test-grid-undo.ts',source],{cwd:resolve(import.meta.dir,'..'),env:{...process.env,LIFE_UI_GRID_UNDO_CASE:scenario},stdout:'pipe',stderr:'pipe'});
  const [status,out,err]=await Promise.all([child.exited,new Response(child.stdout).text(),new Response(child.stderr).text()]);
  await Bun.write(`/tmp/life-ui-grid-undo-mutation-${name}.log`,out+err);
  if(!status)throw Error('Mutation survived: '+name);
  if(!/expect\(.*\).*failed|AssertionError|Expected: /s.test(out+err))throw Error('Mutation failed without an assertion: '+name+'\n'+out+err);
  console.log('CAUGHT: '+name);
 }finally{await Bun.write(path,original);}
}
