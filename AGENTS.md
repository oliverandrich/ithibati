# Ithibati — local checkout rules

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. It defines the architecture, conventions,
commit style and required checks for everyone editing this project.

## Local tracker

- `.beans/` and `.beans.yml` are gitignored. Do not commit them or remove their ignore rules.
- When discussing tracker changes or backups, state that the backlog is local: `git push`
  does not back it up.
- Bean IDs (`ithibati-xxxx`) belong only in the tracker and this file, never in `lib/`,
  `test/`, `docs/`, `priv/` or `README.md`. Explain the reason directly instead of citing an
  unresolvable ID. `Ithibati.Credo.NoBeanIds` enforces this for shipped code and documentation.

## Before committing

Review the diff for bugs, regressions, security issues and project-rule violations. Then
simplify unnecessary branches and duplication without changing behavior or expanding scope.
Fix confirmed issues, rerun affected checks after edits, and report the outcome briefly.
For documentation-only changes, review wording and consistency instead.
