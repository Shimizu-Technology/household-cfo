import { test, expect } from '@playwright/test'
import { mkdir } from 'node:fs/promises'
const live=process.env.HCFO_W16_WEB
const evidence=process.env.HCFO_W16_EVIDENCE

test('Coach Studio platform admin retains a newly created program after reload without repeating its creation notice',async({page},info)=>{
 test.skip(!live,'Requires isolated W16 real Rails API')
 test.setTimeout(120_000)
 if(info.project.name==='desktop-chrome')await page.setViewportSize({width:1366,height:900})
 await page.goto(`${live}/admin/settings?pilot_e2e_role=admin&pilot_e2e_live_api=true`)
 await page.locator('summary',{hasText:'Programs'}).click()
 await page.getByRole('button',{name:'Create program',exact:true}).click()
 const name=`New program ${info.project.name} ${Date.now()}`
 await page.getByLabel('Program name',{exact:true}).fill(name)
 await page.getByLabel('Coach display name',{exact:true}).fill('Mrs. Mel')
 await page.getByText('Invite another coach (optional)',{exact:true}).click()
 await page.getByRole('textbox',{name:/Program owner email/}).fill(`w16-owner-${Date.now()}@example.invalid`)
 await page.getByRole('checkbox',{name:'Send invite email now',exact:true}).uncheck()
 const createdResponse=page.waitForResponse(r=>r.url().endsWith('/coach_workspaces')&&r.request().method()==='POST')
 await page.getByRole('button',{name:'Create program',exact:true}).click()
 const response=await createdResponse
 expect(response.status(),await response.text()).toBe(201)
 const workspace=(await response.json()).coach_workspace
 await expect(page.getByLabel('Program',{exact:true})).toHaveValue(String(workspace.id))
 await expect(page.getByRole('status').filter({hasText:`${name} was created and selected`})).toBeVisible()
 await expect(page.getByRole('status').filter({hasText:'No email was sent; share their sign-in link yourself'})).toBeVisible()
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
 if(evidence)await page.screenshot({path:`${evidence}/${info.project.name}-created-notice.png`,fullPage:true,scale:'css'})
 await page.reload()
 await expect(page.getByLabel('Program',{exact:true})).toHaveValue(String(workspace.id))
 await expect(page.getByRole('status').filter({hasText:'was created and selected'})).toHaveCount(0)
 if(evidence){await mkdir(evidence,{recursive:true});await page.screenshot({path:`${evidence}/${info.project.name}-created-reload.png`,fullPage:true,scale:'css'})}
})

test('Coach Studio Advanced history counts and explains the accepted sign-in problem',async({page},info)=>{
 test.skip(!live||!process.env.HCFO_W16_BLOCKED_WORKSPACE,'Requires isolated W16 accepted-but-unlinked fixture')
 test.setTimeout(120_000)
 if(info.project.name==='desktop-chrome')await page.setViewportSize({width:1366,height:900})
 await page.goto(`${live}/admin/coaching?pilot_e2e_role=admin&pilot_e2e_live_api=true`)
 await page.getByLabel('Program',{exact:true}).selectOption(process.env.HCFO_W16_BLOCKED_WORKSPACE!)
 await page.getByRole('button',{name:'Open history',exact:true}).click()
 await page.getByRole('tab',{name:'Group updates',exact:true}).click()
 await page.getByRole('combobox',{name:'Group',exact:true}).selectOption(process.env.HCFO_W16_BLOCKED_GROUP??'1')
 await page.getByRole('tab',{name:/Update group/}).click()
 await page.getByText('Participant readiness',{exact:true}).click()
 await expect(page.getByText('Finish sign-in',{exact:true})).toBeVisible({timeout:60_000})
 await page.getByText('Update in stages',{exact:true}).click()
 await expect(page.getByText(/Sign-in setup incomplete/)).toBeVisible()
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
 if(evidence){await mkdir(evidence,{recursive:true});await page.screenshot({path:`${evidence}/${info.project.name}-advanced-readiness.png`,fullPage:true,scale:'css'})}
})
