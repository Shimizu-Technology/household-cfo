import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { mkdir } from 'node:fs/promises'
const fixtures = process.env.HCFO_W16_FIXTURES ? JSON.parse(readFileSync(process.env.HCFO_W16_FIXTURES, 'utf8')) : null
const live = process.env.HCFO_W16_WEB
const api = process.env.HCFO_W16_API
const evidence = process.env.HCFO_W16_EVIDENCE

test('Coach Studio live follow-ups recover a lost atomic launch response and confirm a created program', async ({page,context,request}, info) => {
  test.skip(!fixtures || !live || !api || !fixtures[info.project.name], 'Requires isolated W16 Rails fixtures')
  test.setTimeout(180_000)
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
      if(launchKey) expect(key).toBe(launchKey)
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
  const payload=await response.json()
  const workspace=payload.coach_workspace ?? payload.workspace
  const saved=await request.get(`${api}/api/v1/admin/coach_workspaces/${workspace.id}`,{headers:{...headers,'X-Coach-Workspace-Id':String(workspace.id)}})
  expect(saved.status()).toBe(200)
  expect(JSON.stringify(await saved.json())).toContain(name)
})
