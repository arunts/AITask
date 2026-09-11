#!/usr/bin/env python3
"""Check an AITaskDefinition task file (.json) the way the app's importer does, then print a preview.

Usage: validate_task.py <file> [<file> ...]   (use - for stdin)

Exit codes: 0 = importable (warnings allowed), 1 = the app would refuse it, 2 = usage.
Standard library only. Mirrors AITaskRunner/Models/TaskBundle.swift, MCPServerImport.swift,
AgentTask.swift and BuiltinTools.swift; update the tables below when those change.
"""

import json
import re
import sys

FORMAT = "AITaskDefinition"
# Format names written by earlier versions; the app still imports them.
LEGACY_FORMATS = {"oddjobs-task"}
CURRENT_VERSION = 1

# pack slug -> tool names. Mirrors the BuiltinTool definitions in the Swift packs.
BUILTIN_TOOLS = {
    "shell": ["run"],
}
BUILTIN_LABELS = {"shell": "Shell"}
# Old pack names the app still accepts on import.
BUILTIN_ALIASES = {"bash": "shell"}
VARIABLE_KINDS = ("text", "file", "folder", "list")
# Most entries a list variable may hold (TaskVariable.maxOptions).
MAX_LIST_OPTIONS = 100
KNOWN_TOP = {"format", "version", "task", "mcpServers"}
KNOWN_TASK = {"name", "systemPrompt", "userPrompt", "allowsSteering", "variables", "tools"}
KNOWN_VARIABLE = {"key", "type", "default", "defaultValue", "description", "options"}
KNOWN_SERVER = {"name", "type", "command", "args", "env", "url", "headers"}
KNOWN_TOOL_ENTRY = {"builtin", "server", "tools"}

VARIABLE_PATTERN = re.compile(r"\{\{\s*([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*\}\}")
TOOL_REF_PATTERN = re.compile(r"([A-Za-z0-9][A-Za-z0-9_-]*?)__([A-Za-z0-9][A-Za-z0-9_.-]*)")


def slugify(name):
    """MCPServerConfig.slugify: lowercase, keep ASCII alphanumerics and '-', collapse the rest to '_'."""
    out = []
    for ch in name.lower():
        if ch.isascii() and (ch.isalnum() or ch == "-"):
            out.append(ch)
        elif not (out and out[-1] == "_"):
            out.append("_")
    slug = "".join(out).strip("_-")
    return slug or "server"


def sanitize_key(raw):
    """TaskVariable.sanitizeKey: letters, digits, '_', '.', '-'; whitespace -> '_'; rest dropped."""
    out = ""
    for ch in raw:
        if ch.isalpha() or ch.isnumeric() or ch in "_.-":
            out += ch
        elif ch.isspace() and not out.endswith("_"):
            out += "_"
    return "" if all(c == "_" for c in out) else out


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, text):
        self.errors.append(text)

    def warn(self, text):
        self.warnings.append(text)


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool) or (
        isinstance(value, float) and value.is_integer()
    )


def check_servers(definitions, report):
    """Return {slug: description} for every valid definition; errors mirror MCPServerImport."""
    servers = {}
    if definitions is None:
        return servers
    if not isinstance(definitions, dict):
        report.error('"mcpServers" must be an object keyed by server name.')
        return servers
    for key in sorted(definitions):
        definition = definitions[key]
        label = f'mcpServers["{key}"]'
        if not isinstance(definition, dict):
            report.error(f"{label}: expected an object.")
            continue
        for extra in sorted(set(definition) - KNOWN_SERVER):
            report.warn(f'{label}: key "{extra}" is ignored by the app.')
        name = definition.get("name", key)
        if not isinstance(name, str) or not name.strip():
            report.error(f'{label}: "name" must be a non-empty string when present.')
            continue
        slug = slugify(name)
        transport = definition.get("type")
        command = definition.get("command")
        url = definition.get("url")
        if transport is not None and not isinstance(transport, str):
            report.error(f'{label}: "type" must be a string.')
            continue
        kind = (transport or "").lower()
        if kind in ("http", "streamable-http", "streamablehttp", "streamable_http", "sse"):
            wants_http = True
        elif kind == "stdio":
            wants_http = False
        elif kind:
            report.warn(f'{label}: unknown "type" "{transport}"; the app decides by whether "command" or "url" is set.')
            wants_http = not (isinstance(command, str) and command.strip()) and isinstance(url, str) and bool(url.strip())
        else:
            wants_http = not (isinstance(command, str) and command.strip()) and isinstance(url, str) and bool(url.strip())

        if wants_http:
            if not isinstance(url, str) or not url.strip():
                report.error(f'{label}: HTTP servers need a "url".')
                continue
            headers = definition.get("headers")
            if headers is not None and not isinstance(headers, dict):
                report.error(f'{label}: "headers" must be an object of strings.')
                continue
            for header, value in (headers or {}).items():
                if looks_secret(header, value):
                    report.warn(f'{label}: header "{header}" looks like a credential; prefer leaving it out and setting it in Settings › Tools.')
            servers[slug] = {"name": name, "summary": url.strip(), "transport": "http"}
        else:
            if not isinstance(command, str) or not command.strip():
                report.error(f'{label}: stdio servers need a "command".')
                continue
            args = definition.get("args", [])
            if isinstance(args, list):
                if not all(isinstance(a, (str, int, float, bool)) for a in args):
                    report.error(f'{label}: "args" must be an array of strings.')
                    continue
                arg_text = " ".join(str(a) for a in args)
            elif isinstance(args, str):
                arg_text = args
            else:
                report.error(f'{label}: "args" must be an array of strings or one string.')
                continue
            env = definition.get("env")
            if env is not None and not isinstance(env, dict):
                report.error(f'{label}: "env" must be an object of strings.')
                continue
            for var, value in (env or {}).items():
                if looks_secret(var, value):
                    report.warn(f'{label}: env "{var}" looks like a credential; prefer leaving it out and setting it in Settings › Tools.')
            servers[slug] = {"name": name, "summary": (command.strip() + " " + arg_text).strip(), "transport": "stdio"}
        if slug != key:
            report.warn(f'{label}: its slug is "{slug}"; tools[].server must use that spelling.')
        if slug in BUILTIN_TOOLS:
            report.warn(f'{label}: slug "{slug}" collides with the built-in {BUILTIN_LABELS[slug]} pack; rename the server.')
    return servers


