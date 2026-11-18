// Fails CI on any npm advisory at moderate or above in the full dependency tree,
// except the exact exceptions below. Production dependencies are audited
// separately with `npm audit --omit=dev` and get no exceptions at all.
import { execFileSync } from 'node:child_process'

const failingSeverities = new Set(['moderate', 'high', 'critical'])

// Each exception names one advisory, the only package it may come from, why it
// is safe to ship around, and the date it stops applying. Remove an entry as
// soon as a patched release lands in the lockfile.
const exceptions = [
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

function runNpm(args) {
  try {
    return execFileSync('npm', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] })
  } catch (error) {
    // npm audit exits nonzero whenever it finds anything; the JSON is still on stdout.
    if (error.stdout) return error.stdout
    throw error
  }
}

const report = JSON.parse(runNpm(['audit', '--json']))
if (report.error) {
  console.error(`npm audit failed: ${report.error.summary ?? JSON.stringify(report.error)}`)
  process.exit(1)
}

const today = new Date().toISOString().slice(0, 10)
const advisories = new Map()
for (const vulnerability of Object.values(report.vulnerabilities ?? {})) {
  for (const via of vulnerability.via) {
    // String entries point at another package's advisory; only objects are advisories.
    if (typeof via === 'object') advisories.set(`${via.url} ${via.name}`, via)
  }
}

const failures = []
const usedExceptions = new Set()
for (const advisory of advisories.values()) {
  if (!failingSeverities.has(advisory.severity)) continue
  const exception = exceptions.find(
    (entry) => entry.advisory === advisory.url && entry.packageName === advisory.name,
  )
  if (!exception) {
    failures.push(`${advisory.severity}: ${advisory.name} ${advisory.range} ${advisory.url} (${advisory.title})`)
    continue
  }
  if (today > exception.expires) {
    failures.push(`${advisory.name} ${advisory.url}: exception expired on ${exception.expires}; re-evaluate it`)
    continue
  }
  usedExceptions.add(exception)
}

for (const exception of usedExceptions) {
  const latest = runNpm(['view', exception.packageName, 'version']).trim()
  if (latest !== exception.vulnerableThrough) {
    failures.push(
      `${exception.packageName} ${latest} has been released since the ${exception.advisory} exception ` +
        `(vulnerable through ${exception.vulnerableThrough}); update the lockfile and remove the exception if it is fixed`,
    )
    continue
  }
  console.log(`Allowed until ${exception.expires}: ${exception.packageName} ${exception.advisory}. ${exception.reason}`)
}

for (const exception of exceptions) {
  if (!usedExceptions.has(exception) && !failures.some((failure) => failure.includes(exception.advisory))) {
    console.log(`::warning::Unused audit exception ${exception.advisory}; remove it from scripts/audit-dependencies.mjs`)
  }
}

if (failures.length > 0) {
  console.error('Dependency audit failed:')
  for (const failure of failures) console.error(`- ${failure}`)
  process.exit(1)
}

console.log(`Dependency audit passed (${advisories.size} advisories checked).`)
