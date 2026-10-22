# Plan: on-device models with MLX (language, vision, embeddings)

Status: **Milestones A and B done** (2026-10-21/22); C is next. Plan written and approved 2026-10-21.
Each milestone gets its own detailed plan, shown to the user before work begins, and ends with a commit.

## Why

Apple's on-device Foundation Model (~3B) wasn't smart enough to file documents. A benchmark on
this Mac (Apple M5, 16 GB) compared MLX (built into the app) with Ollama, both running Qwen3 8B.
The report is in `~/Developer/mlx-experiment/REPORT.md`; the code, test files and raw results are kept there.

- MLX was faster (~27 vs ~24 tok/s, and steadier under heat) and used less memory (5.2–5.8 GB vs 6.9–8.0 GB).
- Describing files was equal (27/27 kinds correct). JSON was valid on the first try without forcing a format.
- Folder decisions need thinking on: MLX `Qwen3-8B-4bit-DWQ` scored 11/12, the same as Ollama, at about 1 minute per decision.
  With thinking off, every setup got only 4–7/12.
- The embedding model `Qwen3-Embedding-0.6B` put the right earlier files in the top 3 for 10/10 files,
  at ~36 ms per file. A similarity cut-off can **not** detect "no match": that's the language model's job.
- Users install nothing: the app downloads its models once.

## Decisions (user, 2026-10-21)

1. **Apple's Foundation Models are removed entirely**: `AppleClassifier`, `FoundationModels`, the
   Apple Intelligence availability checks and settings UI, and `NLEmbedding` in `Grouper`.
   Without downloaded models, leftover files go to review.
2. **A vision model is added**, because photos and images without text need it.
3. **"Wait" files stay in Downloads.** There is no holding folder (`Documents/Unsorted` is gone from the design).
4. **Thinking is on for decisions**; about 1 minute per file is acceptable.

Earlier decisions that still hold:
- Regrouping only pulls files the app filed itself, and moving earlier files always asks first.
- New folders are created only for a group (the new file + at least one earlier file).
- Never delete anything.
- No Apple Developer ID; the app stays ad-hoc signed.
- Signed git commits (SSH), and a commit per milestone.
- Sandbox only (`TestData`) until the user says otherwise.
- Don't tune prompts with examples taken from the test or evaluation data.

## Models (all MLX, all downloaded on first use, revisions pinned)

| role | model | size | thinking | loaded when |
|---|---|---|---|---|
| Language: cards + decisions | `mlx-community/Qwen3-8B-4bit-DWQ` | 4.6 GB | off for cards, on for decisions | Organize Now, text phase |
| Vision: cards for images | `Qwen3-VL-4B-Instruct` 4-bit (`VLMRegistry.qwen3VL4BInstruct4Bit`, or `mlx-community/Qwen3-VL-4B-Instruct-4bit`, 3.1 GB) | ~3 GB | n/a | Organize Now, image phase |
| Embeddings | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` | 0.35 GB | n/a | all of Organize Now |

The vision model choice is **provisional**: Milestone C starts with a small image evaluation
comparing Qwen3-VL-4B and Gemma 3 4B (`mlx-community/gemma-3-4b-it-qat-4bit`, 3.0 GB), and the better one is kept.

**Memory rule:** never load the vision model and the 8B together; 3 + 5.8 GB is too much on 16 GB.
Organize Now runs the image phase first, unloads the vision model, then runs the text phase.
The embedder (0.35 GB) can stay loaded. Everything is released when Organize Now ends.

## The pipeline

```
New download
   ├─ rules (safety, installers, code projects, incomplete downloads…)  unchanged
   └─ leftover file
        1. Card    images/photos → vision model; text, PDF, Office, scans (OCR text) → Qwen3 8B, thinking off
                   card = kind, issuer, subject, date, people, suggested_name, summary
        2. Embed   card text → Qwen3-Embedding → vector, saved in the catalog
        3. Shortlist  nearest 5 candidates from the catalog
        4. Decide  Qwen3 8B, thinking on: join / new_folder (+ earlier files) / wait
        5. Swift validates every answer → plan → user approves moves of earlier files
