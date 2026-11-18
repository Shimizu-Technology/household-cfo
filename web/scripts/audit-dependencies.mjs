// Fails CI on any npm advisory at moderate or above in the full dependency tree,
// except the exact exceptions in scripts/audit-policy.mjs. Production
// dependencies are audited separately with `npm audit --omit=dev` and get no
// exceptions at all.
import { execFileSync } from 'node:child_process'
import { evaluate, validReport } from './audit-policy.mjs'

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
if (!validReport(report)) {
  console.error(`npm audit failed: ${report.error?.summary ?? 'unexpected report format'}`)
  process.exit(1)
}

function publishedVersions(packageName) {
  const versions = JSON.parse(runNpm(['view', packageName, 'versions', '--json']))
  if (versions?.error) throw new Error(`npm view ${packageName} failed: ${versions.error.summary ?? versions.error.code}`)
  // A package with a single version comes back as a string.
  return [versions].flat()
}
const { failures, allowed, unused, checked } = evaluate(report, { today: new Date().toISOString().slice(0, 10), publishedVersions })

for (const exception of allowed) {
  console.log(`Allowed until ${exception.expires}: ${exception.packageName} ${exception.advisory}. ${exception.reason}`)
}
for (const exception of unused) {
  console.log(`::warning::Unused audit exception ${exception.advisory}; remove it from scripts/audit-policy.mjs`)
}

if (failures.length > 0) {
  console.error('Dependency audit failed:')
  for (const failure of failures) console.error(`- ${failure}`)
  process.exit(1)
}

console.log(`Dependency audit passed (${checked} advisories checked).`)
