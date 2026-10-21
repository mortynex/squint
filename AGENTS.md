# Squint

macOS Quick Look extension that previews code with Shiki, plus a small native code editor. See `README.md` for features.

## Layout

- `App/` – SwiftUI app and editor (`App/Editor/`)
- `Extension/` – Quick Look preview extension
- `Shared/` – code shared by both (Oniguruma shim, etc.)
- `js/` – Shiki bundle sources; `js/build.sh` generates `Resources/`
- `Resources/` – generated JS bundle, grammars and themes (committed so a clone builds without npm)
- `vendor/` – prebuilt Oniguruma
- `test/`, `tools/` – snapshot/editor tests and helper scripts

## Build and test

- `./build.sh` – builds `build/Squint.app` (ad-hoc signed)
- `./install.sh` – installs the app
- `test/snap.sh`, `test/editor.sh` – render/editor checks
- `cd js && npm install && ./build.sh` – regenerate `Resources/` after changing `js/`

## Git workflow (automatic)

The remote is the private GitHub repo `mortynex/squint` (`origin`, branch `main`). Commit and push on your own, without
asking:

- After every completed, working change (a feature, a fix, a refactor, a docs update), commit and push right away.
  Don't batch unrelated changes into one commit; don't leave finished work uncommitted at the end of a task.
- Before committing, make sure it builds (`./build.sh`) if Swift, C or `js/` code changed.
- Stage files explicitly (`git add <paths>`), never blindly `git add -A`. Check `git status` first.
- Never commit `build/`, `js/node_modules/`, `.DS_Store`, or secrets (tokens, keys, `.env`).
- Commit messages: short imperative subject (e.g. `Fix gutter width for 5-digit line numbers`), body only when the
  why isn't obvious.
- Push with `git push`; if rejected, `git pull --rebase` and push again. Never force-push, never rewrite pushed history.
- If a push fails for another reason (auth, network), say so in your reply instead of retrying in a loop.
