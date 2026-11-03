# Statement extraction benchmark

Use `api/script/benchmark_statement_extraction.rb` in an isolated test database. It runs the actual extraction job three times per fictional PDF, rolls each run back, and records download/read, PDF safety, native text extraction, native parsing, routing, provider replay and persistence separately. Nested timings are exclusive. The total includes other job overhead; medians of stages need not add to the median total.

The script replaces S3 reads with local committed fictional files and provider calls with committed recordings. It measures local overhead and confirms whether a provider request is needed. It does **not** measure live network/model latency or production S3. Native successes consume no recordings.

```sh
cd api
RAILS_ENV=test DATABASE_TEST_NAME=household_cfo_qa_statement_benchmark \
  OPENROUTER_API_KEY='' STATEMENT_BENCHMARK_OUTPUT=/tmp/statement-after.json \
  bin/rails runner script/benchmark_statement_extraction.rb \
  bank-of-guam-2026-09.pdf bankpacific-2026-09.pdf mainland-visa-2026-09.pdf \
  coast360-2026-10-scanned.pdf
```

Prepare that isolated database first. To compare a baseline, save the baseline versions of `financial_documents/native_statement_parser.rb` and `financial_documents/extractor.rb` as `baseline_native.rb` and `baseline_extractor.rb` in a private temporary directory. Set `STATEMENT_BENCHMARK_BASELINE_DIR` to that directory and choose a separate output file. Those definitions load only in the benchmark process. Keep application, fixture and database versions fixed across the pair.

The initial November 3 measurement preceded changes to the paused work. A final paired run compared `origin/main` at `f19b00de` with the implementation. After the owned test stacks stopped, the final 27-row text PDF median was 0.771 seconds before (one replayed provider call) and 0.632 seconds after (zero provider calls). These figures exclude live provider latency. The lead's earlier 50–60-second text-PDF observation is historical context, not a measured before median from this run. A separately verified live scanned fallback took 17.592 seconds and the fictional receipt photo took 9.127 seconds.

The separate loaded pair measured 5.810 seconds before and 6.036 seconds after while full suites competed for the host; persistence alone was about 4.8 seconds. Both observations are retained in the worker evidence. This is a local processing target, not a promise about production storage or network latency.

| Stage, seconds (median of 3) | Before | After |
| --- | ---: | ---: |
| Local download/read | 0.000090 | 0.000099 |
| PDF safety | 0.175610 | 0.167707 |
| Native text extraction | 0.211837 | 0.211421 |
| Routing | 0.000033 | 0.000030 |
| Native parse | 0.028422 | 0.025713 |
| Provider replay | 0.000053 (1 request) | 0 (0 requests) |
| Persistence | 0.259568 | 0.214130 |
| Whole extraction job | **0.771** | **0.632** |

The first measurement preceded implementation changes. The final pair uses the same baseline definitions from `f19b00de` and final application source. The baseline model response is replayed; its service latency is deliberately excluded to honor the brief's live-call restriction. Do not compare the replay total directly with the historical 50–60-second live observation.
