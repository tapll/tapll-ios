# Changelog

## Unreleased

### Fixed
- The crash handler resumes the threads it suspended once the record is on disk. An app whose runtime
  recovers from the fault itself (Unity/Mono turning a null dereference into a managed exception) was
  left with every other thread frozen.
- The hang watchdog no longer reports the time an app spent suspended in the background as a main-thread
  hang when it resumes.

## 0.6.0

### Added
- **Feature flags.** `Tapll.flag("new_paywall")` returns a `Flag` with `isEnabled`, `variant` and
  `value(default:)`. Reads are synchronous and never throw; before the first fetch, offline on a first
  launch, or for a key the project does not have, `variant` is `nil` and the default you coded applies.
- Flags are fetched from `GET /v1/flags` at `configure` and on every return to the app (at most every
  5 minutes), with an ETag, and kept on disk for the next launch. `Tapll.refreshFlags()` fetches now;
  `Tapll.onFlagsChanged { }` is called when a fetch brought a different ruleset.
- Evaluation happens on the device, so traits from `identify` can target a flag without leaving it.
  In `strictAnonymous` there is no stable id, so a percentage split serves the flag's default.
- `Options.flagsEndpoint` (derived from `endpoint`, `/v1/batch` → `/v1/flags`, unless set).
- The first read of each flag in a session sends one `$flag_exposure` event (`flag`, `variant`,
  `reason`), which is what the panel's per-variant results follow.

## 0.5.0

Rebrand: Union is now **Tapll**.

### Breaking
- Swift package, library, target and module renamed `Union` → `Tapll`; the C target `UnionCrashCore` → `TapllCrashCore`.
  Migrate with `import Union` → `import Tapll` and `Union.…` → `Tapll.…`. The repository moves to
  `github.com/tapll/tapll-ios`.
- `public typealias Union = Tapll` is kept, marked `@available(*, deprecated, renamed: "Tapll")`, for one or two
  minors. It does not make `import Union` compile: the module name changed.

### Changed
- Default ingest endpoint `https://in.useunion.dev/v1/batch` → `https://in.tapll.com/v1/batch`.
- Key header `x-union-key` → `x-tapll-key` (the server accepts both). User-Agent is `tapll-ios/<version>`.
- RevenueCat / Survicate attribute documented as `tapll_install_id` (was `union_install_id`).
- Build-phase scripts read `TAPLL_*` env vars and still accept `UNION_*` as a fallback (`TAPLL_CRASH_E2E_PORT`,
  `TAPLL_SERVER_KEY`).
- Internal names moved too: Keychain service, `UserDefaults` suite and logging subsystem `app.union.sdk` →
  `app.tapll.sdk`, thread and queue labels, `union_crash_*` C symbols → `tapll_crash_*`.

### Migration (automatic, once, on `configure`)
Everything 0.4.x persisted under a Union name is moved, so the install id is preserved and a pending queue or
crash report from the previous launch is still delivered. Old present and new absent: moved. Both present: the new
one wins and the old is removed. Neither: nothing happens.

| What | Old | New |
| --- | --- | --- |
| Keychain service (`install_id`, `user_id`, `traits`) | `app.union.sdk` | `app.tapll.sdk` |
| `UserDefaults` suite (session snapshot, app version, opt-out, …) | `app.union.sdk` | `app.tapll.sdk` |
| Offline queue and crash reports | `Application Support/Union/<keyHash>/` | `Application Support/Tapll/<keyHash>/` |

The on-disk record format (`.ucr`, magic `UCR1`) is unchanged.

### Tests
- `LegacyMigrationTests`: defaults, directory and Keychain, each for old only, both present and neither.

## 0.4.0 and earlier (as Union)
See the git history; 0.4.0 added crash contract v2 and the wrapper bridge.
