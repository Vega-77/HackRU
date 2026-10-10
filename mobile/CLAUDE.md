# Working on the HandsOn Physics app

Read `README.md` first for how to run it and how the code is laid out.

## Ground rules

- All app code lives in `mobile/`. The protocol is `../docs/protocol.md`;
  the backend teams own their own folders. Don't edit outside `mobile/` and
  `docs/` without asking.
- Work on branch `Dev1`. Merge `origin/main` into it (merge, don't rebase:
  it is a shared branch) before pushing. `main` only changes through a PR.
- Before every commit, these must all be clean:
  `dart format lib test`, `flutter analyze`, `flutter test`.
- Never commit `.claude/` or `build/`.

## Code conventions

- Layers: `models` <- `services` <- `state` <- `features`. A layer never
  imports one above it. `core/` can be used by anything.
- State is Riverpod 3 (`Notifier`). After an `await`, check `ref.mounted`
  (in a notifier) or `mounted` (in a widget) before touching state.
- Colours, type, spacing, radii and motion come from
  `lib/core/theme/tokens.dart`. No raw hex or magic numbers in widgets.
- Icons come from `AppIcons` (vendored Phosphor font). Add new glyphs there.
- Physics colours are reserved: velocity green, acceleration red, forces
  blue and yellow. Don't use them for anything else.
- Comments explain why, not what. Keep them short.
- New logic gets a unit test under the matching `test/` folder. New screens
  get a step in `test/widgets/app_flow_test.dart`.

## Copy

Sentence case. Buttons say what they do. Errors say what went wrong and
how to fix it. No em dashes, no middle dots, no exclamation marks.

## Previewing on Windows

`flutter build web --release`, then serve `build/web` (the `mobile-web`
launch config does this on port 8080). After a rebuild, unregister the
service worker and clear caches, or the browser shows the old build.
