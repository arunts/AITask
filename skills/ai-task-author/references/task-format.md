# Task definition file format (`AITaskDefinition`, `.json`)

Version 1. Strict JSON (no comments, no trailing commas). Encoding UTF-8. The app reads it with a tolerant decoder: unknown keys are ignored, missing optional keys take their defaults.

```json
{
  "format": "AITaskDefinition",
  "version": 1,
  "task": {
    "name": "Summarise Notes",
    "systemPrompt": "You are a concise technical writer. Always reply in Markdown.",
    "userPrompt": "1. Run shell__run with: ls {{notes_folder}}/*.md\n2. …",
    "allowsSteering": false,
    "requires": ["tools"],
    "variables": [
      { "key": "notes_folder", "type": "folder", "default": "~/Notes", "description": "Folder whose .md files are summarised" }
    ],
    "tools": [
      { "builtin": "shell" },
      { "server": "fetch", "tools": null }
    ]
  },
  "mcpServers": {
    "fetch": { "type": "stdio", "command": "uvx", "args": ["mcp-server-fetch"] }
  }
}
```

## Top level

| Key | Type | Required | Notes |
|---|---|---|---|
| `format` | string | yes | Must be exactly `"AITaskDefinition"`. Files written by earlier versions say `"oddjobs-task"`; the app still imports those, but always write the new name. |
| `version` | integer | yes | `1`. Anything else is refused. |
| `task` | object | yes | See below. |
| `mcpServers` | object | no | Definitions for every `server` slug the task attaches. Omit or leave `{}` when only built-ins are used. |

## `task`

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | `""` → shown as "Untitled Task" | Short, title case. Becomes the sidebar row and window title. |
| `systemPrompt` | string | `""` | Sent before the user prompt on every run. Variables and tool names are substituted/recognised here too. |
| `userPrompt` | string | — | **Required, non-empty.** The concrete job. |
| `allowsSteering` | bool | `false` | `true` = interactive: the run window shows a chat box and the model gets an `ask_user` tool. |
| `requires` | array of strings | `[]` | What the model must support: any of `"tools"`, `"vision"`, `"thinking"`. See Model requirements. |
| `variables` | array | `[]` | See Variables. |
| `tools` | array | `[]` | See Tools. |

Not part of the file (chosen in the app per machine): model, temperature, top_p, seed, max tokens, stop sequences, schedule, run history.

## Variables

Each entry:

| Key | Type | Default | Notes |
|---|---|---|---|
| `key` | string | — | Required. Sanitized on import: letters, digits, `_`, `.`, `-` are kept; whitespace becomes `_`; other characters are dropped. An entry whose key becomes empty is dropped. |
| `type` | `"text"` \| `"file"` \| `"folder"` \| `"list"` | `"text"` | `file` and `folder` show a Choose… button in the run sheet. `list` holds several values at once (see below). Unknown values fall back to `text`. |
| `default` | string | `""` | Pre-filled value; the user can override it before each run. `defaultValue` is accepted as an alias. Ignored for `list`. |
| `options` | array of strings | `[]` | `list` only: the values, at most 100. Blanks and repeats are dropped. `{{key}}` becomes all of them joined with `, `. The run sheet lets the user add or remove entries, and those edits are saved back onto the task. |
| `description` | string | `""` | One line shown under the field in the run sheet. Say what to enter. |

Reference a variable as `{{key}}` anywhere in either prompt (spaces inside the braces are tolerated). Every `{{…}}` must match a declared key: unmatched placeholders are sent to the model unchanged. Paths are substituted as typed; `~` is fine because the shell expands it.

Prefer a `folder` or `file` variable over asking the model to guess a path. Prefer a default that makes the task runnable without typing anything. Use a `list` when the prompt needs a set of values that grows over time (topics to cover, feeds to check, languages to translate into):

```json
{ "key": "languages", "type": "list", "options": ["French", "Japanese"], "description": "Languages to translate into" }
```

## Tools

Each entry attaches one tool source. Exactly one of `builtin` or `server`:

```json
{ "builtin": "shell" }
{ "server": "fetch", "tools": null }
{ "server": "github", "tools": ["search_issues", "get_issue"] }
```

