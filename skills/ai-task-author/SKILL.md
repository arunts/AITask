---
name: ai-task-author
description: Turn a plain-language description of a job into an AITaskDefinition JSON file that the AITaskRunner Mac app imports. Use this whenever someone wants to create, design, write, draft or export a task, job, recipe, automation, or prompt for AITaskRunner, mentions AITaskDefinition, a task definition file or "import into AITaskRunner", or asks what a local model could do for them with files, shell commands or MCP tools. Guides them through name, prompts, variables, tools and interactivity, then writes and validates the file.
---

# AI Task Author

AITaskRunner is a Mac app that runs saved "tasks" on any OpenAI-compatible endpoint (Ollama, LM Studio, llama.cpp, vLLM, MLX and others, local or remote) or Apple's on-device Foundation model. A task is saved as a JSON file with `"format": "AITaskDefinition"` and holds:

- a **system prompt** (the model's job description, optional),
- a **user prompt** (the concrete job, required),
- **variables** the user fills in before each run, referenced as `{{key}}`,
- **tools** the model may call: the built-in Shell pack, or MCP servers,
- an **interactive** switch that gives the model an `ask_user` tool and a chat box.

Your job: interview the user briefly, write the prompts, pick the tools, produce `<Name>.json`, validate it with the bundled script, and tell them how to import it. Model choice and sampling settings are picked inside the app, never in the file, so do not ask about them.

## Tools a task can use

**Built into the app** (nothing to install; details, arguments and file recipes in `references/builtin-tools.md`).

| Tool | Does |
|---|---|
| `shell__run` | Run a command line in the login shell, with per-command approval. Reading, writing, finding and moving files all go through it (`ls`, `cat`, `find`, `grep`, heredocs, `mv`). |
| `ask_user` | Ask the user a question mid-run (interactive tasks only; not listed in `tools`) |

Shell commands are not confined to a folder; the user approves each one in the run window. Inside the AITaskRunner repo, `python3 scripts/list_builtin_tools.py` prints the live list from the Swift sources; `--check` confirms the validator agrees with them.

**When the shell is not enough**, read `references/mcp-servers.md`: it has a ladder (built-in shell → servers the user already has → known servers → search the MCP registry → say no and offer a shell fallback), a table of known servers with ready-made definitions, and how to verify a server and its tool names before writing them into a file. Never invent a server or tool name from memory; confirm it first.

## Workflow

### 1. Understand the job
Restate in one sentence what the task should produce each time it runs. From the description, work out:
- what changes from run to run → **variables** (text, file, folder or list),
- what the model has to touch → **tools** (none, Shell, an MCP server),
- whether it needs to check in mid-run → **interactive**.

### 2. Ask only what changes the file
Put every open question in one message and suggest a default for each, so "looks good" is a complete answer. Skip anything the description already settles. Typical questions:
- Which inputs differ per run, and their defaults (a folder, a topic, a URL, pasted text)?
- Which folders may it read or write? Should output go to a file or just the transcript?
- What should the output look like (Markdown, bullets, a table, JSON)?
- May the model ask questions during the run, or should it finish unattended?
- If an external service is needed: which MCP server do they already have, or which one should the file define?

### 3. Write the prompts
Read `references/task-format.md` for the exact JSON before writing. Guidance that matters for small local models:
- **System prompt** = job description: persona, binding rules phrased Always / Never / Only, output format, tool habits. Keep it general; the specific job goes in the user prompt.
- **User prompt** = the concrete job with `{{variables}}`, explicit tool names (`shell__run`, `<server>__<tool>`) and, for shell steps, the actual command to run. Numbered steps beat prose for 7B-class models. Say exactly what to output and when to stop.
- One job per task. Short beats thorough: the Apple Foundation model has roughly a 4K-token window, and small local models pick tools badly when the context is crowded.
- Interactive tasks: tell the model when to call `ask_user` ("Before trashing anything, ask_user to confirm the list").

### 4. Pick tools
- Prefer the built-in shell: `{ "builtin": "shell" }`. It runs commands with per-command approval and covers files, git, brew, curl and anything else with a CLI. Recipes are in `references/builtin-tools.md`.
- Add an MCP server only when the shell cannot do it well, following the ladder in `references/mcp-servers.md`. Define it under `mcpServers` in the same shape Claude Desktop uses; the task refers to it by its slug. Tell the user what runtime to install (Node for `npx`, uv for `uvx`).
- Never put API keys or tokens in the file. Leave `env` and `headers` out, and tell the user to add them in Settings › Tools after importing. If a header is structurally required, use an obvious placeholder such as `REPLACE_ME`.

### 5. Write, validate, deliver
1. Write `<Task Name>.json`, pretty-printed UTF-8, in the working directory or wherever the user asked.
2. Run the validator and fix every error. Keep a warning only when it is intentional, and say why.
   ```bash
   python3 <skill-dir>/scripts/validate_task.py "<file>"
   ```
3. Report: a short summary (what it does, its variables, its tools, whether it is interactive), the validator output, and the file path.
4. Import instructions for the user: in AITaskRunner choose File › Import Task… (⌘⇧I) or the + button above the task list, pick the file, check the preview, and click Import Task. Servers the file defines are added automatically. Then pick a model in the toolbar and press Run (⌘R); variables are asked for before each run.

## What the importer refuses (errors)
- Missing `"format": "AITaskDefinition"`, `"version": 1`, or a `"task"` object. (`"oddjobs-task"`, the old name, still imports.)
- Empty `task.userPrompt`.
- A `tools[]` entry that is neither `{"builtin": "shell", ...}` nor `{"server": "<slug>", ...}`, an unknown built-in pack, or an unknown built-in tool name.
- A `server` slug with no definition under `mcpServers` (unless a server with that slug already exists in the app).
- An `mcpServers` definition without `command` (stdio) or `url` (http).

## What goes wrong silently (warnings)
- A `{{placeholder}}` with no matching variable is sent to the model as literal text.
- Variable keys are sanitized to letters, digits, `_`, `.`, `-`; spaces become `_`. Use the sanitized form in the prompts.
- `tools[].server` must equal the slug of the `mcpServers` key: lowercase, `a-z`, `0-9` and `-` kept, everything else becomes `_`. Lowercase keys avoid surprises.
- If the app already has a server with the same slug, the file's definition is ignored and the existing one is reused.
- The Shell pack can be turned off in Settings › Tools; the import succeeds with a warning.
- `tools: null` (or omitted) means every tool the server offers, including ones added later.
- `"builtin": "bash"` (the pack's old name) still imports as Shell, but prompts must say `shell__run`.

## Examples
Four complete files live in `assets/examples/`: prompt-only, Shell for files, Shell plus interactive, and an MCP server. Start from the closest one and adapt it rather than writing from scratch.