SECRET_WORDS = ("token", "secret", "key", "password", "authorization", "bearer")


def looks_secret(name, value):
    lowered = name.lower()
    if not any(word in lowered for word in SECRET_WORDS):
        return False
    text = str(value).strip().lower()
    return bool(text) and "replace" not in text and "your_" not in text and "<" not in text


def check_task(root, report):
    task = root.get("task")
    if not isinstance(task, dict):
        report.error('"task" must be an object.')
        return None
    for extra in sorted(set(task) - KNOWN_TASK):
        report.warn(f'task: key "{extra}" is ignored by the app.')

    name = task.get("name", "")
    if not isinstance(name, str):
        report.error('task.name must be a string.')
        name = ""
    elif not name.strip():
        report.warn('task.name is empty; the app will show "Untitled Task".')

    system_prompt = task.get("systemPrompt", "")
    if not isinstance(system_prompt, str):
        report.error("task.systemPrompt must be a string.")
        system_prompt = ""

    user_prompt = task.get("userPrompt", "")
    if not isinstance(user_prompt, str):
        report.error("task.userPrompt must be a string.")
        user_prompt = ""
    elif not user_prompt.strip():
        report.error("task.userPrompt is empty; the app refuses tasks without a user prompt.")

    steering = task.get("allowsSteering", False)
    if not isinstance(steering, bool):
        report.error("task.allowsSteering must be true or false.")
        steering = False

    variables = check_variables(task.get("variables", []), report)
    servers = check_servers(root.get("mcpServers"), report)
    attachments = check_tools(task.get("tools", []), servers, report)
    check_prompts(system_prompt + "\n" + user_prompt, variables, attachments, steering, report)

    return {
        "name": name.strip() or "Untitled Task",
        "steering": steering,
        "variables": variables,
        "attachments": attachments,
        "servers": servers,
    }


