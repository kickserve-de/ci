# kickserve-de/ci

Shared GitHub Actions for all Kickserve project repos: the same checks on every
PR, the same deploy flow, and the results as a traffic light in the PR.

## What a repo gets

| When | What runs | Where the result shows |
|---|---|---|
| Every PR and every push to `main` | `pr-checks.yml`: validate, install, audit, syntax, lint, typecheck, tests, build, migrations in the PR, snippet translations (the repo passes its own commands) | Checks on the PR + block `PR checks` in the PR description |
| Push to `staging` | `deploy-deployer.yml` to staging, then smoke test + Lighthouse (each path warmed up first, `warmup-hits`) | Checks on the merged branch head + block `Staging` in its open PR |
| Manual "Run workflow" on `main` | Gate (waits for the PR checks on that commit, they must be green) → deploy → smoke + Lighthouse | Block `Production` in the merged PR, job summary |
| Manual "Release" on `main` (admin/maintain) | `release.yml`: role and gate check → version `N` (tag + GitHub Release "Version N") → production deploy → `release-tasks.yml`: tasks to Done with "Live mit Version N" | Releases page, block `Production` in the merged PRs, task comments, job summary |
| Manual "Run workflow" | `rollback-deployer.yml`: previous Deployer release | Job log |
| Manual "Run workflow" | `unlock-deployer.yml`: removes a stale Deployer lock after a killed deploy | Job log |
| Every push and PR opened/merged | `task-sync.yml`: task ID from commit, branch or PR title | Task link in the PR description, one pinned Commit-Log comment on the task |

## Traffic light

- 🔴 a **hard** check failed (tests, build, syntax, smoke, Lighthouse below `lighthouse-min`): the job fails and blocks the merge or marks the deploy red.
- 🟡 only **soft** checks failed (audits, lint/typecheck when set to soft, Lighthouse below `lighthouse-target`): GitHub shows them as neutral checks.
- 🟢 everything passed.

The block in the PR description sits between `<!-- kickserve-ci:<key>:start -->`
and `<!-- kickserve-ci:<key>:end -->` and is replaced on every run; the rest of
the description is never touched.

## Use in a repo

`.github/workflows/pr.yml`:

```yaml
name: PR checks
on:
  pull_request:
  push:
    branches: [main]
jobs:
  pr:
    uses: kickserve-de/ci/.github/workflows/pr-checks.yml@v1
    with:
      php: true                 # PHP 8.4 + composer + the ext-* composer requires (php-version, php-extensions)
      node: true                # Node 20 (node-version to change)
      install: |
        composer install --no-interaction --no-progress --prefer-dist
        npm ci --no-audit --no-fund
      syntax-paths: site        # PHP syntax check
      lint: npm run lint        # soft by default (lint-level: hard)
      typecheck: npm run typecheck
      test: composer test
      build: npm run build      # e.g. shopware-cli project ci . with shopware-cli: true
      build-dirs: site/plugins/foo   # sub-packages built with npm, part of "build"
    secrets: inherit
```

Every non-empty command is one check with a generic name (`install`, `lint`,
`typecheck`, `tests`, `build`); `validate` (composer.json), `audit`, `syntax`,
`migrations` and `translations` are built in. Lint and typecheck are warnings
until a repo sets their level to `hard`.

`.github/workflows/deploy-staging.yml` and `deploy-production.yml`:

```yaml
name: Deploy production
on: workflow_dispatch
jobs:
  deploy:
    if: github.ref == 'refs/heads/main'
    uses: kickserve-de/ci/.github/workflows/deploy-deployer.yml@v1
    with:
      environment: production
      host: production
      url: https://www.example.com
    secrets: inherit
```

All inputs and their defaults are documented at the top of each workflow and
action file. The Deployer version comes from `deployer/deployer` in `composer.lock`
(`require` or `require-dev`); repos without one (e.g. Node apps) pass
`deployer-version` to both the deploy and the rollback workflow. When the build or `deploy.php` reads secrets from the environment (e.g. to write
a config file into each release), list their names in `env-secrets`; with
`secrets: inherit` the job sees the secrets of its GitHub environment.
Repo-specific deploy scripts (no Deployer) can still use the
`check-gate` and `post-deploy` actions directly. Repos deployed by AWS CodePipeline wait for
the release with `actions/wait-codepipeline` before `post-deploy`.

## Release (versioned production deploys)

A version is a plain integer per repo (1, 2, 3 …): a git tag `N` and a GitHub
Release "Version N" with generated notes (PRs since the previous version; for
version 1 since the newest older release or tag, so repos with old semver
releases get sensible notes). Other tags are ignored for the numbering.

- **A version always deploys.** "Release" creates the next version and deploys
  it to production in the same run. Merged work waits on `main` until someone
  runs it, so dependent tasks can go live together.
- **Only on `main`, only admin or maintain.** The run fails for anyone else
  (role of the person who started or re-ran it) and on other branches.
- **No version for red checks.** The gate (PR checks on the commit) runs before
  the tag exists.
- **Nothing new, nothing created.** When the latest version already is `main`'s
  HEAD, no new number is made: it deploys again only when it has no successful
  production deployment yet (e.g. the deploy failed), else the run says
  "nothing new".