| Key | Notes |
|---|---|
| `builtin` | `"shell"` or `"context"`. Unknown packs are refused. (`"bash"`, the shell pack's old name, is still accepted and treated as `shell`.) |
| `server` | Slug of a server defined under `mcpServers`, or of a server that already exists in the user's app. |
| `tools` | Array of tool names to expose, or `null`/omitted for every tool the source offers (including ones added later). Unknown built-in tool names are refused; MCP tool names cannot be checked at import time, so spell them exactly as the server reports them. |

The model sees each tool as `<slug>__<tool>`: `shell__run`, `context__clear`, `fetch__fetch`. Use those exact names in the prompts; the app highlights them and small models follow explicit names far more reliably than descriptions.

The file's top-level `version` is for the file schema only and stays at 1 until the layout of the file itself changes.

Order matters only for display. Attaching the same source twice is pointless; the last entry wins.

### How tool results reach the model

- Text content is joined and sent as the tool result; a result longer than about 60 000 characters is cut with a note.
- MCP **image** content (and embedded resources with an `image/*` blob; PNG, JPEG, WebP, GIF) is kept. An OpenAI-compatible model receives the images as `image_url` parts in a follow-up `user` message right after the tool result; the tool result itself keeps a numbered placeholder such as `[image 1: image/png]`. Up to about 24 MB of image data per result; the rest is dropped with a note.
- A model without vision (the server rejects the images) gets the text placeholder plus a note that images are not shown; the app switches to text-only for the rest of the run and says so in the transcript. Some servers silently ignore images instead of rejecting them. When the task lists `vision` under `requires`, a rejected image ends the run instead, and models known to lack vision are never tried.
- The Apple on-device model never receives images; it gets the placeholder and a note.
- Images returned by tools appear as thumbnails in the run window's tool calls.

## Model requirements

`requires` names what the model must be able to do. The app never runs the task on a model known to lack one of them, marks such models in the picker, and holds a scheduled run until the chosen model qualifies.

| Name | Means | When to list it |
|---|---|---|
| `tools` | The model can call tools. | Never needed by hand: implied whenever `tools` is non-empty or `allowsSteering` is `true`. Listing it is harmless. |
| `vision` | The model accepts image input, so it sees the images tools return (see "How tool results reach the model") instead of a text placeholder. | The job depends on looking at screenshots, rendered pages, charts or photos a tool returns. |
| `thinking` | The model reasons before answering (Qwen3, DeepSeek-R1, gpt-oss, Gemma 4 and other "thinking" models). | The job needs multi-step reasoning that plain instruction-tuned models get wrong; the app does not turn thinking on, it only gates on the model. |

How the app knows what a model supports: Ollama reports all three per model; LM Studio and llama.cpp report vision; and a run teaches it (a rejected image or tool request, a tool call that came back). A model whose server reports nothing is allowed to run, with a note in the transcript. Unknown names in `requires` are ignored with a warning on import. Export always writes the full effective set, `tools` included.

```json
"requires": ["tools", "vision"]
```

## `mcpServers`

The same shape Claude Desktop, Cursor, VS Code and Claude Code use. The key is the server's name; its **slug** is what the task references.

Slug rule: lowercase the name; keep ASCII letters, digits and `-`; every other run of characters becomes a single `_`; trim `_` and `-` from both ends. `"Brave Search"` → `brave_search`, `"fetch"` → `fetch`. A definition may carry its own `"name"`, which then replaces the key for both display and slug. Do not use `shell`, `bash` or `context` as a slug; they belong to the built-in packs.

stdio (a local process):

```json
"fetch": {
  "type": "stdio",
  "command": "uvx",
  "args": ["mcp-server-fetch"],
  "env": { "SOME_FLAG": "1" }
}
```

- `command` required. Resolved through the user's login-shell PATH, so `npx`, `uvx`, `node`, `python3` work if installed.
- `args`: array of strings (preferred) or one shell-style string.
- `env`: object of string values. Optional. Leave secrets out.

http (streamable HTTP or SSE endpoint):

```json
"docs": {
  "type": "http",
  "url": "https://mcp.example.com/mcp",
  "headers": { "Authorization": "Bearer REPLACE_ME" }
}
```

- `url` required. `type` may also be `"streamable-http"` or `"sse"`.
- `headers`: object of string values. Optional.
- Without `type`, a definition with `command` is stdio and one with only `url` is http.

Import behaviour: a server whose slug already exists in the app is reused as configured there and the file's definition is ignored. Otherwise the definition is added to Settings › Tools with a fresh ID. Definitions that no `tools[]` entry references are ignored.

## How the app exports

File › Export Task… writes exactly this format, with `env` and `headers` omitted unless the user ticks "Include environment variables and HTTP headers", and `requires` filled in with everything the task needs (`tools` included when any tool is attached). Round-tripping a file through export/import is lossless apart from those secrets and the per-machine fields listed above.

## Checklist before handing a file over

1. `format`, `version`, `task.userPrompt` present.
2. Every `{{placeholder}}` has a variable; every variable is used.
3. Every `tools[].server` has a matching `mcpServers` slug (or the user confirmed it exists in their app).
4. Every tool name mentioned in the prompts is attached (`shell__run` needs the `shell` entry).
5. `ask_user` mentioned only when `allowsSteering` is `true`.
6. `requires` lists `vision` when the job depends on images a tool returns, and `thinking` when only a reasoning model will do; otherwise leave it out.
7. No secrets in `env` or `headers`.
8. `python3 scripts/validate_task.py <file>` exits 0.
