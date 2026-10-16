# How Directory Organizer works

The full details. For a quick start, see the [README](../README.md).

An offline macOS app that sorts new downloads into the right folders, with Finder tags.
Simple deterministic rules handle the obvious cases. A small on-device language model is
used only for files the rules can't place.

**Core principle:** the model never moves files or runs commands. It only *suggests* a
destination, a name and tags. Swift code checks every suggestion and performs the move.
A wrong guess sends the file to the review folder; it is never lost.

```
~/Downloads → facts → rules → model (leftovers only) → proposed action → checks → plan → you approve → move + undo log
```

## Status

| Milestone | What | State |
|---|---|---|
| 1 | Fact extraction, rules engine, plan-only CLI, stub classifier | ✅ |
| 2 | Apply moves, undo log, Finder tags, safety checks, creating folders and renaming | ✅ |
| 3 | Apple's on-device model for leftovers: folders, new folders, names (text and images) | ✅ |
| 4 | Menu-bar app + dashboard, Downloads watcher, approval UI, notifications, review reminder every 8 hours | ✅ |
| 5 | Organize Now: the heavy work (text recognition + model) on demand from the menu bar | ✅ |
| 6 | Evaluation on a labeled test set: rules only vs rules + model | |

**Next (approved 2026-10-14):** a model-led app with few rules, in phases:
1. Folders in Downloads: read inside, safety-checked, left alone while changing, unpacked when the model says so ✅ (0.7.0-dev)
2. Folder profiles learned from your own folders (replacing the fixed folder list and personal prompt) ✅
3. Grouping: code groups similar files, the model decides per group; new folders only for groups of 2–3+ ✅
4. Evaluation harness (the old Milestone 6), before any autonomy
5. Only universal rules left (safety, installers, code projects, incomplete downloads); NSU/FSAE/course rules removed
6. Earned autonomy: per-folder trust from your approvals; undo and corrections lower it

## Try it

