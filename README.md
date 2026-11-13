# kickserve-de/ci

Shared GitHub Actions for all Kickserve project repos: the same checks on every
PR, the same deploy flow, and the results as a traffic light in the PR.

## What a repo gets

| When | What runs | Where the result shows |
|---|---|---|
| Every PR and every push to `main` | `pr-checks.yml`: validate, install, audit, syntax, lint, typecheck, tests, build, migrations in the PR, snippet translations (the repo passes its own commands) | Checks on the PR + block `PR checks` in the PR description |
| Push to `staging` | `deploy-deployer.yml` to staging, then smoke test + Lighthouse (each path warmed up first, `warmup-hits`) | Checks on the merged branch head + block `Staging` in its open PR |
| Manual "Run workflow" on `main` | Gate (waits for the PR checks on that commit, they must be green) → deploy → smoke + Lighthouse | Block `Production` in the merged PR, job summary |
| Manual "Release" on `main` (admin/maintain) | `release.yml`: role and gate check → version `N` (tag + GitHub Release "Version N") → production deploy → `release-tasks.yml`: "Live mit Version N" on the tasks, those in "Ready for Deployment" to Done | Releases page, block `Production` in the merged PRs, task comments, job summary |
| Manual "Run workflow" | `rollback-deployer.yml`: previous Deployer release | Job log |
| Manual "Run workflow" | `unlock-deployer.yml`: removes a stale Deployer lock after a killed deploy | Job log |
| Manual "Run workflow" | `sync-staging-deployer.yml`: production database (anonymized) and folders to staging, snapshot to Google Drive; no deploy runs meanwhile | Job log, files in the Drive folder |
| Every push and PR opened/merged | `task-sync.yml`: task ID from commit, branch or PR title | Task link in the PR description, one pinned Commit-Log comment on the task |

## Traffic light

- 🔴 a **hard** check failed (tests, build, syntax, smoke, required requests, Lighthouse below `lighthouse-min`): the job fails and blocks the merge or marks the deploy red.
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
      test: composer test       # hard by default (test-level: soft)
      mysql: '5.7'              # throw-away MySQL for the tests, see below
      build: npm run build      # e.g. shopware-cli project ci . with tools: shopware-cli
      build-dirs: site/plugins/foo   # sub-packages built with npm, part of "build"
    secrets: inherit
