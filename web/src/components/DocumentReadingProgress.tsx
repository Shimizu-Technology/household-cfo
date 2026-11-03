type Progress = { stage?: string; page?: number; page_count?: number }

export function DocumentReadingProgress({ progress }: { progress?: Progress }) {
  const count = progress?.page_count
  const page = progress?.page
  const pagesKnown = Number.isInteger(count) && Number.isInteger(page) && count! > 0 && page! > 0 && page! <= count!
  return <p>{pagesKnown ? `Reading your statement… ${page} of ${count} pages.` : progress?.stage === 'checking' ? 'Checking your saved file…' : 'Reading your saved file…'} You can leave this page; your file is saved and nothing changes until you review it.</p>
}
