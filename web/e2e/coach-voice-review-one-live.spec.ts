import { test, expect as baseExpect } from '@playwright/test'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
const expect = baseExpect.configure({timeout:60_000})
const directory = process.env.W19_REVIEW_EVIDENCE
const fixtures = directory ? JSON.parse(readFileSync(`${directory}/review-browser-fixtures.json`,'utf8')) : null
const web='http://127.0.0.1:5321', api='http://127.0.0.1:3221'

for(const scenario of ['review','save','invite']) test(`Coach Studio review one ${scenario} preserves choices and outcomes against Rails`, async({page,context,request},info)=>{
 test.skip(!fixtures,'Requires isolated W19 review fixtures and provider-off Rails')
 test.setTimeout(300_000)
 const fixture=fixtures[info.project.name][scenario]
 const headers={Authorization:`Bearer test_token_${fixture.coach_id}`,'X-Coach-Workspace-Id':String(fixture.workspace_id)}
 await context.route(`${api}/**`,async route=>{
  const auth={...route.request().headers(),Authorization:headers.Authorization}
  if(new URL(route.request().url()).pathname==='/api/v1/auth/me'){
   const response=await route.fetch({headers:auth}), payload=await response.json()
   return route.fulfill({response,json:{...payload,user:{...payload.user,clerk_id:'e2e_coach'}}})
  }
  return route.continue({headers:auth})
 })
 if(info.project.name==='desktop-chrome')await page.setViewportSize({width:1366,height:900})
 const shot=async(name:string)=>{
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
  if(directory){mkdirSync(`${directory}/shots`,{recursive:true});await page.screenshot({path:`${directory}/shots/${info.project.name}-${scenario}-${name}.png`,fullPage:true,scale:'css'})}
 }
 const state=async()=>{
  const response=await request.post(`${api}/api/v1/admin/personas/${fixture.persona_id}/setup_sessions`,{headers,data:{}})
  expect(response.status()).toBe(201);return (await response.json()).session
 }
 await page.goto(`${web}/?pilot_e2e_role=coach&pilot_e2e_live_api=true&coach_area=${scenario==='invite'?'people':'assistant'}&coach_task=voice#Coach%20Studio`)
 const areas=page.getByRole('navigation',{name:'Coach Studio areas'})
 await expect(areas).toBeVisible()
 if(scenario==='invite'){
  await page.getByText('Group invitations & access',{exact:true}).click()
  await page.locator('summary').filter({hasText:/^Add a participant$/}).click()
  const jane=`jane-${fixture.coach_id}@example.test`,bob=`bob-${fixture.coach_id}@example.test`
  await page.getByLabel('Paste email addresses').fill(`Jane Doe <${jane}>, Bob <${bob}>, ${fixture.existing}, ${fixture.refused}\n<jane@example.test>\nweird@exa mple.com\njane@example..test`)
  await page.getByRole('button',{name:'Review email list'}).click()
  await expect(page.getByRole('heading',{name:'Review 4 people for W19 review group'})).toBeVisible()
  await expect(page.getByRole('alert')).toContainText('weird@exa mple.com')
  await shot('review-invalid-lines')
  const creates:Record<string,unknown>[]=[]
  page.on('response',async response=>{if(response.url()===`${api}/api/v1/admin/users`&&response.request().method()==='POST'&&response.ok())creates.push(await response.json())})
  await page.getByRole('button',{name:'Add these 4 people'}).click()
  await expect(page.getByRole('status').filter({hasText:'2 people added. 1 already in this group.'})).toBeVisible({timeout:180_000})
  await expect(page.getByRole('alert')).toContainText(fixture.refused)
  await expect(page.getByRole('alert')).toContainText('platform administrator')
  await expect(page.getByLabel('Paste email addresses')).toHaveValue('')
  await expect(page.getByRole('button',{name:'Reload groups'})).toBeEnabled()
  await expect(page.locator('.coach-participants-list > li')).toHaveCount(3)
  await shot('partial-success')
  expect(creates.length).toBe(2);expect(creates.every(value=>!('invitation_error' in value))).toBe(true)
  const response=await request.get(`${api}/api/v1/admin/users`,{headers});expect(response.status()).toBe(200)
  const body=await response.json(), users=body.users
  expect(users.filter((user:{email:string})=>[jane,bob,fixture.existing].includes(user.email))).toHaveLength(3)
  return
 }
 await expect(page.getByText('Your voice suggestions',{exact:true})).toBeVisible()
 await expect(page.getByText('Answers: 3 to 4 sentences',{exact:true})).toBeVisible()
 await page.locator('summary').filter({hasText:/^Review each suggestion$/}).click()
 const celebration=page.getByRole('checkbox',{name:'Keep: Celebrate small wins.'})
 await celebration.uncheck()
 await expect(page.getByRole('checkbox',{name:'Keep: Give the direct answer first, then ask one practical question.'})).toBeChecked()
 await shot('individual-choices')
 if(scenario==='save'){
  let previews=0
  page.on('request',request=>{if(request.url().endsWith(`/personas/${fixture.persona_id}/preview`))previews+=1})
  await page.getByRole('button',{name:'Use selected suggestions'}).click()
  await expect(page.getByRole('heading',{name:'Hear your assistant, then go live'})).toBeVisible()
  await expect(page.getByRole('alert')).toContainText("The preview didn't come through")
  const response=await request.get(`${api}/api/v1/admin/personas/${fixture.persona_id}`,{headers}),saved=(await response.json()).persona
  expect(saved.draft.identity.assistant_name).toBe('Lani');expect(saved.draft.response_shape.min_sentences).toBe(3);expect(saved.draft.response_shape.max_sentences).toBe(4)
  expect(saved.draft.coaching.do).toEqual(['Give the direct answer first, then ask one practical question.']);expect(saved.draft.coaching.do_not).toEqual(['Never shame anyone.'])
  expect(saved.draft.phrases.map((p:{text:string})=>p.text)).toEqual(['Chelu, pump the brakes.'])
  if(directory)writeFileSync(`${directory}/${info.project.name}-selected-saved.json`,JSON.stringify(saved,null,2))
  const before=previews;expect(before).toBe(1)
  await page.goBack();await expect(page.getByLabel('Message Mia')).toBeVisible()
  await page.goForward();await expect(page.getByRole('heading',{name:'Hear your assistant, then go live'})).toBeVisible()
  await expect(page.getByRole('button',{name:'Preview answers',exact:true})).toBeEnabled()
  expect(previews).toBe(before)
  await shot('saved-and-history')
  return
 }
 // A failed model-off follow-up must retain her unchecked choice and message.
 await page.getByLabel('Message Mia').fill('Keep these choices, please.')
 await page.getByRole('button',{name:'Send to Mia',exact:true}).click()
 await expect(page.getByRole('alert')).toContainText('could not prepare')
 await expect(celebration).not.toBeChecked()
 await page.getByLabel('Message Mia').fill('')
 if (!(await page.getByRole('button',{name:'Teaching',exact:true}).isVisible())) await page.locator('summary').filter({hasText:/^More settings$/}).click()
 await page.getByRole('button',{name:'Teaching',exact:true}).click()
 await page.getByLabel('Teaching method').fill('Keep this unsaved teaching method.')
 await page.getByRole('button',{name:'Save and preview answers'}).click()
 const warning=page.getByRole('alertdialog',{name:'Discard pending voice suggestions?'})
 await expect(warning).toContainText('pending voice suggestions')
 await shot('teaching-warning')
 await warning.getByRole('button',{name:'Keep suggestions'}).click()
 expect((await state()).proposal).toBeTruthy()
 await expect(page.getByLabel('Teaching method')).toHaveValue('Keep this unsaved teaching method.')
 await page.getByRole('button',{name:'Voice',exact:true}).click()
 await page.getByRole('alertdialog').getByRole('button',{name:'Discard changes',exact:true}).click()
 await expect(page.getByText('Your voice suggestions',{exact:true})).toBeVisible()
 // Simulated 409 tests visibility; successful reject then goes through Rails.
 await page.route(`**/proposals/*/apply`,route=>route.fulfill({status:409,json:{error:'Your saved voice changed. Nothing was saved.'}}))
 await page.getByRole('button',{name:'Review in form',exact:true}).click()
 await page.getByRole('button',{name:'Use all suggestions',exact:true}).click()
 await expect(page.getByRole('alert')).toBeVisible();await expect(page.getByRole('alert')).toContainText('Your saved voice changed')
 await shot('focused-error')
 await page.getByRole('button',{name:'Reject proposal',exact:true}).click()
 await expect(page.getByLabel('Message Mia')).toBeVisible();await expect(page.getByLabel('Message Mia')).toBeEnabled()
 expect((await state()).proposal).toBeNull()
 await shot('rejected-composer')
 if (!(await page.getByRole('button',{name:'Teaching',exact:true}).isVisible())) await page.locator('summary').filter({hasText:/^More settings$/}).click()
 await page.getByRole('button',{name:'Teaching',exact:true}).click()
 await page.getByLabel('Teaching method').fill('Samoans always overspend.')
 await page.getByRole('button',{name:'Save and preview answers'}).click()
 await expect(page.getByRole('alert')).toContainText('This description could stereotype a group of people.')
 await expect(page.getByLabel('Teaching method')).toHaveValue('Samoans always overspend.')
 await shot('teaching-refusal')
 await page.getByLabel('Teaching method').fill('Ask one practical question.')
 await page.getByRole('button',{name:'Save and preview answers'}).click()
 await expect(page.getByRole('heading',{name:'Hear your assistant, then go live'})).toBeVisible()
 const savedResponse=await request.get(`${api}/api/v1/admin/personas/${fixture.persona_id}`,{headers})
 expect((await savedResponse.json()).persona.draft.coaching.method).toBe('Ask one practical question.')
})