```

Every non-empty command is one check with a generic name (`install`, `lint`,
`typecheck`, `tests`, `build`); `validate` (composer.json), `audit`, `syntax`,
`migrations` and `translations` are built in. Lint and typecheck are warnings
until a repo sets their level to `hard`.

`mysql: '<tag>'` starts a throw-away `mysql:<tag>` service container (root
password and database `test`) on a random host port and gives every command
`DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` and
`DATABASE_URL`. The runner needs Docker; the self-hosted runners have it.

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
Scripts that must load in the browser (tag manager, consent banner) go into
`required-requests` as URL parts, e.g.
`googletagmanager.com/gtm.js?id=GTM-XXXX`: the Lighthouse run checks that every
Lighthouse path requested them, and a missing one is a hard failure.
Sites that must send http visitors to https list a few paths in
`https-redirect-paths`, e.g. `/en/register`: the http URL of each must answer
301 or 308 with the same URL on https, else the `https-redirect` row is a hard
failure. It sends no basic auth or check token, so the redirect has to answer
before them.
Repo-specific deploy scripts (no Deployer) can still use the
`check-gate` and `post-deploy` actions directly. Repos deployed by AWS CodePipeline wait for
the release with `actions/wait-codepipeline` before `post-deploy`.

Laravel Forge sites call `deploy-forge.yml` instead of `deploy-deployer.yml`, with
`forge-organization`, `forge-server` and `forge-site` in place of `host`. It
starts the deploy through the site's deploy hook (`actions/forge-deploy`), waits
for it through the Forge API and fails when Forge deployed another commit than
the run's. Turn off quick deploy for the site in Forge, so every deploy runs
through the workflow. Secrets:

- `FORGE_DEPLOY_HOOK`: the site's deploy hook URL (Forge → site → Deployments →
  Deploy hook), as an environment secret in `staging` and `production`, because
  each site has its own hook. Without GitHub environments, keep one repo secret
  per site and pass it explicitly instead of `secrets: inherit`:

  ```yaml
  secrets:
    FORGE_DEPLOY_HOOK: ${{ secrets.FORGE_DEPLOY_HOOK_STAGING }}  # _PRODUCTION in the production deploy
    FORGE_API_TOKEN: ${{ secrets.FORGE_API_TOKEN }}
    BASIC_AUTH: ${{ secrets.BASIC_AUTH }}
    CHECK_TOKEN: ${{ secrets.CHECK_TOKEN }}
  ```
- `FORGE_API_TOKEN`: Forge API token with **only** the scope `server:view`; it
  just reads the deployment status. One org secret covers all Forge repos. Never
  add further scopes. The deploy hook URL is a secret too; if it leaks, refresh
  it in Forge and update the secret. Details are in the internal workflow guide.

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
- After the deploy, the tasks referenced in the version's commits get the
  comment "Live mit Version N: <release link>"; those in the section
  `Ready for Deployment` move to `Done` (never completed), tasks in other
  sections stay where they are. A red smoke test or Lighthouse after a
  successful deploy still counts as live. Reruns post no second comment.
  For version 1 the tasks start after the last production deployment, never
  at old non-version tags. A task the tracker no longer knows (deleted) is
  skipped with a warning.

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
(default `Done`), `ready-section` (default `Ready for Deployment`), `runner`, `api`; tracker settings as for task sync below
(repos outside kickserve-de pass `api` and `TASK_TOKEN` explicitly instead of
`secrets: inherit`). Both workflows need `gh` on the runner.

Run `lib/test-release.sh` and `actions/release-tasks/test.sh` for the offline
tests (the `Release tests` workflow runs them).

## Staging sync (Deployer)

`sync-staging-deployer.yml` copies production to staging on a Deployer host, which
is where production and staging live (one host, one SSH user):

1. **Dump** (holds `deploy-production`): `mysqldump` of production on the host,
   with the database settings read from `env-file` there, then import into a
   throwaway database on the runner and run the repo's `anonymize-sql` in it. Without
   that file the sync stops. Personal data never reaches staging or the snapshot.
2. **Write staging** (holds `deploy-staging`): keep `keep-tables` from staging,
   import the anonymized dump, put the kept tables back, run the repo's
   `staging-sql` (staging-only settings such as domains or base URLs), copy
   `sync-dirs` from production to staging on the host (`rsync --delete`, without `exclude`).
3. **Snapshot** (when `snapshot-folder-id` is set): the anonymized dump and an archive
   of `sync-dirs` (without `exclude` and `snapshot-exclude`) go to that Google Drive folder as
   `<name>-db-<date>.sql.gz` / `<name>-files-<date>.tgz` plus a copy named
   `-latest`; dated files older than `snapshot-keep-days` are deleted. A repo's
   ddev command can import the `-latest` files. The snapshot keeps production's
   schema, matching local branches cut from main. `snapshot-exclude` (e.g. `*.zip *.mp4`)
   keeps large downloads out of the archive only; staging keeps them.
4. **After sync**: `after-sync` runs in staging's `current/`, last, so a failure
   there does not block the snapshot.

**Database URL** (Shopware): set `env-file: shared/.env.local` and
`db-url-env: DATABASE_URL`. The URL (`mysql://user:password@host:port/name`,
percent-encoded parts are decoded) is read on the host and replaces `db-env`.

**Without a database** (Kirby): set `database: false` and `anonymize-files` to a
script in the repo. The sync copies `sync-dirs` from production to a temporary
folder beside staging's `shared/` (while holding `deploy-production`), runs the
script there (by its shebang, working directory = the copy, paths as below
`shared/`), and staging and the snapshot get only that copy. A failing script
stops the sync; a folder the script deletes is emptied on staging. Leave folders
staging keeps for itself, such as Kirby's `accounts`, out of `sync-dirs`.
`anonymize-files` also works with a database, for uploads with personal data.

Staging code can be ahead of production: migrations that exist only on staging
are missing after the import, and production's migration table says they never
ran. Set `after-sync` to the same migrate step the staging deploy runs, plus the
cache flush; it is project-specific, the workflow only runs it:

| Framework | `after-sync` |
|---|---|
| TYPO3 | `vendor/bin/typo3 extension:setup && vendor/bin/typo3 cache:flush` (schema from `ext_tables.sql`, never drops) |
| Magento 2 | `bin/magento setup:upgrade --keep-generated && bin/magento cache:flush`; set staging's base URLs in `staging-sql` (`core_config_data` comes from production) |
| Shopware 6 | `bin/console database:migrate --all && bin/console cache:clear`; point the sales channel domains to staging in `staging-sql` (`sales_channel_domain`) |
| Laravel | `php artisan migrate --force && php artisan optimize:clear` |