def check_variables(entries, report):
    variables = []
    if not isinstance(entries, list):
        report.error("task.variables must be an array.")
        return variables
    seen = set()
    for index, entry in enumerate(entries):
        label = f"variables[{index}]"
        if not isinstance(entry, dict):
            report.error(f"{label}: expected an object.")
            continue
        for extra in sorted(set(entry) - KNOWN_VARIABLE):
            report.warn(f'{label}: key "{extra}" is ignored by the app.')
        raw_key = entry.get("key")
        if not isinstance(raw_key, str):
            report.error(f'{label}: "key" must be a string.')
            continue
        key = sanitize_key(raw_key)
        if not key:
            report.warn(f'{label}: key "{raw_key}" sanitizes to nothing and will be dropped.')
            continue
        if key != raw_key:
            report.warn(f'{label}: key "{raw_key}" will be stored as "{key}"; reference it as {{{{{key}}}}}.')
        if key in seen:
            report.warn(f'{label}: duplicate key "{key}"; the app blocks saving the task until one is renamed.')
        seen.add(key)
        kind = entry.get("type", "text")
        if kind not in VARIABLE_KINDS:
            report.warn(f'{label}: type "{kind}" is unknown; it will be treated as text (use text, file, folder or list).')
            kind = "text"
        default = entry.get("default", entry.get("defaultValue", ""))
        if not isinstance(default, str):
            report.warn(f'{label}: "default" must be a string; a non-string default is ignored.')
            default = ""
        options = entry.get("options")
        if kind == "list":
            if not isinstance(options, list) or not all(isinstance(o, str) for o in options):
                report.warn(f'{label}: a list variable needs "options", an array of strings; without it the list starts empty.')
                options = []
            kept = []
            for option in options:
                option = option.strip()
                if option and option not in kept:
                    kept.append(option)
            if len(kept) > MAX_LIST_OPTIONS:
                report.warn(f'{label}: {len(kept)} options; the app keeps only the first {MAX_LIST_OPTIONS}.')
                kept = kept[:MAX_LIST_OPTIONS]
            if not kept:
                report.warn(f'{label}: the list has no values; the user has to add them when running.')
            if default:
                report.warn(f'{label}: "default" is ignored for list variables; the options are the value.')
            default = ", ".join(kept)
        elif options is not None:
            report.warn(f'{label}: "options" only applies to list variables and is ignored here.')
        description = entry.get("description", "")
        if not isinstance(description, str):
            report.warn(f'{label}: "description" must be a string; ignored.')
            description = ""
        elif not description.strip():
            report.warn(f'{label}: no description; add one line saying what the user should enter for {{{{{key}}}}}.')
        variables.append({"key": key, "kind": kind, "default": default, "description": description})
    return variables


def check_tools(entries, servers, report):
    """Return [{slug, label, tools (list or None), source}]; errors mirror TaskBundle.parse."""
    attachments = []
    if not isinstance(entries, list):
        report.error("task.tools must be an array.")
        return attachments
    for index, entry in enumerate(entries):
        label = f"tools[{index}]"
        if not isinstance(entry, dict):
            report.error(f"{label}: expected an object.")
            continue
        names = entry.get("tools")
        if names is not None:
            if not isinstance(names, list):
                report.error(f'{label}: "tools" must be an array of tool names or null.')
                continue
            dropped = [n for n in names if not isinstance(n, str)]
            if dropped:
                report.warn(f'{label}: non-string entries in "tools" are ignored.')
            names = [n for n in names if isinstance(n, str)]
            if not names:
                report.warn(f'{label}: "tools" is an empty list, so no tool from this source can be called. Use null for all tools.')
        for extra in sorted(set(entry) - KNOWN_TOOL_ENTRY):
            report.warn(f'{label}: key "{extra}" is ignored by the app.')
        builtin = entry.get("builtin")
        server = entry.get("server")
        if builtin is not None:
            if isinstance(builtin, str) and builtin in BUILTIN_ALIASES:
                report.warn(f'{label}: "{builtin}" is the old name of the {BUILTIN_LABELS[BUILTIN_ALIASES[builtin]]} pack; the app accepts it, but write "{BUILTIN_ALIASES[builtin]}" and use {BUILTIN_ALIASES[builtin]}__ names in the prompts.')
                builtin = BUILTIN_ALIASES[builtin]
            if not isinstance(builtin, str) or builtin not in BUILTIN_TOOLS:
                report.error(f'{label}: unknown built-in pack "{builtin}" (use "shell").')
                continue
            pack = BUILTIN_TOOLS[builtin]
            if names is not None:
                unknown = [n for n in names if n not in pack]
                if unknown:
                    report.error(f'{label}: built-in {BUILTIN_LABELS[builtin]} has no tool(s) {", ".join(unknown)}. Available: {", ".join(pack)}.')
                    continue
            attachments.append({"slug": builtin, "label": BUILTIN_LABELS[builtin], "tools": names, "source": "built-in"})
        elif server is not None:
            if not isinstance(server, str) or not server.strip():
                report.error(f'{label}: "server" must be a non-empty slug.')
                continue
            if server in servers:
                attachments.append({"slug": server, "label": servers[server]["name"], "tools": names, "source": "will be added on import (or reused if a server with slug \"%s\" already exists)" % server})
            else:
                hint = ""
                if servers:
                    hint = " Defined slugs: " + ", ".join(sorted(servers)) + "."
                report.error(f'{label}: server "{server}" is not defined under "mcpServers".{hint} (Import only succeeds if the user already has a server with that slug.)')
                continue
        else:
            report.error(f'{label}: needs either "builtin" or "server".')
            continue
    slugs = [a["slug"] for a in attachments]
    for slug in sorted(set(s for s in slugs if slugs.count(s) > 1)):
        report.warn(f'tools: "{slug}" is attached more than once; only the last entry counts.')
    return attachments


