# Migrations

A migration repairs state that an older release left behind, such as a retired key in
`settings.json` or an orphaned default. It ships in exactly one stable release and is then deleted,
so the codebase never carries a history of its past formats.

## Invariants

- **Every migration lives in `Tinycast/Migrations/`**, one file and one `<Subject>Migration` type
  each. Its call sites name that type, so deleting the file fails the build at every one of them.
- **One stable release, then gone.** `Scripts/check-migrations.sh` fails `lint.sh` and the Release
  workflow once a stable tag (`vX.Y.Z`) contains the commit that added the file. Beta tags do not
  count: the beta channel runs it on the way to that stable release.
- **Missing it must be harmless.** A user who skips that release never runs it, so a migration only
  tidies. A value a later release depends on is never left to one.
- **Except a dated row.** When no later release can work without the migration, its row names a
  `YYYY-MM-DD` instead, and the check fails from that day rather than at the first stable tag. The
  custom quick-action prompt format requires this longer transition.
- **Idempotent and silent.** It runs on every launch of its release, does nothing when there is
  nothing to repair, and reports nothing.
- **Every live migration has a row below.** The check fails for a file the table does not name.

## Adding one

Write the type in `Migrations/` and call it from `AppCore.start()` before anything reads the state it
repairs. A file-format upgrade may instead run at the store's decode boundary, before records reach
its state. Cover it with a harness of its own, so deleting it removes a whole file, one
`run-tests.sh` entry and one row in [testing.md](testing.md). Then add its row here.

## Deleting one

When the check fails, delete everything the row lists, then the row. Then run `xcodegen generate`,
`./Scripts/run-tests.sh` and `./Scripts/lint.sh`.

## Live migrations

| Migration | Repairs | Delete with it |
| --- | --- | --- |
| `CustomQuickActionPromptMigration` | Expands legacy custom-action `instructions` into the full `systemPrompt` at decode time, preserving the previously implicit text-transformation boundary. Kept until **2027-05-17** for users who skip releases | `Tinycast/Migrations/CustomQuickActionPromptMigration.swift`, its decode call in `CustomQuickActionStore.load()`, `Tests/CustomQuickActionPromptMigrationTests.swift`, both source references and the harness entry in `Scripts/run-tests.sh`, and its row in [testing.md](testing.md) |