test('Coach Studio review one preserves Admin history identity and a declined dirty Back against Rails',async({page,context},info)=>{
 test.skip(!directory,'Requires the isolated W19 admin history fixture')
 test.setTimeout(300_000)
 const fixture=JSON.parse(readFileSync(`${directory}/admin-history-fixture.json`,'utf8'))
 await context.route(`${api}/**`,async route=>{
  const headers={...route.request().headers(),Authorization:`Bearer test_token_${fixture.coach_id}`}
  if(new URL(route.request().url()).pathname==='/api/v1/auth/me'){
   const response=await route.fetch({headers}),payload=await response.json()
   return route.fulfill({response,json:{...payload,user:{...payload.user,clerk_id:'e2e_coach'}}})
  }
  return route.continue({headers})
 })
 if(info.project.name==='desktop-chrome')await page.setViewportSize({width:1366,height:900})
 await page.goto(`${web}/?pilot_e2e_role=coach&pilot_e2e_live_api=true&coach_area=people&coach_task=voice#Coach%20Studio`)
 const picker=page.getByLabel('Program',{exact:true})
 await expect(picker).toBeVisible();await picker.selectOption(String(fixture.workspace_id))
 await expect(page.getByText('Get your program ready',{exact:true})).toBeVisible()
 await page.getByRole('button',{name:'Your assistant',exact:true}).click()
 await expect(page.getByLabel('Assistant name')).toBeVisible()
 const index=await page.evaluate(()=>history.state.appHistoryPosition)
 await page.getByRole('link',{name:'Admin',exact:true}).click()
 await expect(page.getByRole('heading',{name:'Program operations',exact:true})).toBeVisible()
 await page.goBack();await expect(page.getByLabel('Assistant name')).toBeVisible()
 expect(await page.evaluate(()=>history.state.appHistoryPosition)).toBe(index)
 await page.getByLabel('Assistant name').fill('Keep this private unfinished name')
 await page.goBack()
 await page.getByRole('alertdialog').getByRole('button',{name:'Keep editing',exact:true}).click()
 await expect.poll(()=>new URL(page.url()).searchParams.get('coach_area')).toBe('assistant')
 await expect(page.getByLabel('Assistant name')).toHaveValue('Keep this private unfinished name')
 await page.goBack()
 await page.getByRole('alertdialog').getByRole('button',{name:'Discard changes',exact:true}).click()
 await expect(page.getByText('Get your program ready',{exact:true})).toBeVisible()
 await page.goForward();await expect(page.getByLabel('Assistant name')).toHaveValue('Mia')
 if(directory)await page.screenshot({path:`${directory}/shots/${info.project.name}-admin-history.png`,fullPage:true,scale:'css'})
})


