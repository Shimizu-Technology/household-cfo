// Rules for scripts/audit-dependencies.mjs, kept free of npm calls so they can be tested.
export const failingSeverities = new Set(['moderate', 'high', 'critical'])

// Each exception names one advisory, the only package it may come from, why it
// is safe to ship around, and the date it stops applying. Remove an entry as
// soon as a patched release lands in the lockfile.
export const exceptions = [
  {
    advisory: 'https://github.com/advisories/GHSA-fc5q-39xc-vjpf',
    packageName: 'picomatch',
    // Newest release the advisory covers. Any later release means a fix may exist.
    vulnerableThrough: '4.0.7',
    expires: '2027-01-31',
    reason:
      'ReDoS from attacker-controlled glob patterns. picomatch is only reached through ' +
      'dev/build tooling (vite, vitest, tinyglobby, typescript-eslint) matching globs we write; ' +
      'it is not in the production dependency tree or the built bundle. No patched release exists.',
  },
]

const parts = (version) => {
  const [core, prerelease] = version.split('-', 2)
  return { core: core.split('.').map(Number), prerelease }
}

// True when version sorts after through. A prerelease of a later version counts,
// since it may carry the fix.
export function isNewer(version, through) {
  const a = parts(version)
  const b = parts(through)
  for (let i = 0; i < 3; i++) {
    if (a.core[i] !== b.core[i]) return a.core[i] > b.core[i]
  }
  return !a.prerelease && Boolean(b.prerelease)
}

// Every advisory object in an `npm audit --json` report, once each.
export function advisoriesIn(report) {
  const advisories = new Map()
  for (const vulnerability of Object.values(report.vulnerabilities ?? {})) {
    for (const via of vulnerability.via) {
      // String entries point at another package's advisory; only objects are advisories.
      if (typeof via === 'object') advisories.set(`${via.url} ${via.name}`, via)
    }
  }
  return [...advisories.values()]
}

// publishedVersions(packageName) returns every version on the registry.
export function evaluate(report, { today, publishedVersions, rules = exceptions }) {
  const failures = []
  const allowed = []
  const used = new Set()
  const advisories = advisoriesIn(report)
  for (const advisory of advisories) {
    if (!failingSeverities.has(advisory.severity)) continue
    const exception = rules.find((entry) => entry.advisory === advisory.url && entry.packageName === advisory.name)
    if (!exception) {
      failures.push(`${advisory.severity}: ${advisory.name} ${advisory.range} ${advisory.url} (${advisory.title})`)
      continue
    }
    used.add(exception)
    if (today > exception.expires) {
      failures.push(`${advisory.name} ${advisory.url}: exception expired on ${exception.expires}; re-evaluate it`)
      continue
    }
    const newer = publishedVersions(exception.packageName).filter((version) => isNewer(version, exception.vulnerableThrough))
    if (newer.length > 0) {
      failures.push(
        `${exception.packageName} ${newer.join(', ')} published since the ${exception.advisory} exception ` +
          `(vulnerable through ${exception.vulnerableThrough}); update the lockfile and remove the exception if it is fixed`,
      )
      continue
    }
    allowed.push(exception)
  }
  const unused = rules.filter((exception) => !used.has(exception))
  return { failures, allowed, unused, checked: advisories.length }
}
