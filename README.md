# File Organizer

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
| 3 | Apple Foundation Models classifier (text + images), Ollama fallback | next |
| 4 | Menu-bar app, Downloads watcher, approval UI, review-folder reminder every 8 hours | |
| 5 | Night runs: plugged in, idle, cool, within a time window | |
| 6 | Evaluation on a labeled test set: rules only vs rules + model | |

## Try it

Needs macOS 27 and Swift 6 (the Command Line Tools are enough; Xcode isn't required).

```sh
swift run make-testdata                      # builds TestData/Downloads and TestData/Home
swift run organize plan TestData/Downloads   # shows the plan; nothing is moved
swift run organize apply TestData/Downloads  # shows the plan, asks: all / one by one / cancel
swift run organize undo --last               # puts the last batch back exactly as it was
swift run organize log                       # history of moves and undos
./scripts/test.sh                            # runs the tests
```

All commands, plus macOS commands for checking tags and attributes: **[docs/CLI-CHEATSHEET.md](docs/CLI-CHEATSHEET.md)**.

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
9. Anything else → the model (Milestone 3). Until then: review.

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
  "done" afterwards, in append-only JSON Lines (`TestData/moves.jsonl` for now). An interrupted
  run is settled on the next start by checking where the file actually is.
- **Tags:** `com.apple.metadata:_kMDItemUserTags`, a binary plist of `"Name\nColor"` strings
  (NSU 4, FSAE 2, Personal 3, Secure 6). Tags already on the file are kept.
- **Origin note:** each moved file gets a small `io.github.n1soryu.directory-organizer.origin`
  attribute with its original path.
- **Undo restores the original state exactly:** original folder and name, original tags, origin
  note removed, and folders the move created removed again (only if empty; `rmdir` refuses
  otherwise). If the original name has been taken since, the file comes back with the date
  added rather than overwriting.

## Layout

```
Sources/OrganizerCore/   facts, safety, rules, planning, applying (no UI)
  Facts/       FactExtractor, PDF/Office/OCR/media readers, xattrs, hashing
  Naming/      unclear-name check, name cleaning, film/TV name parsing
  Safety/      sensitive-file detector, BIP-39 wordlist
  Rules/       rules engine and the rules above
  Classify/    FileClassifier protocol + stub (the model plugs in here)
  Planning/    Planner (duplicates, clashes, new folders), DestinationValidator
  Apply/       Applier, Undoer, SafeMove, MoveJournal (write-ahead log), FinderTags
  Config/      folder layout, record types, NSU course catalog
Sources/TestDataKit/     generates realistic fake downloads + expected results
Sources/organize/        the CLI (plan, apply, undo, log, facts)
docs/CLI-CHEATSHEET.md   every command in one place
```

Test data (fake password exports, keys and recovery phrases included) is generated locally and
never committed.
