import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { mkdir } from 'node:fs/promises'
const fixtures = process.env.HCFO_W16_FIXTURES ? JSON.parse(readFileSync(process.env.HCFO_W16_FIXTURES, 'utf8')) : null
const live = process.env.HCFO_W16_WEB
const api = process.env.HCFO_W16_API
const evidence = process.env.HCFO_W16_EVIDENCE

test('Coach Studio live follow-ups recover a lost atomic launch response then edit and launch again before creating a program', async ({page,context,request}, info) => {
  test.skip(!fixtures || !live || !api || !fixtures[info.project.name], 'Requires isolated W16 Rails fixtures')
  test.setTimeout(300_000)
  const fixture=fixtures[info.project.name]
  const authorization=`Bearer test_token_${fixture.coach_id}`
  const headers={Authorization:authorization,'X-Coach-Workspace-Id':String(fixture.workspace_id)}
  let launchCount=0
  let launchKey=''
  let release!:()=>void
  const held=new Promise<void>(resolve=>{release=resolve})
  let interrupted=true
  await context.route(`${api}/**`, async route=>{
    const path=new URL(route.request().url()).pathname
    const requestHeaders={...route.request().headers(),Authorization:authorization}
    if(path==='/api/v1/auth/me') {
      const response=await route.fetch({headers:requestHeaders})
      const payload=await response.json()
      return route.fulfill({response,json:{...payload,user:{...payload.user,clerk_id:'e2e_coach'}}})
    }
    if(path.endsWith('/go_live')) {
      launchCount+=1
      const key=route.request().headers()['idempotency-key']
      if(launchKey && launchCount <= 2) expect(key).toBe(launchKey)
      if(launchKey && launchCount === 3) expect(key).not.toBe(launchKey)
      launchKey=key
      await held
      const response=await route.fetch({headers:requestHeaders})
      expect(response.status(),await response.text()).toBe(200)
      if(interrupted) { interrupted=false;return route.abort('failed') }
      return route.fulfill({response})
    }
    return route.continue({headers:requestHeaders})
  })
  if(info.project.name==='desktop-chrome') await page.setViewportSize({width:1366,height:900})
  await page.goto(`${live}/?pilot_e2e_role=coach&pilot_e2e_live_api=true#Coach%20Studio`)
  await expect(page.getByLabel('Program',{exact:true})).toBeVisible()
  await page.getByLabel('Program',{exact:true}).selectOption(String(fixture.workspace_id))
  await page.getByRole('navigation',{name:'Coach Studio areas'}).getByRole('button',{name:'Go live',exact:true}).click()
  await expect(page.getByText('Review before going live')).toBeVisible({timeout:60_000})
  await expect(page.getByText('Savings · Mia · Statements · More',{exact:true})).toBeVisible()
  await expect(page.getByText(/program team still needs to open/)).toBeVisible()
  const screenshot=async(name:string)=>{if(evidence){await mkdir(evidence,{recursive:true});await page.screenshot({path:`${evidence}/${info.project.name}-${name}.png`,fullPage:true,scale:'css'})}}
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
  await screenshot('review')
  await page.getByRole('button',{name:'Approve and go live',exact:true}).click()
  await expect(page.getByText(/Saving your assistant and updating/)).toBeVisible()
  await screenshot('progress')
  release()
  await expect(page.getByRole('alert').filter({hasText:'We could not confirm'})).toBeVisible({timeout:60_000})
  await screenshot('recovery')
  await page.reload()
  await page.getByLabel('Program',{exact:true}).selectOption(String(fixture.workspace_id))
  await page.getByRole('navigation',{name:'Coach Studio areas'}).getByRole('button',{name:'Go live',exact:true}).click()
  const finish=page.getByRole('button',{name:'Finish going live'})
  await expect(finish).toBeVisible({timeout:60_000})
  await finish.click()
  await expect(page.getByRole('status').filter({hasText:'Live for'})).toBeVisible({timeout:60_000})
  await expect(page.getByText(/Preview and approve your assistant’s voice before/)).toHaveCount(0)
  await expect(page.getByRole('status').filter({hasText:'Live for'})).toContainText('program team still needs to open')
  await screenshot('success')
  expect(launchCount).toBe(2)
  for(const id of fixture.group_ids) {
    const result=await request.get(`${api}/api/v1/admin/cohorts/${id}/launch`,{headers})
    expect(result.status()).toBe(200)
    const launch=(await result.json()).launch
    expect(launch.active_release_id).toBeTruthy()
  }
  const before = await Promise.all(fixture.group_ids.map(async (id:number) => {
    const response = await request.get(`${api}/api/v1/admin/cohorts/${id}/launch`, {headers})
    return (await response.json()).launch.active_release_id
  }))
  const areas = page.getByRole('navigation',{name:'Coach Studio areas'})
  await areas.getByRole('button',{name:'Your assistant',exact:true}).click()
  await page.getByText('More settings',{exact:true}).click()
  await page.getByRole('button',{name:'Appearance',exact:true}).click()
  const appName = `Updated ${info.project.name}`
  await page.getByLabel('App name',{exact:true}).fill(appName)
  const brandSaved = page.waitForResponse(response => response.url().endsWith('/brand') && response.request().method()==='PATCH')
  await page.getByRole('button',{name:'Save brand draft',exact:true}).click()
  expect((await brandSaved).status()).toBe(200)
  await screenshot('appearance-edit')
  await page.getByText('Advanced / history',{exact:true}).click()
  await page.getByRole('button',{name:'Open advanced settings',exact:true}).click()
  await page.getByRole('button',{name:/Guided setup.*Short steps/}).click()
  const assistantName = `Mia ${info.project.name}`
  await page.getByLabel('Assistant name',{exact:true}).fill(assistantName)
  const voiceSaved = page.waitForResponse(response => response.url().endsWith(`/personas/${fixture.persona_id}`) && response.request().method()==='PATCH')
  await page.getByRole('button',{name:'Save draft',exact:true}).click()
  const savedVoice = await voiceSaved
  expect(savedVoice.status()).toBe(200)
  expect((await savedVoice.json()).persona.preview).toBeNull()
  await screenshot('voice-edit')
  await page.getByRole('button',{name:'Back to simple setup',exact:true}).click()
  await page.getByRole('navigation',{name:'Coach Studio areas'}).getByRole('button',{name:'Go live',exact:true}).click()
  await page.getByRole('button',{name:'Preview answers',exact:true}).click()
  await expect(page.getByText('Review before going live')).toBeVisible({timeout:90_000})
  const brandReview = await request.get(`${api}/api/v1/admin/brand`,{headers})
  expect((await brandReview.json()).brand_configuration.draft.product_name).toBe(appName)
  const currentPersona = await request.get(`${api}/api/v1/admin/personas/${fixture.persona_id}`,{headers})
  const fresh = (await currentPersona.json()).persona
  expect(fresh.preview.digest).toBeTruthy()
  await screenshot('edited-review')
  const updated = page.waitForRequest(request => request.url().endsWith('/go_live') && request.method()==='POST')
  await page.getByRole('button',{name:'Approve and go live',exact:true}).click()
  expect((await updated).postDataJSON().review.persona.preview_digest).toBe(fresh.preview.digest)
  await expect(page.getByRole('status').filter({hasText:'Live for'})).toBeVisible({timeout:90_000})
  expect(launchCount).toBe(3)
  for(const [index,id] of fixture.group_ids.entries()) {
    const response = await request.get(`${api}/api/v1/admin/cohorts/${id}/launch`,{headers})
    const launch = (await response.json()).launch
    expect(launch.active_release_id).not.toBe(before[index])
    const releases = await request.get(`${api}/api/v1/admin/cohorts/${id}/releases`,{headers})
    const studio = (await releases.json()).cohort_release_studio
    expect(studio.latest_release.coach_persona_version_id).toBeTruthy()
  }
  const publishedBrand = await request.get(`${api}/api/v1/admin/brand`,{headers})
  const brandId = (await publishedBrand.json()).brand_configuration.published_version.id
  const brandVersion = await request.get(`${api}/api/v1/admin/brand/versions/${brandId}`,{headers})
  expect((await brandVersion.json()).version.config.product_name).toBe(appName)
  const publishedVoice = await request.get(`${api}/api/v1/admin/personas/${fixture.persona_id}`,{headers})
  const voiceId = (await publishedVoice.json()).persona.published_version.id
  const voiceVersion = await request.get(`${api}/api/v1/admin/personas/${fixture.persona_id}/versions/${voiceId}`,{headers})
  expect((await voiceVersion.json()).version.config.identity.assistant_name).toBe(assistantName)
  await screenshot('updated-live')
  await page.getByRole('link',{name:'Admin',exact:true}).click()
  await page.getByRole('button',{name:'Programs & rules',exact:true}).click()
  await page.getByRole('button',{name:'Create program',exact:true}).click()
  const name=`W16 created ${info.project.name}`
  await page.getByLabel('Program name',{exact:true}).fill(name)
  await page.getByLabel('Coach display name',{exact:true}).fill('Mrs. Mel')
  await screenshot('create-program')
  const created=page.waitForResponse(response=>response.url().endsWith('/api/v1/admin/coach_workspaces')&&response.request().method()==='POST')
  await page.getByRole('button',{name:'Create program',exact:true}).click()
  const response=await created
  expect(response.status()).toBe(201)
  await expect(page.getByText(`${name} was created and selected. You can now set up its assistant, appearance and groups.`,{exact:true})).toBeVisible()
  await screenshot('created-program')
  await page.reload()
  await page.getByLabel('Admin workspace').selectOption(String((await response.json()).coach_workspace?.id ?? (await response.json()).workspace?.id))
  await expect(page.getByText(`${name} was created and selected. You can now set up its assistant, appearance and groups.`,{exact:true})).toHaveCount(0)
  const payload=await response.json()
  const workspace=payload.coach_workspace ?? payload.workspace
  const saved=await request.get(`${api}/api/v1/admin/coach_workspaces/${workspace.id}`,{headers:{...headers,'X-Coach-Workspace-Id':String(workspace.id)}})
  expect(saved.status()).toBe(200)
  expect(JSON.stringify(await saved.json())).toContain(name)
})