Use the PHP binary of the host when it is not the default (e.g. `/usr/bin/php83 vendor/bin/typo3 …`).

The deploys use the same concurrency groups, so no deploy runs while a sync reads
production or writes staging. A repo whose deploy does not come from
`deploy-deployer.yml` adds `concurrency: {group: deploy-<environment>, cancel-in-progress: false}`
to its deploy job. Staging changes that are not on production are lost, except in
`keep-tables`.

`.github/workflows/sync-staging.yml`:

```yaml
name: Sync staging
on:
  workflow_dispatch:
jobs:
  sync:
    uses: kickserve-de/ci/.github/workflows/sync-staging-deployer.yml@v1
    with:
      ssh-host: example.your-server.de
      ssh-user: deploy
      production-path: /var/www/production
      staging-path: /var/www/staging
      anonymize-sql: dev/data/anonymize.sql
      sync-dirs: public/media
      snapshot-folder-id: <Google Drive folder id>
    secrets:
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
      RCLONE_CONFIG_CONTENT: ${{ secrets.RCLONE_CONFIG_CONTENT }}
```

Kirby, without a database:

```yaml
    with:
      ssh-host: example.your-server.de
      ssh-user: deploy
      production-path: /var/www/production
      staging-path: /var/www/staging
      database: false
      anonymize-files: dev/anonymize-files.sh
      sync-dirs: content storage/forms
      snapshot-folder-id: <Google Drive folder id>
```

Other inputs: `ssh-port`, `env-file` (default `shared/.env`), `db-env` (variable
names for host, port, user, password, database; default the Laravel names),
`dump-options`, `db-image` (default `mariadb:10.11`; match the server),
`keep-tables`, `staging-sql`, `exclude`, `after-sync`, `snapshot-exclude`, `snapshot-name` (default the repo name),
`snapshot-keep-days` (default 30), `rclone-remote` (default `gdrive`), `runner`
(default `ubuntu-latest`; needs Docker). `RCLONE_CONFIG_CONTENT` is the base64
of an `rclone.conf` with a Drive remote; kickserve-de has it as an org secret.
`SSH_PRIVATE_KEY` must be a repo secret: the jobs have no environment, so they
add no deployment records that `release.yml` would read.

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

Repos outside the kickserve-de org do not get secrets through
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
callers get the fix once it is merged into `main` (see Versions).

## Repo setup

1. Settings → Branches → `main`: require the status check `pr / checks`.
2. Secrets: `SSH_PRIVATE_KEY` (deploy key, repo or environment secret), optional `BASIC_AUTH` (`user:password`) as a repo secret (the post-deploy job has no environment, so environment secrets are not visible to it).
3. Behind a bot protection that blocks the smoke test: input `check-header` (header name) and repo secret `CHECK_TOKEN` (its value); the smoke test sends the header only when both are set. The bot protection setup is in the internal workflow guide.

## Repos outside kickserve-de

This repo is private, so only repos in `kickserve-de` can use it. Other orgs use
their own private copy `<org>/ci` and write `uses: <org>/ci/...@v1` instead of
`kickserve-de/ci/...@v1`. After every tag move, `move-major-tag.yml` pushes `main`
and the newest major tag to each copy, with the self references rewritten to
`<org>/ci/`. Never change a copy directly: the next run overwrites it.

New org:

1. Create the private repo `<org>/ci` (empty). Settings → Actions → General →
   Access: "Accessible from repositories in the `<org>` organization".
2. Fine-grained token (GitHub → Settings → Developer settings): resource owner
   `<org>`, only the repo `ci`, Contents and Workflows read and write. Store it here
   as repo secret `MIRROR_TOKEN_<ORG>` (upper case, `-` as `_`). A deploy key does
   not work: GitHub rejects workflow files pushed with it. The token expires; renew
   it and the secret before that.
3. Add the org and secret name to the `mirror` matrix in `move-major-tag.yml`, merge,
   and check that the run pushed to `<org>/ci`.

## Versions

Repos use `@v1`. Every push to `main` runs the tests and then moves the newest
major tag (`v1`, after `v2` exists `v2`) to that commit (`move-major-tag.yml`), so a
merge is live for all callers within minutes. Before merging a breaking change, tag the current
`main` as the next major (`git tag v2 origin/main && git push origin v2`); the merge
then moves `v2` and `v1` stays put. If the
run fails with a missing `workflows` permission, add a repo secret `TAG_TOKEN`
(fine-grained token on this repo: contents + workflows write) and re-run it.
