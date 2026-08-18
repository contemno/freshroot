<!--
PRs target `main`. Keep the diff scoped to one logical change — see
CLAUDE.md → "Commit discipline".
-->

## What & why

<!-- What does this change, and why now? Link the issue. -->

Closes #

## How it was verified

<!-- Commands run, manual checks. "Trust me" is not verification. -->

- [ ] `make lint` passes (shellcheck on all scripts)
- [ ] `make build` produces the deb cleanly; `dpkg-deb -c target/*.deb` shows
      the expected paths and permissions
- [ ] Required CI checks reported green (a required check that never *ran* is not a pass)

## Re-sync with base

<!-- A clean diff against a STALE base hides regressions. -->

- [ ] Rebased on the latest `main`
- [ ] Checked `git log <branch-point>..origin/main -- <changed files>`; if another PR
      touched these files, reconciled *intent* against the current `main` version

## Docs moved (Done = docs updated)

- [ ] Updated CLAUDE.md (file roles / constraints / sync points) and README
      for this change, **or** N/A because: ___

## Project invariants

<!-- The sync points documented in CLAUDE.md. -->

- [ ] Subvolume list changes touch **all four** sync points in
      `installer/freshroot-setup` (Phase 2 create, Phase 3 migrate, Phase 4
      fstab, Phase 7 cleanup whitelist) — or no subvolume change
- [ ] Lineage/snapshot helper changes touch **every copy** (`freshroot-update`,
      `freshroot-build`, `freshroot-install`, and the ||-guarded copy in
      `06_freshroot`) — or no helper change
- [ ] Snapshot ordering stays on the parsed timestamp field (never raw names),
      and generated sortable timestamps use `date -u`
- [ ] New conffile keys get pre-source defaults in every consumer (upgraded
      installs keep the old conffile; `set -u` must not abort) — or no new keys
