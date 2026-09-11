# Built-in tools and `ask_user`

The app ships one built-in pack, **Shell**, which appears to the model as `shell__run`. It needs nothing installed. The user can turn it off in Settings › Tools; an imported task that needs it imports with a warning and fails at run time until it is re-enabled.

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

## `ask_user` — only when `allowsSteering` is `true`

| Tool | What it does | Arguments |
|---|---|---|
| `ask_user` | Shows a question in the run window and suspends until the user answers (or stops the run). | `question*` |

Not attached in `tools[]`; the app adds it automatically for interactive tasks. Tell the model when to use it ("ask_user before any destructive step", "if the brief is ambiguous, ask_user once, then proceed") and when not to ("do not ask for confirmation of read-only steps"). Non-interactive tasks should be written to finish without questions.

## Renamed from Bash

Files exported by older versions of the app use `"builtin": "bash"` and mention `bash__run` in prompts. The app still imports `"bash"` as the Shell pack, but the tool the model sees is now `shell__run`, so rewrite prompt references when you touch such a file. The old `files` pack no longer exists; replace `files__*` calls with the shell recipes above.
