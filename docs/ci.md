# CI trust and publication boundary

Decided 2026-07-14. This records which CI lanes run where, and why the
remaining GitHub Actions lanes are intentional exceptions rather than
migration debt.

## Lanes

| Lane | Config | Trigger | Executor |
|---|---|---|---|
| Site contract | `.woodpecker/site.yml` | push/PR to `main`, manual | Woodpecker, Linux Docker (`hostname=ci`) |
| macOS tests (trusted) | `.woodpecker/test-macos.yml` | push to `main` only | Woodpecker, repository-locked isolated native agent (`hostname=macvm-pinemeter`, `trust=public-main-only`) |
| macOS tests (untrusted PRs) | `.github/workflows/test.yml` | `pull_request` to `main` | GitHub-hosted ephemeral `macos-latest` runner |
| GitHub Pages deploy | `.github/workflows/deploy-pages.yml` | push to `main` (`site/**`), manual | GitHub-hosted `ubuntu-latest` |

## Trust boundary

The persistent native macOS agent never executes untrusted public PR code:

- `.woodpecker/test-macos.yml` triggers on push to `main` only. Code reaches
  it exclusively after a maintainer merges it.
- The agent is repository-locked and labeled `trust=public-main-only`; it
  accepts no other repository and no PR events.
- Public PR code runs only in `.github/workflows/test.yml` on GitHub-hosted
  ephemeral runners that are destroyed after each job.
- Any Woodpecker pipeline for a fork PR (the Docker site lane) must remain
  approval-gated server-side; fork PRs never run unreviewed.

## Intentional GitHub Actions exceptions

These lanes stay on GitHub Actions by decision, not as leftover migration
work:

- **`test.yml` (public PR tests).** Permanent until an ephemeral or otherwise
  isolated Woodpecker macOS executor is approved. Hosted ephemeral runners
  are the only executor class currently approved for untrusted code.
- **`deploy-pages.yml` (GitHub Pages).** Permanent GitHub-native exception.
  Pages deployment is inherently GitHub-native (OIDC `id-token`,
  `configure-pages`/`deploy-pages`, the `github-pages` environment); it runs
  only trusted `main` pushes on hosted runners, so a Woodpecker publication
  path would add a long-lived deploy credential without removing any
  untrusted-code exposure.

## Retired duplication

The main-push trigger of `test.yml` was retired after the Woodpecker
replacement (`test-macos.yml`) passed its canary runs on the isolated agent.
`test.yml` is now PR-only.