test('Coach Studio live voice proposal labels exact coach wording and suggestions separately', async ({page,context},info)=>{
 test.skip(!fixtures?._voice || !live || !api,'Requires the recorded W16 setup turn')
 test.setTimeout(120_000)
 const voice=fixtures._voice
 await context.route(`${api}/**`,async route=>{
  const headers={...route.request().headers(),Authorization:`Bearer test_token_${voice.coach_id}`}
  if(new URL(route.request().url()).pathname==='/api/v1/auth/me'){
   const response=await route.fetch({headers});const payload=await response.json()
   return route.fulfill({response,json:{...payload,user:{...payload.user,clerk_id:'e2e_coach'}}})
  }
  return route.continue({headers})
 })
 if(info.project.name==='desktop-chrome') await page.setViewportSize({width:1366,height:900})
 await page.goto(`${live}/?pilot_e2e_role=coach&pilot_e2e_live_api=true#Coach%20Studio`)
 await page.getByLabel('Program',{exact:true}).selectOption(String(voice.workspace_id))
 await page.getByRole('navigation',{name:'Coach Studio areas'}).getByRole('button',{name:'Your assistant',exact:true}).click()
 await expect(page.getByText('Your voice suggestions')).toBeVisible({timeout:60_000})
 await page.getByText('Review each suggestion',{exact:true}).click()
 await expect(page.getByText('Coach said',{exact:true}).first()).toBeVisible()
 await expect(page.getByText('Suggested from what you said',{exact:true}).first()).toBeVisible()
 const exact=await page.locator('.persona-proposal-change').evaluateAll(rows=>rows.filter(row=>row.querySelector('header span')?.textContent==='Coach said').map(row=>({value:row.querySelector('.coach-suggestion-value')?.textContent,quote:row.querySelector('blockquote')?.textContent})))
 expect(exact.length).toBeGreaterThan(0)
 for(const row of exact) expect(row.quote).toContain(row.value)
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
 if(evidence){await mkdir(evidence,{recursive:true});await page.screenshot({path:`${evidence}/${info.project.name}-voice-source-labels.png`,fullPage:true,scale:'css'})}
})

