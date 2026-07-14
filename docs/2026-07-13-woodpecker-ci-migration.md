# Woodpecker CI migration

The migration keeps GitHub Actions enabled until shadow validation is complete.

`site.yml` is secret-free and validates the GitHub Pages payload on Linux for
pushes, pull requests, and manual runs. It does not publish the public site.
The existing Pages workflow remains the production deployment rollback path
until a separately approved GitHub Pages source and credential cutover.

`test-macos.yml` builds the Xcode test bundle under the dedicated
`_woodpecker_pm` service account, then calls the host's fixed, argument-free
`pinemeter-xctest-bridge`. The bridge enters the current console Aqua bootstrap
for Keychain services but runs the test bundle as `_woodpecker_pm`, never as
root or the logged-in user. Each run uses a disposable service-account
Keychain. It runs only for main pushes. The
repository is public, so fork pull-request
code must never execute on the persistent native macVM local backend. GitHub
Actions is retained only for pull-request tests until an ephemeral macOS
Woodpecker executor is available. The superseded GitHub Actions main-push path
is disabled after Woodpecker pipeline 16 passed all 198 tests.

The macOS workflow requires a second Woodpecker agent instance on macVM with a
unique token, state directory, service label, health port, and exact labels for
`PineIT-ca/pinemeter`, including `hostname=macvm-pinemeter` and
`trust=public-main-only`. It runs as a separate service user and cannot read
the PineSeed agent token. Do not relabel or share the PineSeed agent.

Rollback is to disable Pinemeter in Woodpecker, revoke only its dedicated agent
token, stop only its dedicated service, and leave both GitHub Actions workflows
and GitHub Pages settings unchanged.
