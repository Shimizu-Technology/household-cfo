import type { BudgetData, DashboardData } from '../api'
import { formatRunway } from '../lib/runway'
import { YearOutlook } from './YearOutlook'
import { guamTodayIso } from '../lib/householdDate'
import { formatReviewMoney } from '../lib/reviewMoney'
import { useEffect, useRef, type CSSProperties, type ReactNode } from 'react'
import { useBrand } from '../contexts/brandContextValue'

// First reveal belongs to this page lifetime, so tab remounts do not replay it.
const revealedTracks = new Set<string>()

type HomeScreenProps = {
  starterPrompts?: { label: string; message: string }[]
  onChoosePrompt?: (message: string) => void
  dashboard: DashboardData
  budget: BudgetData
  onAskMia: () => void
  onReviewTransactions: () => void
  onReviewMiaActions: () => void
  pendingImportCount: number
  onReviewImports: () => void
  onOpenDebt?: () => void
  onOpenBudget?: () => void
  onOpenProfile?: () => void
  onOpenAccounts?: () => void
  incomeKnown?: boolean
  planKnown?: boolean
  canAskMia?: boolean
  canReviewTransactions?: boolean
}

export function HomeScreen({ starterPrompts = [], onChoosePrompt, dashboard, budget, onAskMia, onReviewTransactions, onReviewMiaActions, pendingImportCount, onReviewImports, onOpenDebt, onOpenBudget, onOpenProfile, onOpenAccounts, incomeKnown = true, planKnown = true, canAskMia = true, canReviewTransactions = true }: HomeScreenProps) {
  const { assistantName } = useBrand()
  const screenRef = useRef<HTMLElement>(null)
  useEffect(() => {
    if (typeof IntersectionObserver === 'undefined' || matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const observer = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue
        const key = entry.target.getAttribute('data-reveal-key') ?? (entry.target.classList.contains('ui-bar') ? 'answer' : 'cushion')
        if (!revealedTracks.has(key)) {
          revealedTracks.add(key)
          entry.target.animate([{ transform: 'scaleX(0)' }, { transform: 'scaleX(1)' }], { duration: 400, easing: 'cubic-bezier(0.23, 1, 0.32, 1)' })
        }
        observer.unobserve(entry.target)
      }
    })
    screenRef.current?.querySelectorAll('.home-month-answer .ui-bar, .home-cushion .ui-track__fill, .home-outlook-track .ui-track__fill').forEach(element => observer.observe(element))
    return () => observer.disconnect()
  }, [dashboard.month_answer?.money_in_cents, dashboard.month_answer?.planned_out_cents, dashboard.month_answer?.runway_months, budget.annual_plan])
  const { action_center: actionCenter, month_answer: answer } = dashboard
  const plan = budget.annual_plan?.year === actionCenter.current_year ? budget.annual_plan : null
  const left = answer?.plan_left_cents
  const purchaseCount = canReviewTransactions ? actionCenter.transaction_review_count : 0
  const needsReview = purchaseCount > 0 || pendingImportCount > 0 || (canAskMia && actionCenter.mia_action_review_count > 0)
  const goal = dashboard.readiness_path.target_runway_months
  const known = answer?.money_in_cents != null && answer.planned_out_cents != null && left != null
  const income = Math.max(0, answer?.money_in_cents ?? 0)
  const spent = Math.min(income, Math.max(0, answer?.spent_so_far_cents ?? 0))
  // Debt minimums stay in the plan; pending purchases never become spending.
  const stillPlanned = answer?.category_left_cents != null && answer.category_plan_cents != null
    ? Math.max(0, answer.category_left_cents) + Math.max(0, (answer.planned_out_cents ?? 0) - answer.category_plan_cents)
    : Math.max(0, (answer?.planned_out_cents ?? 0) - spent)
  const barStyle = { '--spent': `${income > 0 ? spent / income * 100 : 0}%`, '--planned': `${income > 0 ? Math.min(income - spent, stillPlanned) / income * 100 : 0}%` } as CSSProperties
  const miaName = `Tell ${assistantName} what changed`
  const miaContent = <><span className="ui-monogram" aria-hidden="true" data-initial={Array.from(assistantName)[0]} /><span className="ui-row__body"><span className="ui-row__title">{miaName}</span></span><Chevron /></>
  return <div className="home-layout"><section ref={screenRef} className="screen-grid home-screen">
    <div className="screen-heading home-heading">
      <h2 data-page-heading tabIndex={-1}>Home</h2>
      <p>{actionCenter.current_month_label}{actionCenter.current_year !== Number(guamTodayIso().slice(0, 4)) ? ` ${actionCenter.current_year}` : ''}</p>
    </div>
    <section className={`home-month-answer ui-answer${left != null && left < 0 ? ' home-month-answer--short' : ''}`} aria-label="Your month in money">
      <HomeMoneyValues answer={answer} />
      <p className="home-plan-caveat ui-answer__note">{answer?.missing_plan_inputs?.length ? `Still to add: ${answer.missing_plan_inputs.map(input => input.label).join(', ')}.` : answer?.main_income_missing ? 'Still to add: your main income.' : left == null ? 'Add your income, planned costs, and debt minimums to see what’s left.' : 'This is your plan, not your bank balance.'}</p>
      {known && <div className="ui-bar" aria-hidden="true" style={barStyle}>
        {answer?.spent_so_far_cents != null && <span className="ui-bar__spent" />}
        <span className="ui-bar__planned" /><span className="ui-bar__remainder" />
      </div>}
      <p className="home-spent"><span><i className="ui-dot ui-dot--spent" aria-hidden="true" />Spent so far this month:</span>{' '}<strong>{answer?.spent_so_far_cents == null ? 'Not known yet' : formatReviewMoney(answer.spent_so_far_cents)}</strong></p>
      {answer?.planned_out_cents == null && dashboard.coach_read?.action === 'open_debt' && onOpenDebt && <button type="button" className="ui-btn ui-btn--tonal home-answer-recovery" onClick={onOpenDebt}>Add debt minimums</button>}
      {answer && answer.pending_count == null && <p className="home-answer-pending ui-answer__note">More purchases may be waiting. Check Review before your next money decision.</p>}
    </section>
    {needsReview && <section className="home-needs-you home-other-reviews ui-card" aria-label="Needs you">
      <h3 className="ui-section home-needs-heading">Needs you</h3>
      <div className="ui-rows">
        {purchaseCount > 0 && <div className="home-next-action"><HomeAction onClick={onReviewTransactions}>{`Review ${purchaseCount} purchase${purchaseCount === 1 ? '' : 's'}`}</HomeAction></div>}
        {pendingImportCount > 0 && <HomeAction secondary onClick={onReviewImports}>{pendingImportCount} file{pendingImportCount === 1 ? '' : 's'} waiting for review</HomeAction>}
        {canAskMia && actionCenter.mia_action_review_count > 0 && <HomeAction secondary onClick={onReviewMiaActions}>{actionCenter.mia_action_review_count} {assistantName} change{actionCenter.mia_action_review_count === 1 ? '' : 's'} waiting for review</HomeAction>}
      </div>
    </section>}
    <section className="home-cushion ui-card" aria-label="Your emergency cushion">
      <h3>{answer?.runway_months == null ? 'Your emergency cushion' : formatRunway(answer.runway_months)}</h3>
      <p>{answer?.readiness_guidance ?? 'Add the missing starting numbers before judging your cushion.'}</p>
      {answer?.runway_months == null && answer?.cushion_missing_inputs?.map(input => {
        const open = { profile: onOpenProfile, budget: onOpenBudget, debt: onOpenDebt, accounts: onOpenAccounts }[input.destination]
        const label = { profile: 'Add income', budget: 'Add planned costs', debt: 'Add debt minimums', accounts: 'Add account balances' }[input.destination]
        return open && <HomeAction secondary key={input.destination} onClick={open}>{label}</HomeAction>
      })}
      {answer?.runway_months != null && <>
        {goal > 0 && <div className="ui-track" aria-hidden="true" style={{ '--value': `${Math.max(0, Math.min(100, answer.runway_months / goal * 100))}%` } as CSSProperties}><span className="ui-track__fill" /><span className="ui-track__goal" /></div>}
        <p className="home-cushion-goal">Goal: {goal} months of planned costs.</p>
      </>}
    </section>
    {plan && <YearOutlook plan={plan} currentMonth={answer?.month ?? actionCenter.current_month_index + 1} moneyKnown={incomeKnown && planKnown && answer?.money_in_cents != null && answer?.planned_out_cents != null} />}
    {onOpenBudget && <p className="home-plan-link"><button className="ui-btn ui-btn--text" type="button" onClick={onOpenBudget}>Plan details →</button></p>}
    {canAskMia && <section className="home-mia ui-card" aria-label={assistantName}>
      <div className="home-next-action"><button className="ui-row" type="button" onClick={onAskMia}>{miaContent}</button></div>
      {onChoosePrompt && <div className="home-mia-prompts">{starterPrompts.map(prompt => <button type="button" className="ui-chip" key={prompt.label} onClick={() => onChoosePrompt(prompt.message)}>{prompt.label}</button>)}</div>}
    </section>}
  </section></div>
}

