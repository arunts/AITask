# Website

The site at `docs/` is generated; GitHub Pages serves it from the `main` branch, folder `/docs`
(Settings › Pages › Build and deployment › Source: *Deploy from a branch*, branch `main`, folder `/docs`).

```
site/
  build.py          the generator (Python 3, standard library only)
  templates/        one HTML body per page type; base.html wraps them all
  static/           site.css, site.js, the app icon
  tasks/            the task repository: one AITaskDefinition .json per task + catalog.json
  downloads/        release files served as-is (the notarized AITaskRunner.dmg)
docs/               OUTPUT. Do not edit by hand; rebuild instead.
```

## Rebuild

```bash
python3 site/build.py          # writes docs/ from scratch
python3 site/build.py --check  # only validates the task catalog
```

Rebuild and commit `docs/` after changing anything under `site/` or `skills/ai-task-author/`
(the skill is zipped into `docs/downloads/` and its Markdown is rendered under `docs/skill/`).

## Add or update a task

Tasks are kept wherever you author them; the site holds a copy plus a catalog entry. One command does both:

```bash
python3 site/build.py add ~/path/to/"Find PII in Folder.json" \
    --description "One or two sentences for the card." --tags files,productivity --featured
python3 site/build.py            # then rebuild
```

- The slug (URL `/tasks/<slug>/` and download name) comes from the task name; override with `--slug`.
- The file is validated with the skill's `validate_task.py` first; an error means nothing is written.
- `--tags` are keys from `categories` in `catalog.json`; `--featured` puts the task on the landing page
  (the first four featured tasks are shown), `--no-featured` takes it off.
- The source path is recorded in the catalog entry (`"source"`, written with `~`), so the copy can be
  refreshed later.

After editing a task where it lives:

```bash
python3 site/build.py sync       # re-copies every task whose source changed (each is validated first)
python3 site/build.py list       # shows every task, its tags, and whether the copy is in sync
python3 site/build.py            # rebuild
```

Running `add` again on a task that is already in the catalog refreshes its copy and only changes the
description, tags or featured flag when you pass them. The build itself prints a note for any copy
that no longer matches its source. To drop a task, delete its file and its catalog entry.

Tool chips, variable counts, "needs" (nothing / shell / MCP) and the interactive flag are derived from the file.

## Configuration

At the top of `build.py`:

- `REPO` — read from the `origin` git remote at build time (falls back to `OWNER/AITaskRunner` until a remote exists), used for the Source link and the fallback download URL. Rebuild after adding the remote.
- `DMG_NAME` / `DOWNLOADS` — the notarized disk image is hosted by the site itself. After `scripts/release.sh`, copy the result to `site/downloads/AITaskRunner.dmg` and rebuild; it is served from `docs/downloads/AITaskRunner.dmg`, every Download button points at it, and the landing page shows its size and SHA-256. When the file is absent the buttons fall back to the GitHub releases page.

The version shown on the site is read from `MARKETING_VERSION` in the Xcode project.

## Preview locally

```bash
python3 site/build.py && python3 -m http.server -d docs 8765
# open http://127.0.0.1:8765/
```
