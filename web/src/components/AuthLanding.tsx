import type { CSSProperties } from 'react'
import { useBrand } from '../contexts/brandContextValue'
import { assistantGreeting } from '../lib/assistantGreeting'
import { SignInButton, SignUpButton } from './AuthControls'
import { BrandFooter, BrandLogo, BrandWordmark } from './BrandChrome'
import './AuthLanding.css'

// Kept outside App.tsx so signed-out visitors see it without downloading the workspace.
export function AuthLanding() {
  const { brand, assistantName } = useBrand()
  const { initial, displayName, greeting, intro } = assistantGreeting(assistantName)
  // Signed-out visitors get the brand provider's placeholder name. Without the
  // assistant's own name the greeting is generic, so leave the bubble out.
  const namedAssistant = assistantName.trim().toLowerCase() !== 'your assistant'
  return (
    <main className="auth-landing">
      <header className="auth-landing-header">
        <div className="auth-landing-mark"><BrandLogo brand={brand} /><BrandWordmark brand={brand} />{brand.organization_name !== 'Household CFO Method' && brand.organization_name !== brand.short_name && <span className="auth-landing-organization">{brand.organization_name}</span>}</div>
        <div className="auth-landing-header-action"><SignInButton><button type="button" className="ui-btn ui-btn--on-deep">Sign in</button></SignInButton></div>
      </header>
      <div className="auth-landing-content">
        <section className="auth-landing-body" aria-labelledby="auth-landing-title">
          <h1 id="auth-landing-title">{brand.welcome_heading || `Welcome to ${brand.product_name}.`}</h1>
          <p className="auth-landing-description">{brand.welcome_description || brand.tagline || 'Your coaching workspace is ready.'}</p>
          <div className="auth-landing-actions">
            <SignInButton><button type="button" className="ui-btn ui-btn--primary ui-btn--on-deep">Sign in</button></SignInButton>
            <SignUpButton><button type="button" className="secondary ui-btn ui-btn--on-deep">Create invited account</button></SignUpButton>
          </div>
          <p className="auth-landing-note">Use the email your invitation was sent to.</p>
          {/* Existing participant promise: SavingsPlanApprovalReview.tsx. */}
          <p className="auth-landing-trust"><span className="ui-dot" aria-hidden="true" />Nothing changes until you confirm.</p>
        </section>
        <div className="auth-landing-product">
          {/* Static, fictional decoration. No workspace components, data, or controls. */}
          <div className="auth-landing-phone" aria-hidden="true">
            <div className="auth-landing-phone-mark"><BrandWordmark brand={brand} /></div>
            <p className="ui-title">November</p>
            <div className="ui-answer">
              <span className="ui-label">What’s left this month</span>
              <p className="ui-figure">$2,180</p>
              <p className="ui-answer__note">Your plan, not your bank balance</p>
              <div className="ui-bar" style={{ '--spent': '26%', '--planned': '39%' } as CSSProperties}><span className="ui-bar__spent" /><span className="ui-bar__planned" /><span className="ui-bar__remainder" /></div>
              <div className="ui-key"><span>Spent<strong>$1,612</strong></span><span>Still planned<strong>$2,408</strong></span><span>Money in<strong>$6,200</strong></span></div>
            </div>
            <div className="ui-card ui-rows">
              <div className="ui-row"><span className="ui-dot" /><span className="ui-row__body"><span className="ui-row__title">2 purchases to check</span><span className="ui-row__detail">Ready for your review</span></span><span className="ui-row__chevron">›</span></div>
              <div className="ui-row"><span className="ui-dot ui-dot--good" /><span className="ui-row__body"><span className="ui-row__title">Breathing room</span><span className="ui-row__detail">2.5 of 6 months of planned costs</span></span><span className="ui-row__chevron">›</span></div>
            </div>
            <div className="ui-card">
              <p className="ui-section">Your year</p>
              <div className="ui-cols" style={{ '--columns': 6 } as CSSProperties}>
                {[36, 42, 58, 58, 90, 25].map((value, index) => <div key={index} className={`ui-cols__column${index === 4 ? ' ui-cols__column--current' : index === 5 ? ' ui-cols__column--attention' : ''}`}><span className="ui-cols__bar" style={{ '--value': `${value}%` } as CSSProperties} /><span className="ui-cols__label">{['Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][index]}</span></div>)}
              </div>
              <p className="auth-landing-year-note">December is your tight month.</p>
            </div>
          </div>
          {namedAssistant && <div className="auth-landing-greeting">
            <span className="ui-monogram" aria-hidden="true">{initial}</span>
            <div className="ui-card"><p className="auth-landing-assistant">{greeting}, I’m {displayName}.</p><p>{intro}</p></div>
          </div>}
        </div>
      </div>
      <BrandFooter privacyFallback />
    </main>
  )
}
