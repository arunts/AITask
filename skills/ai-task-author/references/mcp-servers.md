# External MCP servers

Use this when the built-in Shell pack cannot do the job (web, browser, an online service, a database). Work down the ladder and stop at the first rung that fits:

1. **Built-in shell** (`references/builtin-tools.md`). It covers more than people expect: `shell__run` can call `curl`, `gh`, `git`, `ffmpeg`, `sqlite3`, `osascript`.
2. **Servers the user already has** in Settings › Tools. Ask; reusing one means no new install and the task can reference it by its existing slug.
3. **Known servers** in the table below.
4. **Search** for one (procedure at the end).
5. **No fit**: say so plainly and offer the closest shell-based version instead of inventing a server.

## Before writing any server into a file

- **Runtime**: `npx -y <pkg>` needs Node.js, `uvx <pkg>` needs uv, `docker run` needs Docker. Say which one the user must have installed.
- **Verify it exists**. Package names churn. Run `npm view <pkg> version` or `uvx --from <pkg> <command> --help`, or open the repo README, before trusting a name from memory (including the table below).
- **Get the tool names right**. Take them from the README. If unsure, tell the user to add the server in Settings › Tools, then open the wizard's tool picker, which lists the live tools. Explicit `tools` lists beat `null` for small models; keep it to 3–8 tools.
- **Secrets stay out of the file**. Name the env variable or header the server needs and tell the user to add it in Settings › Tools after import. Use `REPLACE_ME` only where a key is structurally required.
- **Remote (HTTP) servers**: The app sends static headers only. A server that needs an OAuth login flow will not work; prefer its stdio package or a bearer token.
- **Small local models** pick tools badly beyond a dozen. A server that exposes 30 tools needs an explicit list and a prompt that names the one or two to call.

## Servers that return images

A server may answer with MCP `image` content (screenshots, rendered pages, charts). The app passes those images on: an OpenAI-compatible **vision** model (Qwen-VL, Gemma 3/4, LLaVA…) sees them as `image_url` parts in a follow-up user message after the tool result, whose text keeps a numbered placeholder such as `[image 1: image/png]`. A text-only endpoint model gets the placeholder and a note; the Apple on-device model never receives images. Only PNG, JPEG, WebP and GIF are forwarded, up to about 24 MB per result. When a task depends on the model looking at an image, put `"requires": ["vision"]` in the task so the app offers only vision models, and say in the prompt that the images follow the tool result.

## Known servers

Checked September 2026. Names drift; verify before use. Definitions are in the `mcpServers` shape.

| Job | Definition | Needs | Tools to name in the prompt |
|---|---|---|---|
| Fetch a web page as text | `"fetch": {"type": "stdio", "command": "uvx", "args": ["mcp-server-fetch"]}` | uv | `fetch__fetch` (args `url`, `max_length`, `start_index`, `raw`) |
| Git history and diffs | `"git": {"type": "stdio", "command": "uvx", "args": ["mcp-server-git", "--repository", "/path/to/repo"]}` | uv | `git__git_status`, `git__git_log`, `git__git_diff`, `git__git_diff_unstaged`, `git__git_show` (read-only set) |
| Current time, time zones | `"time": {"type": "stdio", "command": "uvx", "args": ["mcp-server-time"]}` | uv | `time__get_current_time`, `time__convert_time` |
| Persistent notes across runs (knowledge graph in a file) | `"memory": {"type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"]}` | Node; optional env `MEMORY_FILE_PATH` | `memory__create_entities`, `memory__add_observations`, `memory__search_nodes`, `memory__read_graph` |
| Drive a real browser | `"browser": {"type": "stdio", "command": "npx", "args": ["@playwright/mcp@latest"]}` | Node; opens a Chromium window | `browser__browser_navigate`, `browser__browser_snapshot`, `browser__browser_click`, `browser__browser_type`, `browser__browser_take_screenshot`, `browser__browser_close` (about 25 in total; list explicitly) |
| Web search | `"brave": {"type": "stdio", "command": "npx", "args": ["-y", "@brave/brave-search-mcp-server"]}` | Node; env `BRAVE_API_KEY` (free tier exists) | `brave__brave_web_search`, `brave__brave_local_search` |
| GitHub issues, PRs, code | `"github": {"type": "http", "url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization": "Bearer REPLACE_ME"}}` | Personal access token | `github__list_issues`, `github__get_issue`, `github__search_issues`, `github__get_pull_request`, `github__get_file_contents`, `github__search_code` (40+ available; list explicitly). `gh` via `shell__run` is often simpler. |
| Notion pages and databases | `"notion": {"type": "stdio", "command": "npx", "args": ["-y", "@notionhq/notion-mcp-server"]}` | Node; env `OPENAPI_MCP_HEADERS` = `{"Authorization": "Bearer REPLACE_ME", "Notion-Version": "2022-06-28"}` | Tool names mirror the Notion API (`notion__API-post-search`, `notion__API-retrieve-a-page`); confirm in the picker |
| Up-to-date library documentation | `"context7": {"type": "stdio", "command": "npx", "args": ["-y", "@upstash/context7-mcp"]}` | Node | `context7__resolve-library-id`, then `context7__get-library-docs` |
| Apple Notes, Reminders, Calendar, Mail, Messages, Contacts | `"apple": {"type": "stdio", "command": "npx", "args": ["-y", "apple-mcp"]}` | Node; macOS Automation permission prompts on first use; community project | `apple__notes`, `apple__reminders`, `apple__calendar`, `apple__mail`, `apple__messages`, `apple__contacts` |
| Query a SQLite file | `"sqlite": {"type": "stdio", "command": "uvx", "args": ["mcp-server-sqlite", "--db-path", "/path/to/file.db"]}` | uv; upstream archived but installable | `sqlite__list_tables`, `sqlite__describe_table`, `sqlite__read_query` (avoid `write_query` unless asked) |
| Structured file tools instead of shell commands (`read_file`, `edit_file`, `directory_tree`), confined to listed folders | `"filesystem": {"type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/allowed/dir"]}` | Node | Prefer `shell__run`; use this only for `filesystem__edit_file` or `filesystem__directory_tree` |

Slug reminder: the key becomes the slug (`brave` → `brave__brave_web_search`). Keep keys lowercase and short, since the model has to type them.

## Finding a server that is not listed

1. **Search**, in this order, with the web tools you have (WebSearch / WebFetch) or by asking the user to paste what they find:
   - Official registry: https://registry.modelcontextprotocol.io (API: `https://registry.modelcontextprotocol.io/v0/servers?search=<term>`)
   - Reference and vendor list: https://github.com/modelcontextprotocol/servers (README sections "Reference servers", "Official integrations", "Community")
   - Package indexes: `npm search mcp-server <term>`, PyPI `mcp-server-<term>`, GitHub search `"mcp server" <term>`
2. **Prefer** a server published by the service's own vendor, then the modelcontextprotocol reference set, then a community server with recent commits and a README that lists its tools. Prefer stdio over remote unless the remote server only needs a bearer token.
3. **Verify** the package installs (`npm view` / `uvx --help`) and copy the exact tool names from its README.
4. **Write** the definition in the same shape as the table, with an explicit `tools` list, and tell the user what to install and which secret to add in Settings › Tools.
5. **Nothing suitable**: say so. Offer the closest alternative through `shell__run` (a CLI such as `gh`, `curl` against the service's REST API, `osascript` for Apple apps) and note that each command will ask for approval.
