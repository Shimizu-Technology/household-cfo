// Writes the Playwright test list for one CI browser partition:
//   node scripts/browser-shard.mjs <npm script> <index> <total> <list file>
// then CI runs `npm run <npm script> -- --test-list <list file>`.
//
// Playwright's own --shard cuts the ordered test list into equal-count runs, so tests that are slow
// together (a heavy describe block, the phone projects) land in the same shard: one shard took twice
// as long as another. Dealing the tests round-robin spreads them out, and the shards finish within a
// few percent of each other without any timing data to maintain. Every listed test goes to exactly one
// partition, and this script checks that Playwright selects exactly this partition's tests from the file.
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'

const [script, indexArg, totalArg, listFile] = process.argv.slice(2)
const index = Number(indexArg)
const total = Number(totalArg)
if (!script || !listFile || !Number.isInteger(index) || !Number.isInteger(total) || index < 1 || index > total) {
  console.error('usage: node scripts/browser-shard.mjs <npm script> <index> <total> <list file>')
  process.exit(1)
}

// Every test the npm script would run, in Playwright's order, as { key, line } pairs.
function listTests(extraArgs = []) {
  const output = execFileSync('npm', ['run', '--silent', script, '--', '--list', '--reporter=json', ...extraArgs], {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  const report = JSON.parse(output)
  if (report.errors?.length) throw new Error(`playwright --list reported errors: ${JSON.stringify(report.errors)}`)
  const tests = []
  const walk = (suite, file, titles) => {
    for (const spec of suite.specs ?? []) {
      for (const test of spec.tests) {
        const titlePath = [...titles, spec.title]
        tests.push({ key: `${test.projectName}\u0000${spec.id}`, line: [`[${test.projectName}]`, file, ...titlePath].join(' › ') })
      }
    }
    for (const child of suite.suites ?? []) walk(child, file, [...titles, child.title])
  }
  for (const fileSuite of report.suites) walk(fileSuite, fileSuite.file, [])
  return tests
}

const all = listTests()
if (all.length === 0) throw new Error(`npm run ${script} lists no tests`)
if (new Set(all.map(test => test.key)).size !== all.length) throw new Error('playwright --list returned a test twice')
const mine = all.filter((_, position) => position % total === index - 1)
writeFileSync(listFile, mine.map(test => test.line).join('\n') + '\n')

// Playwright splits each line on › and trims the parts, and a line also matches tests nested under it, so
// a title with a › or surrounding spaces could select the wrong tests. Check the selection is exact.
const selected = listTests(['--test-list', listFile]).map(test => test.key).sort()
const expected = mine.map(test => test.key).sort()
if (selected.length !== expected.length || selected.some((key, position) => key !== expected[position])) {
  throw new Error(`the list file selects ${selected.length} tests, but partition ${index}/${total} has ${expected.length}`)
}
console.log(`Partition ${index}/${total}: ${mine.length} of ${all.length} tests from npm run ${script}.`)
