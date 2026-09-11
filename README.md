# AITaskRunner

A Mac app for defining and running bare-bones tasks on local models: Ollama, LM Studio, llama.cpp, vLLM or Apple's on-device model.

A task is the smallest set of instructions that gets a job done: what to do, and the inputs to ask for. The app sends the model exactly that and nothing else, so small models with small context windows stay on track. Save the tasks you repeat, run them on demand or on a schedule, and share them as small JSON files.

- **Download:** the notarized disk image is on the project website (served from `docs/`), or pick it up directly from [`docs/downloads/AITaskRunner.dmg`](docs/downloads/AITaskRunner.dmg).
- **Requirements:** macOS 26.5 or later. For local models, any server that speaks `/v1/chat/completions`; Apple's on-device model needs Apple Intelligence.
- **Task format and authoring:** see the [spec](docs/spec/) and the [ai-task-author skill](skills/ai-task-author/), which teaches an AI assistant to write task files for you.

## Building from source

Open `AITaskRunner.xcodeproj` in Xcode 26.6 or later and run the `AITaskRunner` scheme. No dependencies beyond the SDK.

Signing is configured outside the tracked project file so the repository carries no team identifiers:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then put your Team ID in it
```

`Config/Local.xcconfig` is git-ignored. Without it the project still builds and runs locally with development signing.

## Releasing

`scripts/release.sh` archives a Release build, exports it with a Developer ID certificate, notarizes and staples both a `.dmg` and a `.zip`, and prints the command that publishes the disk image on the website. It needs a notarization keychain profile; the setup line is at the top of the script.

## Website

`site/` holds the generator, templates, task repository and release downloads; `docs/` is its output and is served by GitHub Pages. See [site/README.md](site/README.md).

```bash
python3 site/build.py
```

## Layout

```
AITaskRunner/         app sources (SwiftUI, macOS 26)
AITaskRunner.xcodeproj
Config/               signing xcconfig (local values git-ignored)
scripts/              release.sh, ExportOptions.plist
site/                 website generator, templates, tasks, downloads
docs/                 generated website (GitHub Pages)
skills/ai-task-author task-authoring skill for AI assistants
```
