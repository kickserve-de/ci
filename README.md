# kickserve-de/ci

Shared GitHub Actions for all Kickserve project repos: the same checks on every
PR, the same deploy flow, and the results as a traffic light in the PR.

## What a repo gets

| When | What runs | Where the result shows |
|---|---|---|
| Every PR and every push to `main` | `pr-checks.yml`: validate, install, audit, syntax, lint, typecheck, tests, build, migrations in the PR, snippet translations (the repo passes its own commands) | Checks on the PR + block `PR checks` in the PR description |
| Push to `staging` | `deploy-deployer.yml` to staging, then smoke test + Lighthouse (each path warmed up first, `warmup-hits`) | Checks on the merged branch head + block `Staging` in its open PR |
| Manual "Run workflow" on `main` | Gate (waits for the PR checks on that commit, they must be green) → deploy → smoke + Lighthouse | Block `Production` in the merged PR, job summary |
| Manual "Run workflow" | `rollback-deployer.yml`: previous Deployer release | Job log |

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
      php: true                 # PHP 8.4 + composer (php-version to change)
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
action file. Repos without a `composer.lock` that pins `deployer/deployer`
(e.g. Node apps) pass `deployer-version` to both the deploy and the rollback
workflow. When `deploy.php` reads secrets from the environment (e.g. to write
a config file into each release), list their names in `env-secrets`; with
`secrets: inherit` the job sees the secrets of its GitHub environment.
Repo-specific deploy scripts (no Deployer) can still use the
`check-gate` and `post-deploy` actions directly. Repos deployed by AWS CodePipeline wait for
the release with `actions/wait-codepipeline` before `post-deploy`.

## Repo setup

1. Settings → Branches → `main`: require the status check `pr / checks`.
2. Secrets: `SSH_PRIVATE_KEY` (deploy key), optional `BASIC_AUTH` (`user:password`) as a repo secret (the post-deploy job has no environment, so environment secrets are not visible to it).

## Versions

Repos use `@v1`. Compatible changes move the `v1` tag; breaking changes get `v2`.
