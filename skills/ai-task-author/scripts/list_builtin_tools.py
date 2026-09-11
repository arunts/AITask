#!/usr/bin/env python3
"""Read the built-in tool packs straight from the AITaskRunner Swift sources.

Usage:
  list_builtin_tools.py                 Markdown tables (same shape as references/builtin-tools.md)
  list_builtin_tools.py --json          Machine-readable list
  list_builtin_tools.py --check         Exit 1 if validate_task.py's tool table disagrees with the sources
  list_builtin_tools.py --source DIR    Folder holding ShellToolPack.swift

Without --source the script looks for ../../AITaskRunner/Services/Builtin relative to itself (the AITaskRunner repo).
When the sources are not available, fall back to references/builtin-tools.md.
"""

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_SOURCE = HERE.parent.parent.parent / "AITaskRunner" / "Services" / "Builtin"
PACKS = {"shell": "ShellToolPack.swift"}

TOOL_BLOCK = re.compile(
    r'BuiltinTool\(\s*name:\s*"(?P<name>[^"]+)",'
    r'\s*description:\s*"(?P<description>(?:[^"\\]|\\.)*)",\s*inputSchema:\s*(?P<schema>.*?)\n\s*\),?\n',
    re.S,
)
PROPERTY = re.compile(r'"(?P<name>\w+)":\s*\["type":\s*"(?P<type>\w+)",\s*"description":\s*"(?P<desc>(?:[^"\\]|\\.)*)"\]')
REQUIRED = re.compile(r'"required":\s*\[(?P<list>[^\]]*)\]')


def unescape(text):
    return text.replace('\\"', '"').replace("\\n", "\n")


def parse_pack(path):
    tools = []
    for match in TOOL_BLOCK.finditer(path.read_text(encoding="utf-8")):
        schema = match.group("schema")
        required_match = REQUIRED.search(schema)
        required = re.findall(r'"(\w+)"', required_match.group("list")) if required_match else []
        arguments = [
            {"name": p.group("name"), "type": p.group("type"), "description": unescape(p.group("desc")), "required": p.group("name") in required}
            for p in PROPERTY.finditer(schema)
        ]
        tools.append({
            "name": match.group("name"),
            "description": unescape(match.group("description")),
            "arguments": arguments,
        })
    return tools


def load(source):
    packs = {}
    for slug, filename in PACKS.items():
        path = source / filename
        if not path.is_file():
            sys.exit(f"Cannot find {path}. Pass --source DIR, or use references/builtin-tools.md instead.")
        tools = parse_pack(path)
        if not tools:
            sys.exit(f"No BuiltinTool definitions found in {path}; the parser may need updating.")
        packs[slug] = tools
    return packs


def markdown(packs):
    out = []
    for slug, tools in packs.items():
        out.append(f"## `{slug}` pack ({len(tools)} tool{'s' if len(tools) != 1 else ''})\n")
        out.append("| Tool | What it does | Arguments (`*` required) |")
        out.append("|---|---|---|")
        for tool in tools:
            args = ", ".join(f"`{a['name']}{'*' if a['required'] else ''}`" for a in tool["arguments"])
            out.append(f"| `{slug}__{tool['name']}` | {tool['description']} | {args} |")
        out.append("")
    return "\n".join(out)


def check(packs):
    sys.path.insert(0, str(HERE))
    import validate_task  # noqa: E402

    problems = []
    for slug in sorted(set(packs) | set(validate_task.BUILTIN_TOOLS)):
        source = {t["name"] for t in packs.get(slug, [])}
        table = set(validate_task.BUILTIN_TOOLS.get(slug, []))
        for name in sorted(source - table):
            problems.append(f"{slug}__{name}: in the sources but not in validate_task.py")
        for name in sorted(table - source):
            problems.append(f"{slug}__{name}: in validate_task.py but not in the sources")
    if problems:
        print("validate_task.py is out of date with the Swift sources:")
        for line in problems:
            print("  " + line)
        return 1
    print("validate_task.py matches the Swift sources.")
    return 0


def main(argv):
    source = DEFAULT_SOURCE
    mode = "markdown"
    args = list(argv[1:])
    while args:
        arg = args.pop(0)
        if arg == "--source":
            source = Path(args.pop(0)).expanduser().resolve()
        elif arg == "--json":
            mode = "json"
        elif arg == "--check":
            mode = "check"
        elif arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            sys.exit(f"Unknown argument {arg}")
    packs = load(source)
    if mode == "json":
        print(json.dumps(packs, indent=2))
    elif mode == "check":
        return check(packs)
    else:
        print(markdown(packs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
