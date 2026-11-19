# Local full stack

`bin/local-stack` runs the real Rails API and the web app on your own machine, signed in as fictional people, so a change can be checked in a browser against a real API before it ships. Nothing it starts can reach production.

## What it guarantees

The API refuses to boot in local-stack mode (`HCFO_LOCAL_STACK=1`) unless all of these hold. The checks live in `api/lib/local_stack.rb` and run from the first initializer.

- `RAILS_ENV=test`, so sign-in uses test identities and never WorkOS.
- Uploads use the local file store (`STORAGE_BACKEND=local`), in a folder outside the repository.
- Every hosted-service variable is empty: AWS, Resend, SMTP and reminder email, ops alerts, Sentry, Plaid, WorkOS, Clerk, and the database URLs. `api/.env` can't sneak them back: dotenv refills a variable only when it's missing, the launcher exports each one empty, and the guard refuses any value that is still there.
- The database is this stack's own (`household_cfo_ls_<name>_test`) on this machine.
- The API can open connections only to this machine. Anything else (S3, Resend, WorkOS, OpenRouter) is blocked and logged as `[local-stack] blocked a connection to …`.
- ActionMailer mail is written to files, never sent.
- Jobs run in-process, so statement reading finishes while you wait.

The web app gets the same treatment: analytics, Sentry and WorkOS settings are blanked, and it signs in through the local test identities.

## Use it

```bash
bin/local-stack doctor   # checks Postgres, gems, Node 24 in web/, ports, and the guard
bin/local-stack up       # creates the database, seeds sign-ins, starts the API and web
bin/local-stack status   # URLs and sign-in links
bin/local-stack down     # stops only the two processes it started
bin/local-stack reset    # stops, drops this stack's database and deletes its files
```

Sign in by opening one of the links `status` prints, for example `http://127.0.0.1:5300/?pilot_e2e_role=participant&pilot_e2e_live_api=true`. The fictional people are `participant@pilot.test`, `coach@pilot.test` and `admin@pilot.test`. For API calls, send `Authorization: Bearer test_token:e2e_participant:participant@pilot.test:Test:Participant`.

Give the participant a set-up household plan (fictional numbers) with:

```bash
bin/local-stack run bin/rails local_stack:household
```

`bin/local-stack run <command…>` runs any command in `api/` with the same guarded settings, for example `bin/local-stack run bin/rails console`.

A fresh database has no program. An admin creates one under Settings → Programs before creating groups.

## Files and logs

Everything lives under `~/.local/state/household-cfo/local-stack/<name>/`: uploads in `storage/`, any mail in `mail/`, and `api.log`, `web.log` and `prepare.log`. Rails also writes `api/log/test.log`. `<name>` comes from the checkout's folder name.

## Several checkouts at once

Each checkout gets its own database and state folder from its folder name. Give each one its own ports:

```bash
LOCAL_STACK_API_PORT=3310 LOCAL_STACK_WEB_PORT=5310 bin/local-stack up
```

Pass `LOCAL_STACK_LIFECYCLE_SESSION=<session id>` to record both processes with `dev-lifecycle`. Use the same ports for `down` and `status`.

## Reading statements that need the AI reader

CSV and Excel files, and the Wells Fargo and Apple Cash PDF templates, are read without a model. PDFs from other banks, screenshots and receipt photos need the AI reader. That stays off unless you put a separate OpenRouter key in `~/.config/household-cfo/local-stack.env`:

```bash
OPENROUTER_API_KEY=sk-or-…
```

The launcher uses it only when the key is different from the one in `api/.env` (production spends that one) and OpenRouter reports a credit limit on it. Then the API may also reach `openrouter.ai`. `doctor` shows which way it went.

## Not covered yet

- Signing in through WorkOS's staging environment (human mode). The stack signs in with test identities only.
- Safari on a real iPhone. Use Playwright's WebKit engine locally, and a real phone for camera, HEIC and keyboard checks.
