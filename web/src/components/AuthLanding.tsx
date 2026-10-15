import { useBrand } from '../contexts/brandContextValue'
import { brandByline } from '../lib/brandByline'
import { SignInButton, SignUpButton } from './AuthControls'
import { BrandFooter, BrandLogo } from './BrandChrome'

// Kept outside App.tsx so signed-out visitors see it without downloading the workspace.
export function AuthLanding() {
  const { brand } = useBrand()
  return (
    <main className="app loading-state auth-state">
      <section className="hero-panel auth-panel">
        <BrandLogo brand={brand} />
        <p className="eyebrow">{brandByline(brand)}</p>
        <h1>{brand.welcome_heading || `Welcome to ${brand.product_name}.`}</h1>
        <p>{brand.welcome_description || brand.tagline || 'Your secure coaching workspace is ready.'}</p>
        <p className="auth-invitation-copy">Sign in with the email your program invited. Your secure seat determines which coaching experience opens.</p>
        <div className="auth-actions">
          <SignInButton>
            <button type="button">Sign in</button>
          </SignInButton>
          <SignUpButton>
            <button type="button" className="secondary">Create invited account</button>
          </SignUpButton>
        </div>
      </section>
      <BrandFooter privacyFallback />
    </main>
  )
}
