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
  bundle id move and custom quick-action prompt format require this longer transition.
- **Idempotent and silent.** It runs on every launch of its release, does nothing when there is
  nothing to repair, and reports nothing.
- **Every live migration has a row below.** The check fails for a file the table does not name.

## Adding one

Write the type in `Migrations/` and call it from `AppCore.start()` before anything reads the state it
repairs, or from `TinycastLaunch.main` when that state is read before `AppCore` exists. A file-format
upgrade may instead run at the store's decode boundary, before records reach its state. Cover it
with a harness of its own, so deleting it removes a whole file, one `run-tests.sh` entry and one row
in [testing.md](testing.md). Then add its row here.

## Deleting one

When the check fails, delete everything the row lists, then the row. Then run `xcodegen generate`,
`./Scripts/run-tests.sh` and `./Scripts/lint.sh`.

## Live migrations

| Migration | Repairs | Delete with it |
| --- | --- | --- |
| `CustomQuickActionPromptMigration` | Expands legacy custom-action `instructions` into the full `systemPrompt` at decode time, preserving the previously implicit text-transformation boundary. Kept until **2027-05-17** for users who skip releases | `Tinycast/Migrations/CustomQuickActionPromptMigration.swift`, its decode call in `CustomQuickActionStore.load()`, `Tests/CustomQuickActionPromptMigrationTests.swift`, both source references and the harness entry in `Scripts/run-tests.sh`, and its row in [testing.md](testing.md) |
| `BundleIdentifierMigration` | Moves `com.tinycast.app[.beta\|.dev]` and `com.conversun.tinycast-cn[.beta]` preferences, Application Support, Caches and login items to the matching `com.abueammar.tinycast[.beta\|.dev]`, and repoints every saved path into the old folders: in preferences (JSON-encoded ones too), JSON files, clipboard and quicklink rows, and `settings.json`. A `paths-repointed` marker in its backup makes it repair, once, a copy 0.12.14-beta.141 moved without repointing. API and MCP Keychain items are copied only into an empty destination service and left in place for recovery. A successful pass records `BundleIdentifierMigration.secretsMigrated`; later launches leave the legacy services unread, while an interrupted pass resumes. Kept until **2027-05-13** | Everything in [Removing the bundle id move](#removing-the-bundle-id-move) |

### Removing the bundle id move

Afterwards, searching the repo for `BundleIdentifierMigration`, `com.tinycast.app` and
`com.conversun.tinycast-cn` finds nothing.

**Delete these files**

- `Tinycast/Migrations/BundleIdentifierMigration.swift`
- `Tests/BundleIdentifierMigrationTests.swift`

**Remove these lines**

- `Tinycast/App/TinycastApp.swift`: the `BundleIdentifierMigration.run()` call in
  `TinycastLaunch.main`.
- `Scripts/run-tests.sh`: the `run BundleIdentifierMigrationTests` entry.
- `Scripts/check-migrations.sh`: once no dated migrations remain, the dated-row block: its comment,
  the `until=` line and the `if [ -n "$until" ]` block around `continue`.

**Edit these docs**

- [testing.md](testing.md): the `BundleIdentifierMigrationTests` row.
- This file: the "or from `TinycastLaunch.main`" clause in [Adding one](#adding-one), the
  `BundleIdentifierMigration` row and this section. Remove the "Except a dated row" invariant only
  once no dated migrations remain.

**Left on users' Macs, with no code to remove it:** an empty `com.tinycast.app*.plist`, Keychain
secrets under the old names, stale permission entries in System Settings, and a `Migration Backup`
folder for anyone migrated in the last 30 days.
