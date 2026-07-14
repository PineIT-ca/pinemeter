# Woodpecker CI migration

The migration keeps GitHub Actions enabled until shadow validation is complete.

`site.yml` is secret-free and validates the GitHub Pages payload on Linux for
pushes, pull requests, and manual runs. It does not publish the public site.
The existing Pages workflow remains the production deployment rollback path
until a separately approved GitHub Pages source and credential cutover.

`test-macos.yml` builds the Xcode test bundle and runs it headlessly under the
dedicated `_woodpecker_pm` service account. Each run creates and removes a
disposable Keychain, so Keychain repository tests retain parity without using a
logged-in user's Aqua session or Keychain. It runs only for main pushes. The
repository is public, so fork pull-request
code must never execute on the persistent native macVM local backend. GitHub
Actions remains the pull-request test path until an ephemeral macOS executor is
available.

The macOS workflow requires a second Woodpecker agent instance on macVM with a
unique token, state directory, service label, health port, and exact labels for
`PineIT-ca/pinemeter`, including `hostname=macvm-pinemeter` and
`trust=public-main-only`. It runs as a separate service user and cannot read
the PineSeed agent token. Do not relabel or share the PineSeed agent.

Rollback is to disable Pinemeter in Woodpecker, revoke only its dedicated agent
token, stop only its dedicated service, and leave both GitHub Actions workflows
and GitHub Pages settings unchanged.
