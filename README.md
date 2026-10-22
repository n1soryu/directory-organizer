<img src="Resources/Icon/AppIcon-1024.png" width="112" alt="Directory Organizer icon">

# Directory Organizer

An offline macOS menu-bar app that sorts your downloads into the right folders, renames unclear
files and adds Finder tags. Simple rules handle the obvious cases; an on-device language model
(Qwen3 8B, run with MLX) handles the rest. **Nothing moves until you approve it, and every move can be undone.**

<img src="docs/images/overview.png" alt="Overview: what's ready, where it's headed, what needs attention">

| Pending approval, grouped by destination | Menu bar |
|---|---|
| <img src="docs/images/pending.png" alt="Pending approval"> | <img src="docs/images/menubar.png" width="300" alt="Menu bar"> |

## What it does

- **Watches Downloads** and sorts new files within seconds with rules: course files by course code,
  NSU records (dated), FSAE files, films and TV (cleaned names), installers, code projects.
- **Organize Now** (menu bar button) does the heavy work on demand: text recognition for images and
  scans, a vision model that looks at images (a photographed receipt is filed like a receipt; a
  photo gets a real name), and the on-device model for files no rule fits and for unclear names.
  It can propose new category folders ("Manuals", "Bills").
- **Folders too:** a downloaded folder is checked all the way down; the model decides whether it's
  one thing to keep together or a bag of files to unpack and sort one by one.
- **Safety first, in code, not left to the model:** never deletes, never overwrites (dated names
  instead), duplicates by content hash only, password exports / recovery phrases / private keys
  detected and reported, every model answer checked against the folders that exist.
- **Undo anything:** a write-ahead move log puts files back exactly as they were (name, folder, tags).
- **Fully offline:** the models run on your Mac (downloaded once, ~8 GB); no file is ever uploaded.

## Install

Download the latest `.zip` from [Releases](../../releases), unzip, and move the app to Applications.
It isn't notarized, so the first time: right-click the app → **Open** → **Open**.

Requires macOS 27 on Apple silicon (16 GB of memory recommended). The models are downloaded once in
**Settings → On-device models → Download Models** (~8 GB); until then, files no rule can place go
to review.

It starts on a test sandbox (`~/Developer/directory-organizer/TestData`, created with
`swift run make-testdata`). To use it on your own files: **Settings → Switch to My Real Folders**.
From then on it watches `~/Downloads`, but only files downloaded *after* the switch are touched;
auto-filing is off, so every move waits for your approval.

## Build from source

```sh
swift run make-testdata              # sandbox: fake downloads + a stand-in home folder
./scripts/build-app.sh --open        # build and open the app
./scripts/test.sh                    # run the tests
swift run organize plan TestData/Downloads   # or use the command-line tool
build/cli/organize model-check --download    # fetch the MLX models (~8 GB, once) and test them
```

Needs full Xcode with the Metal toolchain: it compiles the GPU shaders of
[MLX](https://github.com/ml-explore/mlx-swift), which runs the on-device models (Qwen3 8B, Qwen3-VL 4B for images and
Qwen3 Embedding, downloaded once in Settings; see [docs/mlx-plan.md](docs/mlx-plan.md)). The app is built with `xcodebuild`;
`swift run organize …` works too.

## Docs

- [How it works](docs/how-it-works.md): the pipeline, rules, safety checks, the model, the design
- [CLI cheatsheet](docs/CLI-CHEATSHEET.md): every command

## License

[MIT](LICENSE) © 2026 Niso Ryu