function Chevron() {
  return <svg className="ui-row__chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="m6 4 4 4-4 4" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" /></svg>
}

function HomeAction({ children, onClick, secondary = false, className = '' }: { children: ReactNode; onClick: () => void; secondary?: boolean; className?: string }) {
  return <button type="button" className={`ui-row ${secondary ? 'text-button' : ''} ${className}`} onClick={onClick}><span className={`ui-dot${secondary ? ' ui-dot--attention' : ''}`} aria-hidden="true" /><span className="ui-row__body"><span className="ui-row__title">{children}</span></span><Chevron /></button>
}

export function HomeMoneyValues({ answer }: { answer?: DashboardData['month_answer'] }) {
  const left = answer?.plan_left_cents
  return <dl className="home-money-values">
    <MoneyValue hero label={left != null && left < 0 ? 'Short of the plan' : 'What’s left · planned'} cents={left == null ? left : Math.abs(left)} />
    <MoneyValue label="Money out · planned" cents={answer?.planned_out_cents} />
    <MoneyValue label="Money in" cents={answer?.money_in_cents} />
  </dl>
}

/** The current month answer can travel with plan details without recalculation. */
export function MonthPlanLine({ answer }: { answer?: DashboardData['month_answer'] }) {
  if (!answer || (answer.money_in_cents == null && answer.planned_out_cents == null)) return null
  const money = (value: number | null | undefined) => value == null ? 'Not entered' : formatReviewMoney(value)
  const left = answer.plan_left_cents
  return <p className="month-plan-line" aria-label="Current month plan">
    {answer.period_label} plan: <strong>{money(answer.money_in_cents)}</strong> money in · <strong>{money(answer.planned_out_cents)}</strong> planned out · <strong>{money(left == null ? left : Math.abs(left))}</strong> {left != null && left < 0 ? 'short' : 'left'}.
    {' '}Plan figures, not a bank balance.
  </p>
}

/** The hero figure is the one answer the screen leads with, set in the serif (docs/design-system.md). */
function MoneyValue({ label, cents, hero = false }: { label: string; cents: number | null | undefined; hero?: boolean }) {
  const value = cents == null ? 'Not entered' : formatReviewMoney(cents)
  return <div className={hero && cents != null ? 'is-hero' : undefined}><dt>{label}</dt><dd className={[hero && cents != null ? 'ui-figure' : '', cents != null && value.length > 9 ? 'is-long-money' : ''].filter(Boolean).join(' ') || undefined}>{value}</dd></div>
}
