import { shortAssistantName } from './assistantName'

// Shared by the public front door and empty chat. Keep the landing independent
// of ChatHistory and the rest of the workspace bundle.
export function assistantGreeting(assistantName: string) {
  const displayName = shortAssistantName(assistantName)
  const hers = displayName === 'Mia'
  return {
    displayName,
    initial: Array.from(assistantName.trim())[0]?.toUpperCase() ?? 'A',
    greeting: hers ? 'Håfa adai' : 'Hi',
    intro: hers
      ? 'No judgment, no jargon. Tell me what’s going on with your money.'
      : 'Tell me what changed, like a purchase, a bill, or a raise, or ask what to do next. I’ll prepare anything that changes your numbers for you to review first.',
  }
}
