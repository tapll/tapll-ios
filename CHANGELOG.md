# Changelog

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
