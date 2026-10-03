import type { MiaAnswerPresentation } from '../api'
import { SafeMessageText } from './SafeMessageText'
import { useBrand } from '../contexts/brandContextValue'

const basisLabels: Record<MiaAnswerPresentation['basis'], string> = {
  saved_household: 'Saved household records',
  saved_household_plus_scenario: 'Saved household records + your scenario',
  scenario_only: 'Your scenario only',
}

export function MiaReadOnlyAnswer({ presentation, idPrefix }: { presentation: MiaAnswerPresentation; idPrefix: string }) {
  const { assistantName } = useBrand()
  const scenarioTitleId = `${idPrefix}-scenario-title`

  return (
    <div className="mia-read-only-answer" role="group" aria-label={`${assistantName} read-only answer`}>
      <p className="mia-answer-basis"><span>Answer basis</span>{basisLabels[presentation.basis]}</p>
      <p className="mia-answer-lead">{presentation.lead}</p>
      <ol className="mia-answer-sections" aria-label={`${assistantName} answer sections`}>
        {presentation.sections.map((section, index) => {
          const titleId = `${idPrefix}-section-${section.id}`
          return (
            <li key={section.id}>
              <section aria-labelledby={titleId}>
                <div className="mia-answer-section-heading">
                  <span aria-hidden="true">{index + 1}</span>
                  <h4 id={titleId}>{section.title}</h4>
                </div>
                <SafeMessageText content={section.body} allowFormatting />
              </section>
            </li>
          )
        })}
      </ol>
      {presentation.scenario && (
        <aside className="mia-answer-scenario" role="note" aria-labelledby={scenarioTitleId}>
          <div>
            <h4 id={scenarioTitleId}>Scenario only · not saved</h4>
            <p>{assistantName} used these values for this answer. Your saved household records did not change.</p>
          </div>
          <dl>
            {presentation.scenario.values.map((value, index) => (
              <div key={`${value.label}-${index}`}>
                <dt>{value.label}</dt>
                <dd>{value.display_value}</dd>
              </div>
            ))}
          </dl>
        </aside>
      )}
    </div>
  )
}
