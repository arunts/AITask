# Built-in tools and `ask_user`

The app ships three built-in packs, **Shell** (`shell__run`), **Context** (`context__clear`) and **Progress** (`progress__update`). They need nothing installed. The user can turn any of them off in Settings › Tools; an imported task that needs one imports with a warning and fails at run time until it is re-enabled.

## `shell` — one tool, `run`

| Tool | What it does | Arguments (`*` required) |
|---|---|---|
| `run` | Runs a command line in the user's login shell (`zsh -l -c`) and returns `$ command`, cwd, exit code, timing, stdout and stderr. | `command*`, `working_directory` (default: the folder set in Settings › Tools), `timeout_seconds` (Settings default 60, max 600) |

Behaviour:
- Every command is shown to the user for approval before it runs (Deny / Allow / Allow All This Run) unless they turned approval off in Settings › Tools › Shell.
- Commands are not confined to any folder; they can reach anything the user's account can. Say so in the prompt when the job is destructive, and make the prompt use the Trash rather than `rm`.
- Output is truncated at about 30 000 characters; tell the model to pipe through `head`, `tail` or `wc` for large output.
- Non-zero exit is reported as a tool error, which the model sees and can react to.
- `~` is expanded in `working_directory` and inside the command, as in any shell.

Working with files goes through the shell too. Recipes that small models follow well when spelled out in the prompt:

| Job | Command to name in the prompt |
|---|---|
| List a folder | `ls -la {{folder}}` or `find {{folder}} -maxdepth 1 -name '*.md'` |
| Read a text file | `cat "{{folder}}/notes.md"` (add `\| head -c 20000` to cap size) |
| Find files | `find {{folder}} -iname '*report*'`, `grep -ril "budget" {{folder}}` |
| Write a file | `cat > "{{folder}}/SUMMARY.md" <<'EOF'` … `EOF` |
| Append | `cat >> file <<'EOF'` … `EOF` |
| Make a folder | `mkdir -p "{{folder}}/archive"` |
| Move, rename, copy | `mv`, `cp -R` |
| Trash instead of delete | `osascript -e 'tell application "Finder" to delete POSIX file "/full/path"'` |
| Size of things | `du -sh {{folder}}/* \| sort -h \| tail -n 15` |
| File details | `stat -f '%N %z bytes %Sm' "path"` |

Prompt tips:
- Quote paths in the commands you write into the prompt, so spaces in the user's folders do not break them.
- One command per step. Small models handle "Run `ls …`. Then for each file run `cat …`" far better than a single pipeline that does everything.
- Read-only jobs: say "Only run commands that read; never write, move or delete." The user still approves each command, but the model then stops proposing risky ones.
- Output that must land on disk needs an explicit write step (heredoc); otherwise the result only appears in the run transcript.

## `context` — one tool, `clear`

| Tool | What it does | Arguments (`*` required) |
|---|---|---|
| `clear` | Drops everything in the conversation except the system prompt, the original user prompt and the note passed in. The model continues from a tool result that repeats the note. | `note*` |

Attach it with `{ "builtin": "context" }` when one run works through many large inputs one at a time: files in a folder, pages, tickets, records. Without it every file the model reads stays in the conversation, and once one item fills the window the run fails; the app only stubs out *older* tool results, never the latest.

Behaviour:
- Only three things survive a clear: the system prompt, the task's user prompt (with variables filled in), and the note. Anything the model has not written to disk or put in the note is gone. Tell the prompt to save each item's output (heredoc, `>>`) *before* clearing.
- A blank note clears nothing and returns an error, so a model that forgets the note keeps its state.
- Tool calls the model issues after `context__clear` in the same reply still run; ones before it lose their results.
- The round counter restarts, so a run that clears between items is not stopped by the 50-round limit.
- The run window shows the clear as a tool call plus a "Context cleared" notice, and the context gauge drops.
- Not available on the Apple on-device model: the tool is skipped with a notice and the run proceeds without it.

Recipe for "do X to every file in a folder", written for small models:

```
1. Run shell__run with: find "{{folder}}" -maxdepth 1 -name '*.md' | sort
2. Take the first file not yet done. Run shell__run with: cat "<path>"
3. Do the job for that file. Write the result with shell__run: cat > "<path>.summary.md" <<'EOF' … EOF
4. Call context__clear with a note like: "Done: a.md, b.md. Remaining: c.md, d.md. Output goes next to each file as <name>.summary.md."
5. Repeat from step 2 with the next remaining file. When none remain, reply "All files done." and stop.
```

Put the list of remaining files in the note; after a clear the model no longer remembers the `find` output.

## `progress` — one tool, `update`

| Tool | What it does | Arguments (`*` required) |
|---|---|---|
| `update` | Records how far a multi-step job has got. The run window shows a small bar and `done/total` in the toolbar, next to the Thinking and Tool Calls toggles. | `done*` (0 … total), `total*` (≥ 1) |

Attach it with `{ "builtin": "progress" }` when the job has a countable list: files in a folder, pages, records, or numbered steps in the prompt. Without it the user only sees the transcript scroll by.

Behaviour:
- Plain integers; the tool accepts numbers sent as strings. `done` above `total`, a `total` below 1, or a missing argument returns an error that tells the model what to pass. Nothing else happens: the value is display only.
- Each call replaces the previous value; the last one stays in the toolbar after the run ends. The bar turns green when `done` equals `total`.
- Works on every model, the Apple on-device model included.
- Survives `context__clear` (the app keeps it, not the conversation), so a task that clears between items can still report progress; after a clear the model must get `done` and `total` from its note.

Prompt line that small models follow:

```
After finishing each file, call progress__update with done = number of files finished so far and total = number of files found in step 1.
```

Call `progress__update` with `done` equal to `total` as the last step before the final reply, so the bar completes.

## `ask_user` — only when `allowsSteering` is `true`

| Tool | What it does | Arguments |
|---|---|---|
| `ask_user` | Shows a question in the run window and suspends until the user answers (or stops the run). | `question*` |

Not attached in `tools[]`; the app adds it automatically for interactive tasks. Tell the model when to use it ("ask_user before any destructive step", "if the brief is ambiguous, ask_user once, then proceed") and when not to ("do not ask for confirmation of read-only steps"). Non-interactive tasks should be written to finish without questions.

## Renamed from Bash

Files exported by older versions of the app use `"builtin": "bash"` and mention `bash__run` in prompts. The app still imports `"bash"` as the Shell pack, but the tool the model sees is now `shell__run`, so rewrite prompt references when you touch such a file. The old `files` pack no longer exists; replace `files__*` calls with the shell recipes above.
