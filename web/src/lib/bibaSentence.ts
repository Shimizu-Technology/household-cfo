import { savingsPlainDollars } from './savingsChallenge'
import type { CheckpointSnapshot } from './dailyChallenge'

// One plain sentence with the participant's real figure. An unknown total is never shown as $0.
export function bibaSentence(snapshot: CheckpointSnapshot) {
  const { reported_cents: reported, target_cents: target, achieved } = snapshot.savings
  if (reported === null || reported === undefined) return 'Your review is saved.'
  const setAside = savingsPlainDollars(reported)
  if (target === null || target === undefined) return `You’ve set aside ${setAside} so far.`
  return achieved
    ? `You’ve set aside ${setAside}, which reaches your ${savingsPlainDollars(target)} target.`
    : `You’ve set aside ${setAside} so far, toward your ${savingsPlainDollars(target)} target.`
}
