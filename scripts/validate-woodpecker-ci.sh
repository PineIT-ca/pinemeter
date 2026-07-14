#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
macos="$root/.woodpecker/test-macos.yml"
site="$root/.woodpecker/site.yml"

for file in "$macos" "$site"; do
  test -f "$file"
  ruby -e 'require "yaml"; YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)' "$file"
done

grep -Fq 'repo: PineIT-ca/pinemeter' "$macos"
grep -Fq 'platform: darwin/arm64' "$macos"
grep -Fq 'backend: local' "$macos"
grep -Fq 'hostname: macvm-pinemeter' "$macos"
grep -Fq 'trust: public-main-only' "$macos"
grep -Fq 'xcodebuild build-for-testing' "$macos"
grep -Fq 'security create-keychain' "$macos"
grep -Fq '$HOME/Library/Keychains/' "$macos"
grep -Fq '/usr/bin/xctest' "$macos"
grep -Fq 'trap cleanup EXIT' "$macos"
if grep -Fq 'pull_request' "$macos"; then
  echo 'macOS local-backend workflow must not execute public pull-request code' >&2
  exit 1
fi

grep -Fq 'platform: linux/amd64' "$site"
grep -Fq 'event: [push, pull_request]' "$site"
grep -Fq '0.0.0-shadow' "$site"

for file in "$macos" "$site"; do
  if grep -Eq '(from_secret|privileged:|volumes:|/var/run/docker.sock)' "$file"; then
    echo "unsafe workflow capability in ${file#$root/}" >&2
    exit 1
  fi
done

if grep -Fq 'launchctl asuser' "$macos"; then
  echo 'macOS workflow must remain headless and outside the console Aqua session' >&2
  exit 1
fi

printf 'Pinemeter Woodpecker workflow validation passed.\n'