Needs macOS 27 and Swift 6 (the Command Line Tools are enough; Xcode isn't required). One quirk:
the macOS 27 SDK declares SwiftUI's `@State` also as a macro whose plugin only ships with Xcode,
so the app uses `@ViewState` (an alias for the property wrapper).

```sh
swift run make-testdata                      # builds TestData/Downloads and TestData/Home
swift run organize plan TestData/Downloads   # shows the plan; nothing is moved
swift run organize apply TestData/Downloads  # shows the plan, asks: all / one by one / cancel
swift run organize undo --last               # puts the last batch back exactly as it was
swift run organize log                       # history of moves and undos
./scripts/test.sh                            # runs the tests
```

### The app

```sh
./scripts/build-app.sh --open    # builds build/Directory Organizer.app and opens it
```

A tray icon appears in the menu bar (with the number of files waiting) and the dashboard opens.
Notifications only work in this bundled app, not with `swift run`.

All commands, plus macOS commands for checking tags and attributes: **[docs/CLI-CHEATSHEET.md](CLI-CHEATSHEET.md)**.

`organize` refuses to read your real home, Downloads, Documents, Desktop, Pictures, Movies or
Music folders until real use is switched on deliberately.

## What it reads (no model)

- Name, extension, size, dates (including when the file was downloaded)
- **Download source** (`kMDItemWhereFroms`), the strongest signal: e.g. `northsouth.edu` → NSU
- Text: PDFKit for PDFs, with **OCR for scanned PDFs** that have no text layer; the XML inside
  .docx/.xlsx/.pptx; Vision OCR for images
- Video length and title from the file header (the video itself is never analyzed);
  photo date and camera from EXIF; whether an image is a screenshot
- What's inside zip archives (to spot code projects)

## Rules, in order (first match wins)

1. **Sensitive files** (always first, always reported):
   - CSV/JSON with password-manager columns → review (import it, then delete it)
   - 12+ consecutive BIP-39 words (recovery phrases, even in a photo) → Secure
   - private keys (`-----BEGIN … PRIVATE KEY-----`) and credential files → Secure
2. **Installers, disk images, firmware** (.dmg .iso .pkg .bin …) → review
3. **Code projects** (zips containing Package.swift, .git, package.json …) → review
4. **NSU records**: dated with the download date and kept side by side in
   `University/Records/<type>/` (Grades, Advising, Payments, Registration, Curriculum, …),
   e.g. `2026-10-13 Grade History.pdf`
5. **Courses**: a course code from the curriculum in the name, at the top of the text, or the
   course's full title → `University/<CODE>/`. Unknown codes go to review instead of creating folders.
6. **FSAE** team files → `Documents/FSAE`
7. **Videos**: films → `Movies/Films/Avengers Infinity War.mpeg`, episodes →
   `Movies/TV Shows/<Show>/Show S01E04.mkv`, short clips → `Movies/Clips`. Release clutter
   (4K, BluRay, x265 …) is removed; a year is kept only if it was in the name.
8. **Images** → `Pictures/Downloaded Images`
9. Anything else → the model (below). If it's unavailable or unsure: review.

## Your folders, learned (folder profiles)

The app doesn't come with a list of your folders. Every scan reads the folders under Documents,
Pictures, Movies and Music (two levels deep; a root itself only if files sit directly in it) into
**profiles**: how many files, of which kinds, the newest file names as examples, the sites they
were downloaded from, and the Finder tags most of them carry (2+ files and 60%+).

- **Purpose:** Organize Now has the model read a profile and write what the folder is for
  ("PDF lecture notes and problem sets"). Only from real files: an empty folder gets no purpose,
  since one guessed from a name ("FSAE" → "financial records") misleads every later choice. A
  purpose is rewritten when the folder has grown or shrunk by half (and 3+ files).
- **Tags** of a folder are the ones most of its files carry, so files placed there match them.
- Fixed in code are only the two folders the safety rules rely on: the review folder and
  `Documents/Secure` (keys, recovery phrases, identity documents; *not* bills or receipts).
- Profiles are kept in `folder-profiles.json` next to the move log (`TestData/` in the sandbox,
  Application Support for your real folders) and shown on the Folders page.
- **Shortlist:** each file is offered the 25 folders most likely to fit (shared words with the
  folder's name, purpose and examples; same download site; same kind of file), so the prompt
  fits the model's small context window. New folders are still checked against all folders.
- **Corrections:** a model move you undo is remembered ("notes.txt does not belong in
  Documents/FSAE") and up to 3 relevant ones are shown to the model next time. Moves you keep
  teach by example: the file becomes one of the folder's examples.

## Similar files, placed together (grouping)

In Organize Now, every leftover (no rule, not a duplicate, readable) is first **described** by the
model: what it is ("airfryer manual") and its general category, like a folder name ("User Manuals").
**Code groups** them: same main word in the category ("Bills" / "Utility Bills") or in the
description ("router manual" / "airfryer manual"), or descriptions close in meaning (Apple's
on-device sentence embedding, distance < 0.6). Vague words (files, documents, misc) don't group.

- Each group of 2+ is **placed in one question**: the model sees all of them (up to 8) and picks an
  existing folder or a new one. Its answer goes through the same checks as a single file's.
- **Only a group can create a new folder.** A file placed on its own may go to an existing folder
  or to one a group just created; a new folder of its own goes to review, even if another lone
  file picked the same name (that's chance, not a pattern).
- Group names are deterministic: the most common category, on a tie the more general one.
- `organize describe <file>…` prints what the model says a file is.

What didn't work, measured with the real model (kept here so it isn't tried again):
- Grouping by embeddings of the file text: the airfryer manual came out closer to a bill (0.87)
  than to the other manual (1.05). Short labels written by the model group well.
- Asking the model "do these belong together?": it said no even to two bills it had just called
  "electricity and water bills", before and after describing them. The group comes from its own
  labels instead.
- Example names in prompts ("Manuals", "Bills", later "Contracts", "Recipes") get copied as folder
  names for unrelated files. Prompt examples must not match the test data, and are best kept few.

**Stalls:** every model answer has 90 s and every text recognition 30 s; a stalled call counts as
"model unavailable" / "unreadable" (so: review), and Cancel still stops at once.

## The model (Apple's on-device Foundation Models)

Used only where rules can't decide, and only ever *suggests*:

- **Leftover files:** first question: *what is this, and does one of these folders fit?* The answer
  is constrained at generation time to the folders that exist (a schema built at runtime with
  `DynamicGenerationSchema`), so it can't invent a path. If nothing fits, a second, simpler
  question asks for a **new category folder** ("Manuals", "Bills").
- **Unclear names:** for files a rule has already placed (`IMG_4821.png`, `download.pdf`), it
  suggests a name. For images it **looks at the picture**. Images are dated: `2026-10-12 Router
  wireless settings page.png`.
- It never sees the file system and never acts. It receives a text summary of the facts (plus
  the image itself for pictures), one fresh session per question, greedy (repeatable) sampling.

Swift then checks every answer:
- the folder must be one that was offered, or a valid new folder (right parent for the file
  type, at most 2 levels, a sane name). A near-duplicate name reuses the existing folder:
  "Manual" → "Manuals".
- University folders need NSU evidence the model can't make up: a northsouth.edu source,
  "North South University" in the text, or a known course code.
- **Tags come from the folder** (the ones most of its files carry), never from the model.
- `Documents/Secure` only with high confidence; a guess goes to review instead.
- The answer is generated in order *what is it → which folder's purpose matches and why →
  folder*: a reason written after the choice would only defend it.
- **Unreadable is not clean:** if text recognition fails (it's retried once), the file can't be
  checked for sensitive text, so it goes to review, never into a folder as if it were safe.
- confidence is chosen as high / medium / low (small models are poor at exact numbers):
  0.9 / 0.75 / 0.4, with a threshold of 0.75. Below it, the file goes to review.
- if Apple Intelligence is off or still downloading, leftovers simply go to review.
- sensitive files (safety rules) are never renamed by the model.

`organize model` shows whether the model is available; `--no-model` runs rules only.

## Safety, in code

- Never deletes. Never overwrites: a different file with the same name gets the date added
  (`Report (2026-10-13).pdf`).
- Duplicates are identical SHA-256 content only, never just the same name. A duplicate is
  reported and parked in review.
- Every destination is checked: it must be inside Documents, Pictures, Movies, Music,
  Developer or the review folder; no `..`, no hidden folders, no `Library`, never inside the
  Photos library or an app bundle; at most 3 new folders per file.
- Model suggestions below the confidence threshold, or with tags that aren't on the allowlist,
  are rejected.
- Downloads still in progress (`.crdownload`, `.download`, `.part`) are skipped.

## Applying and undoing

- **Checked again just before moving:** a file whose size or modification date changed since
  the plan (still downloading, edited) is skipped. The destination is validated again too.
- **Never overwrites:** the move is a single exclusive `renamex_np(RENAME_EXCL)` call, so it fails
  if anything is at the destination, even a file that appeared a moment earlier. Between disks it
  copies, verifies the SHA-256, and only then removes the original.
- **No escaping the home folder:** symlinks are resolved, so a linked folder can't redirect a file
  elsewhere.
- **Write-ahead log:** each move is logged as "pending" (fsync'd) before the file is touched and
  "done" afterwards, in append-only JSON Lines (`TestData/moves.jsonl` in the sandbox,
  `~/Library/Application Support/DirectoryOrganizer/moves.jsonl` for your real folders). An interrupted
  run is settled on the next start by checking where the file actually is. A line cut short by a
  crash is skipped (and reported), so it never hides the rest of the history.
- **Tags:** `com.apple.metadata:_kMDItemUserTags`, a binary plist of `"Name\nColor"` strings
  (NSU 4, FSAE 2, Personal 3, Secure 6). Tags already on the file are kept.
- **Origin note:** each moved file gets a small `io.github.n1soryu.directory-organizer.origin`
  attribute with its original path.
- **Undo restores the original state exactly:** original folder and name, original tags, origin
  note removed, and folders the move created removed again (only if empty; `rmdir` refuses
  otherwise). If the original name has been taken since, the file comes back with the date
  added rather than overwriting.

## Folders in Downloads

A downloaded folder is read all the way down (up to 6 levels and 2,000 items; hidden items and
bundle contents skipped): file count, kinds, total size, a sample of paths, and the newest change
anywhere inside.

- **Safety inside:** every file inside (up to 300) gets the same checks as a file in Downloads. A
  folder with a password export, key or recovery phrase anywhere inside goes to review whole, with
  an alert per file, and is never unpacked.
- **Still changing?** A folder that changed in the last 30 s is skipped ("still being unzipped or
  copied?") and the app looks again once it should have settled. When moving, the folder's
  size and date are the whole tree's, so a change anywhere inside since planning skips the move.
- **Rules first:** code projects (`.git`, `package.json`, `Package.swift`…) and empty folders go to
  review whole.
- **Keep together or unpack (Organize Now):** for other folders the model is asked whether the items
  belong together (a project, an album, a course pack) or are separate things. Unpacked folders
  are replaced in the plan by what's inside (2 levels at most, 200 files at most), each item
  placed on its own; the emptied folder later goes to review. Without the model nothing is unpacked.
- A plain folder has no extension: `Dune.Part.Two.2024.1080p.WEB-DL` is all name.

## Quick scans and Organize Now

The app splits the work in two:

- **Quick scan, automatic.** Whenever something lands in the watched folder: rules only, no text
  recognition, no model, so it takes seconds and barely uses the Mac. Courses, records, films,
  installers, password exports, duplicates and the like show up ready to approve right away.
- **Organize Now, when you press it** (menu bar, dashboard toolbar, or ⇧⌘O). The heavy work:
  text recognition for images and scanned PDFs, and Apple's model for files no rule fits and for
  unclear names, asked fresh. Progress shows in the menu bar (percentage, current file and step,
  elapsed time) with **Cancel** (⌘.); cancelling is safe because planning only reads. A
  notification summarizes the run, and its results stick to each file until it changes.

Files the quick scan can't decide are listed as **waiting for Organize Now**. Every image and
scan waits, even an ordinary-looking photo: without text recognition a photographed recovery
phrase can't be told apart from a holiday picture, so nothing unread is ever filed.

`organize plan <folder> --quick` shows what the quick scan sees.

## Design

One idea runs through the app: **lanes**. Every destination has a color and a symbol
(University blue, FSAE green, Secure red, Essays purple, Movies orange, Pictures pink, Review gray),
used for the destination bar on Overview, the groups on Pending Approval, the menu-bar rows and
the folder cards. The main action, **Organize Now**, is the one gradient button. Pages are
rounded cards on the window background, in light and dark mode.

The icon (three lane-colored files dropping into a tray, with a sparkle) is drawn in code:
`swift scripts/make-icon.swift` regenerates `Resources/Icon/AppIcon-1024.png` and
`Resources/AppIcon.icns`.

<img src="images/alerts-dark.png" alt="Alerts page in dark mode">

## The app (menu bar + dashboard)

**Menu bar (compact):** status (watching / scanning / paused), **Organize Now** (with how many
files are waiting, or the progress and Cancel while it runs) and the last run's summary, counts
(pending, waiting, alerts, in review), the top alerts, the next files with ✓ approve / ✕ reject, Approve All, Scan, Pause,
Open Dashboard.

**Dashboard (detailed):**

| Page | Shows |
|---|---|
| Overview | a header with the state and the main actions, four counts, **where your files are headed** (a bar split by destination), what needs attention, activity, last quick scan and Organize Now, model status |
| Pending Approval | files waiting for Organize Now, then every proposed move **grouped by destination** (approve a whole group at once), with filters, search and ⌘-click multi-select. Each row: alerts, original and new name, the reason, who decided, a confidence ring, approve / reject. Rejected files have their own filter. The detail panel has a Quick Look preview, the plan, alerts explained, and **every fact read from the file**: source URLs, dates, title, pages, image info, archive contents, and the text or OCR the decision was based on |
| Alerts | grouped by kind (sensitive, duplicate, rejected suggestion, name clash, unknown course), each explained |
| History | every batch and move from the log, with undo per move or per batch |
| Review Folder | what's waiting in `To Delete (Review)` and why, put-back, reminder schedule |
| Folders | the folders files can go to, what each is for, its tags, item counts, folders the app created |
| Settings | sandbox or real folders, watching, model on/off and status, auto-apply per category, notifications and reminder interval, access to your real folders |

**How it runs:**
- **Watching:** FSEvents on the watched folder. A burst of changes (a download being written)
  becomes one quick scan a few seconds later; a scan requested during a scan (or during
  Organize Now) runs right after it.
- **Rejected files** stay where they are and stay out of the plan until they change.
- **Notifications:** sensitive files right away, new files ready to file (when the app isn't in
  front), auto-filed files, and the **review folder reminder every 8 hours** while it isn't empty
  (4/8/12/24 h in Settings). Clicking one opens the matching dashboard page.
- **Auto-apply** (off by default, per category): only rule decisions at 90%+ with no alerts.
  Model decisions, sensitive files and duplicates always wait for you.
- **Real folders stay locked:** the app refuses ~/Downloads, Documents, Desktop, Pictures, Movies
  and Music, even if chosen in Settings. Settings shows the permission status for them
  ("Check Access" triggers the macOS prompts) and links to Full Disk Access, for when real use is
  switched on.
- Settings are saved in `~/Library/Application Support/DirectoryOrganizer/settings.json`
  (debug runs use a throwaway copy); the sandbox move log is shared with the `organize` command
  (`TestData/moves.jsonl`).
- **Real folders:** "Switch to My Real Folders" (with a confirmation) watches `~/Downloads` and files
  into your home folder. Only items that arrived in Downloads after the switch are considered
  (`Planner.onlyAddedAfter`); auto-filing and earlier rejections are reset. The `organize` command
  stays sandbox-only.

## Layout

```
Sources/OrganizerCore/   facts, safety, rules, planning, applying (no UI)
  Facts/       FactExtractor, PDF/Office/OCR/media readers, xattrs, hashing
  Naming/      unclear-name check, name cleaning, film/TV name parsing
  Safety/      sensitive-file detector, BIP-39 wordlist
  Rules/       rules engine and the rules above
  Classify/    FileClassifier protocol, AppleClassifier (Foundation Models), FactSummary
  Planning/    Planner (duplicates, clashes, new folders), DestinationValidator
  Apply/       Applier, Undoer, SafeMove, MoveJournal (write-ahead log), FinderTags
  Config/      folder layout, record types, NSU course catalog, FolderCatalog (folders offered to the model),
               FolderProfile (what your folders hold, learned)
Sources/TestDataKit/     generates realistic fake downloads + expected results
Sources/organize/        the CLI (plan, apply, undo, log, model, facts)
Sources/DirectoryOrganizer/  the menu-bar app: AppModel (state, scans, moves), Views/ (dashboard pages)
  App/ (in OrganizerCore) FolderWatcher (FSEvents), AppSettings, AutoApplyPolicy, ReviewReminder
docs/                    this file, the CLI cheatsheet
```

Test data (fake password exports, keys and recovery phrases included) is generated locally and
never committed.
