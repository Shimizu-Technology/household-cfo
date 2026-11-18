import assert from 'node:assert/strict'
import { evaluate, exceptions, isNewer } from './audit-policy.mjs'

const picomatch = {
  source: 1247710,
  name: 'picomatch',
  title: 'picomatch vulnerable to ReDoS through single-branch repeated extglobs',
  url: 'https://github.com/advisories/GHSA-fc5q-39xc-vjpf',
  severity: 'high',
  range: '<=4.0.7',
}
const report = (...advisories) => ({
  vulnerabilities: {
    picomatch: { via: advisories },
    // Chained entries name another package and are not advisories themselves.
    vite: { via: ['picomatch', 'tinyglobby'] },
  },
})
const published = ['2.3.1', '3.0.1', '4.0.6', '4.0.7']
const run = (r, options = {}) => evaluate(r, { today: '2026-11-18', publishedVersions: () => published, ...options })

assert.ok(isNewer('4.0.8', '4.0.7'))
assert.ok(isNewer('5.0.0-beta.1', '4.0.7'), 'a prerelease of a later version counts')
assert.ok(isNewer('4.0.7', '4.0.7-rc.1'))
assert.ok(!isNewer('4.0.7', '4.0.7'))
assert.ok(!isNewer('3.9.9', '4.0.7'))
assert.ok(!isNewer('4.0.7-rc.1', '4.0.7'))

{
  const result = run(report(picomatch))
  assert.deepEqual(result.failures, [])
  assert.deepEqual(result.allowed, exceptions)
}

{
  const result = run(report(picomatch), { today: '2027-02-01' })
  assert.match(result.failures.join('\n'), /exception expired on 2027-01-31/)
}

{
  // `latest` can stay on 4.0.7 while a fix ships under another tag.
  const result = run(report(picomatch), { publishedVersions: () => [...published, '4.0.8-next.0'] })
  assert.match(result.failures.join('\n'), /picomatch 4\.0\.8-next\.0 published since/)
}

{
  const other = { ...picomatch, url: 'https://github.com/advisories/GHSA-0000-0000-0000' }
  const result = run(report(picomatch, other))
  assert.equal(result.failures.length, 1, 'a second advisory on the same package still fails')
  assert.match(result.failures[0], /GHSA-0000-0000-0000/)
}

{
  const sameAdvisoryOtherPackage = { ...picomatch, name: 'micromatch' }
  const result = run({ vulnerabilities: { micromatch: { via: [sameAdvisoryOtherPackage] } } })
  assert.equal(result.failures.length, 1, 'the exception is bound to picomatch only')
}

{
  const result = run(report({ ...picomatch, severity: 'critical' }))
  assert.match(result.failures.join('\n'), /now rated critical/, 'a re-rated advisory needs a fresh look')
}

{
  const low = { ...picomatch, url: 'https://github.com/advisories/GHSA-1111-1111-1111', severity: 'low' }
  assert.deepEqual(run(report(picomatch, low)).failures, [], 'low severity stays below the CI threshold, as before')
}

{
  const result = run({ vulnerabilities: {} })
  assert.deepEqual(result.unused, exceptions, 'an exception nobody needs is reported for removal')
}

console.log('audit policy checks passed')