for (const recovery of ['server failures', 'expired access']) {
 test(`Coach Studio real API checks ${recovery} against a fenced or committed launch receipt`, async ({page,context,request},info)=>{
  test.skip(!fixtures || !live || !api || !fixtures[info.project.name], 'Requires isolated W16 Rails fixtures')
  test.setTimeout(120_000)
  const fixture=fixtures[info.project.name]
  const headers={Authorization:`Bearer test_token_${fixture.coach_id}`,'X-Coach-Workspace-Id':String(fixture.workspace_id)}
  const posts:Array<{key:string;body:{review:unknown}}>=[]
  let resolving=false
  await context.route(`${api}/**`,async route=>{
   const path=new URL(route.request().url()).pathname
   const authorized={...route.request().headers(),Authorization:headers.Authorization}
   if(path==='/api/v1/auth/me') {
    const response=await route.fetch({headers:authorized});const payload=await response.json()
    return route.fulfill({response,json:{...payload,user:{...payload.user,clerk_id:'e2e_coach'}}})
   }
   if(path.endsWith('/go_live')) {
    posts.push({key:route.request().headers()['idempotency-key'],body:route.request().postDataJSON()})
    if(!resolving) {
     if(recovery==='server failures') return route.fulfill({status:503,json:{error:'Temporary server failure'}})
     if(posts.length===1) {
      const committed=await route.fetch({headers:authorized})
      expect(committed.status(),await committed.text()).toBe(200)
      return route.abort('failed')
     }
     return route.fulfill({status:403,json:{error:'Sign in again'}})
    }
   }
   return route.continue({headers:authorized})
  })
  if(info.project.name==='desktop-chrome') await page.setViewportSize({width:1366,height:900})
  await page.goto(`${live}/?pilot_e2e_role=coach&pilot_e2e_live_api=true#Coach%20Studio`)
  await page.getByLabel('Program',{exact:true}).selectOption(String(fixture.workspace_id))
  await page.getByRole('navigation',{name:'Coach Studio areas'}).getByRole('button',{name:'Go live',exact:true}).click()
  await expect(page.getByText('Review before going live')).toBeVisible({timeout:60_000})
  await page.getByRole('button',{name:'Approve and go live',exact:true}).click()
  await expect(page.getByRole('alert').filter({hasText:'could not confirm'})).toBeVisible({timeout:60_000})
  await page.getByRole('button',{name:'Finish going live'}).click()
  await expect.poll(()=>posts.length).toBe(2)
  await expect(page.getByRole('button',{name:'Check this update'})).toBeEnabled()
  if(recovery==='expired access') await expect(page.getByRole('alert')).toContainText('Sign in')
  await expect(page.getByRole('alert')).not.toContainText('Nothing went live')
  expect(await page.evaluate(()=>Object.keys(localStorage).filter(key=>key.startsWith('hcfo.goLive:')).length)).toBe(1)
  expect(posts[0]).toEqual(posts[1])
  if((page.viewportSize()?.width ?? 1000)<=620) {
   const finishBox=await page.getByRole('button',{name:'Finish going live'}).boundingBox()
   const checkBox=await page.getByRole('button',{name:'Check this update'}).boundingBox()
   expect(finishBox!.height).toBeGreaterThanOrEqual(44)
   expect(checkBox!.height).toBeGreaterThanOrEqual(44)
   expect(checkBox!.y-(finishBox!.y+finishBox!.height)).toBeGreaterThanOrEqual(8)
  }
  if(evidence) await page.screenshot({path:`${evidence}/${info.project.name}-${recovery}-retained.png`,fullPage:true,scale:'css'})
  resolving=true
  await page.getByRole('button',{name:'Check this update'}).click()
  if(recovery==='server failures') {
   await expect(page.getByRole('status')).toContainText('Nothing went live from this request',{timeout:60_000})
   const delayed=await request.post(`${api}/api/v1/admin/personas/${fixture.persona_id}/go_live`,{headers:{...headers,'Idempotency-Key':posts[0].key},data:posts[0].body})
   expect(delayed.status()).toBe(409)
   await page.getByRole('button',{name:'Review changes',exact:true}).click()
   await expect(page.getByText('Review before going live')).toBeVisible({timeout:60_000})
   await page.getByRole('button',{name:'Approve and go live',exact:true}).click()
   await expect(page.getByRole('status').filter({hasText:'Live for'})).toBeVisible({timeout:60_000})
   expect(posts[2].key).not.toBe(posts[0].key)
  } else {
   await expect(page.getByRole('status').filter({hasText:'Live for'})).toBeVisible({timeout:60_000})
   expect(posts.length).toBe(2)
  }
  expect(await page.evaluate(()=>Object.keys(localStorage).filter(key=>key.startsWith('hcfo.goLive:')).length)).toBe(0)
  if(evidence) await page.screenshot({path:`${evidence}/${info.project.name}-${recovery}-resolved.png`,fullPage:true,scale:'css'})
 })
}
