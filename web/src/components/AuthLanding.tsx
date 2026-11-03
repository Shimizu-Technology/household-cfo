import { useBrand } from '../contexts/brandContextValue'
import { SignInButton, SignUpButton } from './AuthControls'
import { BrandFooter, BrandLogo } from './BrandChrome'
import './AuthLanding.css'

// Kept outside App.tsx so signed-out visitors see it without downloading the workspace.
export function AuthLanding() {
  const { brand } = useBrand()
  return (
    <main className="auth-landing">
      <header className="auth-landing-mark">
        <BrandLogo brand={brand} />
        <span>{brand.organization_name || brand.product_name}</span>
      </header>
      <section className="auth-landing-body" aria-labelledby="auth-landing-title">
        <h1 id="auth-landing-title">{brand.welcome_heading || `Welcome to ${brand.product_name}.`}</h1>
        <p>{brand.welcome_description || brand.tagline || 'Your coaching workspace is ready.'}</p>
        <div className="auth-landing-actions">
          <SignInButton>
            <button type="button">Sign in</button>
          </SignInButton>
          <SignUpButton>
            <button type="button" className="secondary">Create invited account</button>
          </SignUpButton>
        </div>
        <p className="auth-landing-note">Use the email your invitation was sent to.</p>
      </section>
      <BrandFooter privacyFallback />
    </main>
  )
}
