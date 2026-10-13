# CLI cheatsheet

Run everything from the project folder: `cd ~/Developer/directory-organizer`.

> **Sandbox only for now.** The tool refuses your real home, Downloads, Documents, Desktop,
> Pictures, Movies and Music folders. Everything happens inside `TestData/`.

## Build, test, sandbox

| Command | What it does |
|---|---|
| `swift build` | Compile everything (first build takes ~30 s, later ones are quick) |
| `./scripts/test.sh` | Run all tests |
| `./scripts/test.sh --filter Apply` | Run only tests whose name contains "Apply" |
| `FO_LIVE_MODEL=1 ./scripts/test.sh --filter LiveModel` | Also test against the real Apple model (slow; off by default) |
| `swift run make-testdata` | (Re)build the sandbox: `TestData/Downloads` (26 fake downloads), `TestData/Home` (stand-in home folder), `TestData/expected.json` |
| `rm -rf .build` | Clear the build cache if the build acts weird |

`swift run organize …` rebuilds first if needed. After a `swift build`, `.build/debug/organize …`
starts instantly. All examples below work with either.

## organize

| Command | What it does |
|---|---|
| `swift run organize plan TestData/Downloads` | Show where every file **would** go, and why. Moves nothing |
| `swift run organize plan TestData/Downloads --json` | Same plan as JSON |
| `swift run organize plan TestData/Downloads --no-model` | Rules only: files no rule can place go to review (fast) |
| `swift run organize model` | Is Apple's on-device model available (and can it see images)? |
| `swift run organize apply TestData/Downloads` | Show the plan, then ask: **[a]** all · **[o]** one by one · **[c]** cancel |
| `swift run organize apply TestData/Downloads --yes` | Apply everything without asking (`--no-model` works here too) |
| `swift run organize undo --last` | Put back the most recent batch exactly as it was |
| `swift run organize undo --batch 6835a73d` | Undo one batch (ID from `organize log`) |
| `swift run organize undo "Avengers Infinity War.mpeg"` | Undo one file (current **or** original name) |
| `swift run organize undo --all` | Undo every move that's still in place |
| `swift run organize log` | History of moves and undos, newest batch first |
| `swift run organize facts "TestData/Downloads/scan0001.pdf"` | Everything the app read from one file (text, OCR, source URL, dates…) |
| `swift run organize help` | Usage |

**Option for any command:** `--home <folder>` uses a different stand-in home folder. The defaults are
`<folder>/../Home` for `plan`/`apply` and `TestData/Home` for `undo`/`log`.

### Reading the plan

```
📁 Documents/University/ECO201  (new folder)          ← destination; "new folder" = will be created
   document (3).pdf → ECO201 Course Outline.pdf       ← original name → new name (if renamed)
       85% · NSU · rule: course · Course ECO201: …    ← confidence · tags · who decided · why
```

`model: apple` means Apple's model decided; "name suggested by the model" means a rule chose the
folder and the model chose the name. With the model, a plan takes ~30-40 s for the sandbox
(a few seconds per model question); `--no-model` takes a few seconds.

If the model isn't available: **System Settings → Siri** (on macOS 27 the Apple Intelligence
settings are in the Siri pane), then `swift run organize model` to check again.

Alert icons: 🔐 sensitive file · ♊️ duplicate (same content) · ⚠️ name clash (date added) ·
❓ unknown course code · ⛔️ destination rejected by the safety checks

### Typical session

```sh
swift run make-testdata                       # fresh sandbox
swift run organize plan TestData/Downloads    # look
swift run organize apply TestData/Downloads   # approve (a / o / c)
open TestData/Home                            # see the result in Finder (tags show as colored dots)
swift run organize undo --last                # changed your mind: everything goes back
```

## Look under the hood (macOS commands)

| Command | Shows |
|---|---|
| `mdls -name kMDItemUserTags "<file>"` | Finder tags as Spotlight sees them (names only) |
| `xattr "<file>"` | Names of a file's extended attributes |
| `xattr -px com.apple.metadata:_kMDItemUserTags "<file>" \| xxd -r -p \| plutil -convert json -o - -` | Raw tags with color numbers, e.g. `["NSU\n4"]` |
| `xattr -px com.apple.metadata:kMDItemWhereFroms "<file>" \| xxd -r -p \| plutil -convert json -o - -` | Download source URL(s) |
| `xattr -p io.github.n1soryu.directory-organizer.origin "<file>"` | Where the app moved this file from |
| `mdfind "kMDItemUserTags == NSU"` | Every file tagged NSU, but only in folders Spotlight indexes. Your real Documents is indexed; `TestData` (inside ~/Developer) wasn't on this Mac, so use `mdls`/`xattr` there |
| `tail -n 5 TestData/moves.jsonl` | Last entries of the move log (one JSON object per line) |

Tag colors: 0 none · 1 gray · 2 green (FSAE) · 3 purple (Personal) · 4 blue (NSU) · 5 yellow ·
6 red (Secure) · 7 orange. In iCloud-synced Documents, iCloud rewrites the number to 1; that's expected.

## Git

| Command | What it does |
|---|---|
| `git status` | What changed |
| `git log --oneline` | Commit history (one per milestone) |
| `git diff` | Uncommitted changes |
| `git pull` / `git push` | Sync with github.com/n1soryu/directory-organizer |