```

## Milestones

### A. The MLX engine (no behaviour change) — done 2026-10-21
Outcome: the `.app` and `build/cli/organize` find `mlx-swift_Cmlx.bundle` next to their executable (in
`Contents/Resources` for the app), also when copied elsewhere. `model-check` on this Mac: card JSON valid on the
first try; thinking hit a 1,024-token test cap and budget forcing still gave the right answer; ~25.6 tok/s;
peak 5.2 GB; embeddings 14 ms per text after warm-up. A cancelled download keeps finished files only.
1. **Spike first:** add `mlx-swift-lm` (3.32.3 or newer; pin it). Build the app with `xcodebuild`, since only
   xcodebuild compiles MLX's Metal shaders, and confirm the finished `.app` finds `mlx-swift_Cmlx.bundle`
   / `default.metallib` when opened from Finder. This is the riskiest step.
2. **No library macros.** Write the two small adapters (`Downloader` over `HubClient`, `TokenizerLoader` over
   `AutoTokenizer`) by hand, so there's no swift-syntax dependency and no `-skipMacroValidation`.
3. **`MLXEngine` actor**, the only way into the GPU:
   - load and unload models, one at a time;
   - generate with a thinking flag and a thinking cap (the benchmark hit 4,096 tokens twice);
   - strip `<think>…</think>` (MLX streams it inline for Qwen3);
   - parse JSON leniently (accept a ```json fence) and retry up to 2 times with
     "That answer is invalid: … Answer again with one JSON object only."
4. **Model downloads in Settings:** one "Download models" action with progress and a free-space check.
   Files go to `~/Library/Application Support/DirectoryOrganizer/Models` via `HubClient(cache: HubCache(cacheDirectory:))`,
   with revisions pinned.
5. `organize model-check`: loads each model and runs one card, for testing outside the app.
6. Update `scripts/build-app.sh`, `scripts/package-release.sh` and `scripts/test.sh` for xcodebuild. The `.app` grows by ~25 MB.
7. **Tests:** `swift test` can't run MLX (no metallib). MLX sits behind protocols and is faked in unit tests;
   real-model checks are `model-check` and the evaluation harness (E).

Swift 6 language mode notes: build `UserInput` inside `ModelContainer.perform {}`, because it isn't Sendable.
The first guided-grammar compile blocks, so keep it off the main actor (only relevant if guided JSON is ever used).

### B. Cards with Qwen3 and removal of Apple's model — done 2026-10-22
Outcome (sandbox, `organize plan`, 7 min 12 s): both bills → new Documents/Bills; essay → Essays; the film folder →
Movies/Films (whole); lone files (shopping list, lab reminder, photo archive) → review. Lost compared with Phase 3: the
two manuals ("router user guide", "appliance manual") no longer group, since "guide" and "manual" are different main
words and grouping by meaning waits for D; each then wanted its own new folder, so both went to review. Images without
text get no new name until C. The user chose to port `suggest`/`placeGroup` as interim JSON prompts (thinking on) until E.
Correction to A: with full Xcode's Metal toolchain, `swift build` also builds MLX's shaders; `swift run` runs the model.
- `MLXClassifier: FileClassifier`. The card prompt is the benchmark's Task 1, and one card call replaces
  `describe` + `suggestName`. `suggestUnpack` and `describeFolder` are ported to JSON prompts.
- JSON schemas in prompts put `reason` first. Ollama/grammar lesson: field order changes decisions.
- Delete `AppleClassifier.swift`, the `FoundationModels` imports, the Apple Intelligence availability and
  settings UI, and the related tests. Update README / `docs/how-it-works.md`.
- Settings shows model status: not downloaded / downloading / ready.

### C. Vision model for images
1. **Image evaluation first:** a small, fixed set of images (photos of receipts/documents, screenshots,
   plain photos, memes, diagrams) with expected kinds, built in TestDataKit and never used as prompt examples.
   Compare Qwen3-VL-4B vs Gemma 3 4B on card accuracy, speed and memory, then keep the winner.
2. A `MLXVLM`-based card writer for images: the same card fields, thinking off, with the image resized to a sane
   maximum. Scans with plenty of OCR text may still go to the text model; decide from the evaluation.
3. Organize Now gets a separate image phase (load VLM → cards → unload) before the text phase.
4. The rules for images (`Pictures/Downloaded Images`) become the fallback only when no vision model is available.

### D. Embeddings and the catalog
**What gets embedded:** the card (`kind: …; issuer: …; subject: …; summary: …`), not the raw text. It exists for
every file type, including images through the vision card, and separated matches slightly better in the benchmark
(0.89 vs 0.87 average top score). Raw text is the fallback when the card call fails.

