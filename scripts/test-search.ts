import { chromium, expect } from '@playwright/test';
import { disposableOrigin, workspacePage } from './test-origin';
const url=process.env.IRIS_TEST_URL??'http://iris-markdown.localhost:5198/workspace?review';
const origin=disposableOrigin(url);
const browser=await chromium.connectOverCDP(process.env.IRIS_TEST_CDP??'http://127.0.0.1:9222');
try {
 const page=workspacePage(browser.contexts().flatMap(c => c.pages()), url);
 if(!page)throw Error('Open the reserved search review page');
 let acceptDiscard=true;
 page.setDefaultTimeout(8000);page.on('dialog',d=>acceptDiscard?d.accept():d.dismiss());
 await page.setViewportSize({width:1440,height:1000});
 await page.goto(new URL('/',url).href);
 const cdp=await page.context().newCDPSession(page);
 await cdp.send('Storage.clearDataForOrigin',{origin,storageTypes:'all'});await cdp.detach();
 await page.goto(url);
 await page.getByRole('button',{name:'Try sample workspace',exact:true}).click();
 await page.getByRole('button',{name:'New record',exact:true}).click();
 await page.getByRole('textbox',{name:'Title',exact:true}).fill('Space journal');
 await page.getByRole('button', {name:'Body options',exact:true}).click();
  await page.getByRole('menuitem', {name:'Body source',exact:true}).click();
 await page.getByRole('textbox',{name:'Body',exact:true}).fill('# Astronomía\n\nA telescope observes nebulas.');
 await page.getByRole('button',{name:'Save record',exact:true}).click();
 await expect(page.getByRole('button',{name:'Space journal',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 await expect(page.getByRole('button',{name:'Find records',exact:false})).toBeEnabled();
 await page.keyboard.press('Meta+k');
 const search=page.getByRole('dialog',{name:'Find records',exact:true});
 await expect(search).toBeVisible();
 await search.getByRole('combobox',{name:'Search records',exact:true}).fill('nebul');
 await expect(search.getByRole('option').filter({hasText:'Space journal'})).toBeVisible();
 await expect(search).toContainText('notes');
 await search.getByRole('combobox',{name:'Search records',exact:true}).press('ArrowDown');
 await page.keyboard.press('Enter');
 await expect(search).not.toBeVisible();
 await expect(page.getByRole('heading',{name:'Space journal',exact:true})).toBeVisible();
 await page.reload();
 await page.getByRole('button',{name:'Try sample workspace',exact:true}).click();
 await expect(page.getByRole('button',{name:'Find records',exact:false})).toBeEnabled();
 await page.keyboard.press('Meta+k');
 await search.getByRole('combobox',{name:'Search records',exact:true}).fill('astronomia');
 await expect(search.getByRole('option').filter({hasText:'Space journal'})).toBeVisible();
 await page.keyboard.press('Escape');
 await expect(search).not.toBeVisible();
 await page.getByRole('button',{name:'A place to start',exact:true}).click();
 await page.getByRole('textbox',{name:'Title',exact:true}).fill('Keep my unsaved title');
 await page.keyboard.press('Meta+k');
 await search.getByRole('combobox',{name:'Search records',exact:true}).fill('nebul');
 acceptDiscard=false;
 await search.getByRole('option').filter({hasText:'Space journal'}).click();
 await expect(search).toBeVisible();
 await page.keyboard.press('Escape');
 await expect(page.getByRole('textbox',{name:'Title',exact:true})).toHaveValue('Keep my unsaved title');
 acceptDiscard=true;
 await page.getByRole('button',{name:'Close record',exact:true}).click();
 // Hold a real row-read receipt so Escape can race with opening its result.
 await page.evaluate(async()=>{
  const {WorkspaceDatabase}=await import('/src/lib/database.ts');
  const state=window as any;
  const original=WorkspaceDatabase.prototype.request;
  WorkspaceDatabase.prototype.request=async function(method:any,...input:any[]){
   const result=await original.call(this,method,...input);
   if(state.holdSearchOpen&&method==='rows'&&input[0]?.view?.filters?.some((f:any)=>f.column==='id')){
    state.holdSearchOpen=false;
    await new Promise<void>(resolve=>{state.releaseSearchOpen=resolve;});
   }
   return result;
  };
  state.holdSearchOpen=true;
 });
 await page.keyboard.press('Meta+k');
 await search.getByRole('combobox',{name:'Search records',exact:true}).fill('nebul');
 await search.getByRole('option').filter({hasText:'Space journal'}).click();
 await page.waitForFunction(()=>!!(window as any).releaseSearchOpen);
 await page.keyboard.press('Escape');
 await expect(search).not.toBeVisible();
 // Reopening also invalidates the old selection, even with another dialog now visible.
 await page.keyboard.press('Meta+k');
 await expect(search).toBeVisible();
 await page.evaluate(()=>{(window as any).releaseSearchOpen();});
 await expect(search).toBeVisible();
 await page.keyboard.press('Escape');
 await expect(page.getByRole('complementary',{name:'Record editor',exact:true})).not.toBeVisible();
 console.log('PASS: Cmd+K finds Markdown prefixes/accents, opens records and survives reopen');
} finally { await browser.close(); }
