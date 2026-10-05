/// <reference types="node" />
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const stylesheet = (name: string) => readFileSync(new URL(`./${name}.css`, import.meta.url), 'utf8')

describe('participant control brand contract', () => {
  it('keeps participant entry workflows on shared control, focus and readable-input rules', () => {
    const common = stylesheet('ParticipantControls')
    for (const container of ['statement-source-review', 'daily-dialog', 'baseline-dialog', 'optional-debt-dialog', 'evidence-dialog', 'challenge-privacy-dialog']) {
      expect(common).toContain(`.${container}`)
    }
    expect(common).toMatch(/min-height: 44px/)
    expect(common).toMatch(/font-size: 1rem/)
    expect(common).toMatch(/:focus-visible\s*\{[^}]*var\(--focus-color/s)
    for (const name of ['StatementSourceReview', 'ChallengeToday', 'BaselineReview', 'OptionalDebtReview', 'SavingsEvidenceDialog', 'ChallengePrivacyDialog']) {
      expect(stylesheet(name)).toContain("@import './ParticipantControls.css'")
      expect(stylesheet(name)).not.toMatch(/--forest|#245548|#16604c|#367453/)
    }
  })

  it('uses the resolved brand foreground with evidence primary and selected actions', () => {
    const evidence = stylesheet('SavingsEvidenceDialog')
    expect(evidence).toMatch(/button\[type=submit\][^{]*\{[^}]*var\(--action-primary[^}]*var\(--action-on-primary/s)
    expect(evidence).toMatch(/button\[aria-pressed=true\][^{]*\{[^}]*var\(--action-primary[^}]*var\(--action-on-primary/s)
  })
})