def check_prompts(text, variables, attachments, steering, report):
    declared = {v["key"] for v in variables}
    used = set(VARIABLE_PATTERN.findall(text))
    for key in sorted(used - declared):
        report.warn(f'{{{{{key}}}}} appears in a prompt but no variable declares it; the model receives it as literal text.')
    for key in sorted(declared - used):
        report.warn(f'variable "{key}" is declared but neither prompt uses {{{{{key}}}}}.')

    by_slug = {}
    for attachment in attachments:
        by_slug[attachment["slug"]] = attachment
    for prefix, tool in TOOL_REF_PATTERN.findall(text):
        tool = tool.rstrip(".-")  # sentence punctuation right after a name
        if prefix == "ask" and tool == "user":
            if not steering:
                report.warn('prompt mentions ask_user but allowsSteering is false; the model will not have that tool.')
            continue
        attachment = by_slug.get(prefix)
        if attachment is None:
            if prefix.lower() in by_slug:
                continue
            report.warn(f'prompt mentions {prefix}__{tool} but no attached tool source has slug "{prefix}".')
            continue
        allowed = attachment["tools"]
        if allowed is not None and tool not in allowed:
            report.warn(f'prompt mentions {prefix}__{tool} but tools[] for "{prefix}" only exposes: {", ".join(allowed)}.')
        elif attachment["source"] == "built-in" and tool not in BUILTIN_TOOLS[prefix]:
            report.warn(f'prompt mentions {prefix}__{tool}, which the built-in {attachment["label"]} pack does not have.')
    if steering and "ask_user" not in text:
        report.warn("allowsSteering is true but neither prompt tells the model when to use ask_user.")


def validate(text, report):
    try:
        root = json.loads(text)
    except json.JSONDecodeError as error:
        report.error(f"Not valid JSON: {error.msg} at line {error.lineno}, column {error.colno}.")
        return None
    if not isinstance(root, dict):
        report.error("The top level must be a JSON object.")
        return None
    for extra in sorted(set(root) - KNOWN_TOP):
        report.warn(f'top level: key "{extra}" is ignored by the app.')
    fmt = root.get("format")
    if fmt in LEGACY_FORMATS:
        report.warn(f'"format" "{fmt}" is the old name; the app still imports it, but write "{FORMAT}".')
    elif fmt != FORMAT:
        report.error(f'"format" must be "{FORMAT}".')
    version = root.get("version")
    if not is_int(version):
        report.error(f'"version" must be the integer {CURRENT_VERSION}.')
    elif not 1 <= int(version) <= CURRENT_VERSION:
        report.error(f'"version" {int(version)} is not supported; use {CURRENT_VERSION}.')
    if "task" not in root:
        report.error('Missing "task" object.')
        return None
    return check_task(root, report)


def traits(summary):
    parts = []
    if summary["attachments"]:
        count = sum(len(a["tools"]) for a in summary["attachments"] if a["tools"] is not None)
        open_ended = any(a["tools"] is None for a in summary["attachments"])
        parts.append("Tools" if open_ended or count == 0 else f"{count} tool{'s' if count != 1 else ''}")
    if summary["variables"]:
        n = len(summary["variables"])
        parts.append(f"{n} variable{'s' if n != 1 else ''}")
    if summary["steering"]:
        parts.append("Interactive")
    return " · ".join(parts) if parts else "Prompt only"


def print_summary(summary):
    print(f"  Name:       {summary['name']}")
    print(f"  Traits:     {traits(summary)}")
    if summary["variables"]:
        print("  Variables:")
        for v in summary["variables"]:
            default = f' default "{v["default"]}"' if v["default"] else " no default"
            desc = f" — {v['description']}" if v["description"] else ""
            print(f"    {{{{{v['key']}}}}} ({v['kind']},{default}){desc}")
    if summary["attachments"]:
        print("  Tools:")
        for a in summary["attachments"]:
            if a["source"] == "built-in":
                shown = ", ".join(BUILTIN_TOOLS[a["slug"]] if a["tools"] is None else a["tools"])
                which = f"all tools ({shown})" if a["tools"] is None else shown
                extra = ""
            else:
                which = "all tools" if a["tools"] is None else ", ".join(a["tools"])
                extra = f" · {summary['servers'][a['slug']]['summary']} · {a['source']}"
            print(f"    {a['label']} ({a['slug']}__…): {which}{extra}")
    else:
        print("  Tools:      none")


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 2
    exit_code = 0
    for path in argv[1:]:
        try:
            text = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
        except OSError as error:
            print(f"{path}: cannot read: {error}")
            exit_code = 1
            continue
        report = Report()
        summary = validate(text, report)
        if report.errors:
            exit_code = 1
            print(f"✗ {path}: the app would refuse this file")
            for line in report.errors:
                print(f"  error:   {line}")
        else:
            print(f"✓ {path}: importable (version {CURRENT_VERSION})")
        for line in report.warnings:
            print(f"  warning: {line}")
        if summary is not None and not report.errors:
            print_summary(summary)
        print()
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