test('Coach Studio review two keeps the saved history entry across repeated Admin visits',async({page,context},info)=>{
 test.skip(!directory,'Requires the isolated W19 admin history fixture')
 test.setTimeout(180_000)
 const fixture=JSON.parse(readFileSync(`${directory}/admin-history-fixture.json`,'utf8'))
 await context.route(`${api}/**`,async route=>{
  const headers={...route.request().headers(),Authorization:`Bearer test_token_${fixture.coach_id}`}
  if(new URL(route.request().url()).pathname==='/api/v1/auth/me'){
   const response=await route.fetch({headers}),payload=await response.json()
   return route.fulfill({response,json:{...payload,user:{...payload.user,clerk_id:'e2e_coach'}}})
  }
  return route.continue({headers})
 })
 if(info.project.name==='desktop-chrome')await page.setViewportSize({width:1366,height:900})
 await page.goto(`${web}/?pilot_e2e_role=coach&pilot_e2e_live_api=true&coach_area=people&coach_task=voice#Coach%20Studio`)
 await page.getByLabel('Program',{exact:true}).selectOption(String(fixture.workspace_id))
 await expect(page.getByText('Get your program ready',{exact:true})).toBeVisible()
 await page.getByRole('button',{name:'Your assistant',exact:true}).click()
 await expect(page.getByLabel('Assistant name')).toBeVisible()
 await page.getByRole('link',{name:'Admin',exact:true}).click()
 await expect(page.getByRole('heading',{name:'Program operations',exact:true})).toBeVisible()
 await page.getByRole('link',{name:'Coach Studio',exact:true}).click()
 await page.getByLabel('Assistant name').fill('Keep this private return-visit edit')
 const savedUrl=page.url(),savedPosition=await page.evaluate(()=>history.state.appHistoryPosition)
 await page.evaluate(()=>history.go(-3))
 await page.getByRole('alertdialog').getByRole('button',{name:'Keep editing',exact:true}).click()
 await expect(page).toHaveURL(savedUrl)
 expect(await page.evaluate(()=>history.state.appHistoryPosition)).toBe(savedPosition)
 await expect(page.getByLabel('Assistant name')).toHaveValue('Keep this private return-visit edit')
 if(directory)await page.screenshot({path:`${directory}/shots/${info.project.name}-review-two-return-history.png`,fullPage:true,scale:'css'})
})