- **The "Deploy production" button stays** and creates no version.
- After the deploy, the tasks referenced in the version's commits move to the
  `Done` section of their projects (never completed) and get the comment
  "Live mit Version N: <release link>". A red smoke test or Lighthouse after a
  successful deploy still counts as live. Reruns post no second comment.

`.github/workflows/release.yml`:

```yaml
name: Release
on: workflow_dispatch
jobs:
  version:
    uses: kickserve-de/ci/.github/workflows/release.yml@v1
    permissions: { contents: write, actions: read, deployments: read }
  deploy:
    needs: version
    if: needs.version.outputs.deploy == 'true'
    uses: ./.github/workflows/deploy-production.yml
    secrets: inherit
    permissions: { contents: read, actions: read, checks: write, pull-requests: write }
  tasks:
    needs: [version, deploy]
    # Also after a red smoke test: release-tasks checks that the deploy itself succeeded.
    if: ${{ !cancelled() && needs.version.outputs.deploy == 'true' }}
    uses: kickserve-de/ci/.github/workflows/release-tasks.yml@v1
    with: { version: '${{ needs.version.outputs.version }}' }
    secrets: inherit
    permissions: { contents: read, deployments: read }
```

`deploy-production.yml` gets `workflow_call` next to `workflow_dispatch`, nothing
else changes (the button keeps working):

```diff
 name: Deploy production
-on: workflow_dispatch
+on: [workflow_dispatch, workflow_call]
```

Repos with another production deploy chain whatever they run today the same
way. `release.yml` inputs: `gate-workflow` (default `pr.yml`), `environment`
(default `production`, the environment whose deployments tell whether a version
is live), `runner` (default `ubuntu-latest`); outputs `version`, `deploy`,
`created` (`'true'` only when the tag was made in this run) and `sha`.
`release-tasks.yml` inputs: `version` (required), `environment`, `done-section`
(default `Done`), `runner`, `api`; tracker settings as for task sync below
(repos outside kickserve-de pass `api` and `TASK_TOKEN` explicitly instead of
`secrets: inherit`). Both workflows need `gh` on the runner.

Run `lib/test-release.sh` and `actions/release-tasks/test.sh` for the offline
tests (the `Release tests` workflow runs them).

## Task sync

`.github/workflows/task-sync.yml`:

```yaml
name: Task sync
on:
  push:
    branches: ["**"]
  pull_request:
    types: [opened, closed]
permissions:
  pull-requests: write
  contents: read
jobs:
  sync:
    uses: kickserve-de/ci/.github/workflows/task-sync.yml@v1
    secrets: inherit
```

The task ID (16 digits Asana, 17 Kickserve Work) comes from the commit
message, the branch name or the PR title. The `TASK_ID (…)` placeholder of the
PR template is replaced with the task link. The tracker is set only by org or
repo settings, so this file never changes when the tracker does:

- secret `TASK_TOKEN` (falls back to `ASANA_PAT`)
- variable `TASK_API` (falls back to `ASANA_API`; empty = Asana, Kickserve Work `https://<host>/api/1.0`)
- optional variables `TASK_MERGE_SECTION` (move the task on merge into main), `TASK_LOG_MAX` (default 50), `MAIN_BRANCH`

Repos outside the kickserve-de org (rabe-bike, kitchenz, …) do not get secrets through
`secrets: inherit`; they pass the token and the API base explicitly:

```yaml
    uses: kickserve-de/ci/.github/workflows/task-sync.yml@v1
    with:
      api: ${{ vars.TASK_API }}
    secrets:
      TASK_TOKEN: ${{ secrets.TASK_TOKEN || secrets.ASANA_PAT }}
```

Inputs: `runner` (default `ubuntu-latest`), `pin` (default `true`), `api`. Run
`actions/task-sync/test.sh` for jq and offline mocked-HTTP updater regression tests.
The `Task-sync tests` workflow runs them on relevant pull requests and pushes to main.

API/transport failures and malformed read responses fail task sync; failed reads
never trigger comment creation or other mutations for that task. Independent tasks
still sync; the run exits with the first failure status after processing all tasks.
Diagnostics name the request, task and HTTP status when available. For `403`, check that the configured
token has access to the target task, workspace and project; this action cannot
grant access. A subsequent `400` alone does not establish a permissions or pinning issue.

Logs running `.github/scripts/asana/update.sh` use an older local copy, not the shared
`actions/task-sync/update.sh`. Those consumers must migrate to the shared action
with a release containing the fix (or update their local copy). Existing `@v1`
callers benefit only once the compatible fix is released to `v1`; merging a fix
does not itself update that tag.

## Repo setup

1. Settings → Branches → `main`: require the status check `pr / checks`.
2. Secrets: `SSH_PRIVATE_KEY` (deploy key, repo or environment secret), optional `BASIC_AUTH` (`user:password`) as a repo secret (the post-deploy job has no environment, so environment secrets are not visible to it).
3. Behind Cloudflare (smoke test gets `403` with `cf-mitigated: challenge`): repo secret `CHECK_TOKEN` with a random value (kept in 1Password as `<repo> check token`), and a WAF custom rule with action Skip for `http.host eq "<host>" and any(http.request.headers["x-kickserve-check"][*] eq "<value>")`.

## Versions

Repos use `@v1`. Compatible changes move the `v1` tag; breaking changes get `v2`.