**The catalog:** `Application Support/DirectoryOrganizer/catalog.jsonl` (sandbox: next to `TestData/moves.jsonl`).
It's append-only JSON lines with a lock file, the same pattern as `MoveJournal`. One entry per file:

| field | why |
|---|---|
| move ID, or "waiting" | links to the move journal; waiting files have no move |
| current path | where the file is now |
| SHA-256 | recognises the file if it was renamed |
| card | the "about" line shown to the decision model |
| embedding (1,024 × Float16, base64) | ~2 KB per file |
| embedding model id + revision | vectors from a different model are rebuilt, never mixed |
| state | filed / waiting / gone / undone |

**Who is in it:**
- every file the app filed (rules or model);
- **waiting files in Downloads** that the app has carded.

Files you filed yourself are never catalogued and never pulled.

**Search:** brute-force cosine similarity over all live entries. That takes microseconds at thousands of
files, so no database or index is needed. Before ranking, filter to files that still exist where the catalog says and aren't undone or gone.

**Keeping it true:**
- Every app move updates the entry's path.
- Undo marks it undone.
- A file missing at search time is marked gone.
- A file found by hash elsewhere gets its path updated.

**Back-fill:** the first Organize Now after the update cards and embeds the earlier app-filed files once, with progress.

**`Grouper`:** the `NLEmbedding` label distance goes away. "Similar" now means near in the catalog,
and the model makes the final call.

### E. Decisions and regrouping
**Prompt:** the benchmark's Task 2 (reason first), plus your folder profiles (Phase 2) and corrections (undone moves).
Candidates are the top 5 from the catalog. A waiting candidate is shown as `folder: Downloads (waiting)`.

**Actions:**
- `join`: the new file goes into an existing folder.
- `new_folder`: create a folder (only under the allowed parents) for the new file plus at least one earlier file.
  Waiting files from Downloads can be pulled in like filed ones.
- `wait`: the file stays in Downloads, carded and catalogued.

**Swift checks every answer:**
- `join` folder must exist;
- `new_folder` must not exist, must sit under an allowed parent, and needs at least one earlier file;
- never Downloads or a folder inside it as a destination;
- earlier-file IDs only from the candidate list;
- IDs already in the target folder are dropped quietly;
- invalid after 2 retries → the file waits, which is safe.

**Approval:** pulling earlier files always asks first. It shows in Pending as one group ("Move 2 earlier
files into Documents/Rental"), and undo works on the whole group via the move journal.

**Waiting files aren't re-decided every run.** A waiting file is reconsidered only when a newly carded file lands
near it in the catalog. That happens as part of the new file's decision, since the waiting file is one of its candidates.

**Cost:** about 1 minute per leftover file (thinking on). The existing progress bar and Cancel cover it.

### F. Evaluation harness (the old Phase 6)
- `organize eval` runs the benchmark corpus (27 files, 12 scenarios; copied into TestDataKit) and the image set
  through the real pipeline, and prints the same scores as the benchmark: kind/issuer marks, ✓/~/✗ decisions,
  recall@3, speed and memory.
- Scenarios are updated for decision 3: there is no `Documents/Unsorted`, and earlier unsorted files sit in Downloads (waiting).
- It's a regression check for prompt or model changes. Never copy its examples into prompts.

Then the old phases resume: 4 (remove NSU/FSAE/course rules; only universal rules remain) and 5 (earned autonomy).

## Costs

| | |
|---|---|
| Disk | 4.6 GB (8B) + ~3 GB (vision) + 0.35 GB (embeddings) ≈ 8 GB, downloaded once |
| Memory during Organize Now | ≤ ~6 GB at any time (one big model at a time), 0 otherwise |
| Time | ~5 s per card, ~1 min per decision |
| App size | +~25 MB |
| Dependencies | from none to ~8 packages (mlx-swift, mlx-swift-lm, swift-huggingface, swift-transformers, swift-jinja, swift-crypto, swift-collections, swift-numerics, …); MIT/Apache licences |

## Open items (not blocking; decide when reached)
- What happens to files that wait in Downloads for a long time (a reminder after N days?).
- Whether very long documents need a smarter excerpt than the first 4,000 characters.
- Whether the `organize` CLI should also be able to download models, or only the app.
