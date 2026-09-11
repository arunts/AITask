# ai-task-author

A Claude skill that turns "I want a task that…" into an AITaskDefinition `.json` file AITaskRunner can import. It interviews the person, writes the prompts, picks built-in or MCP tools, and validates the result with `scripts/validate_task.py`.

## Install

Copy or symlink this folder to a place Claude Code loads skills from:

```bash
# this project only
mkdir -p .claude/skills && ln -s "$PWD/skills/ai-task-author" .claude/skills/ai-task-author
# or every project
ln -s "$PWD/skills/ai-task-author" ~/.claude/skills/ai-task-author
```

Then ask, for example: "Make me an AITaskRunner task that summarises the PDFs in a folder each week."

## Validate a file by hand

```bash
python3 skills/ai-task-author/scripts/validate_task.py "My Task.json"
```

Exit code 0 means the app will import it; 1 lists the errors; warnings never block.

## Layout

- `SKILL.md` — the workflow Claude follows.
- `references/task-format.md` — every field of the file format.
- `references/builtin-tools.md` — the Shell tool, file recipes for it, and `ask_user`.
- `references/mcp-servers.md` — when and how to add an external MCP server; known servers with definitions; how to search for others.
- `assets/examples/` — four complete task files to start from.
- `scripts/validate_task.py` — stdlib-only checker mirroring the app's importer.
- `scripts/list_builtin_tools.py` — prints the live built-in tool list from the Swift sources (`--check` verifies the validator's tool table against them).
