#!/usr/bin/env python3
"""Builds the AITaskRunner website into docs/ (served by GitHub Pages).

    python3 site/build.py            # rebuild docs/
    python3 site/build.py --check    # validate the task catalog only

Sources: site/templates/*.html, site/static/*, site/tasks/*.json + catalog.json,
skills/ai-task-author/** (zipped and rendered). Standard library only.
"""

import hashlib
import html
import importlib.util
import json
import os
import re
import shutil
import string
import subprocess
import sys
import zipfile
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
OUT = ROOT / "docs"
SKILL_DIR = ROOT / "skills" / "ai-task-author"

# ---- Site configuration ------------------------------------------------------------------

def github_repo():
    """owner/name from the git remote, so nothing personal is hardcoded here. Placeholder until a remote exists."""
    try:
        url = subprocess.run(["git", "-C", str(ROOT), "remote", "get-url", "origin"], capture_output=True, text=True, check=True).stdout.strip()
        match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", url)
        if match:
            return match.group(1)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return "OWNER/AITaskRunner"


REPO = github_repo()
# The notarized disk image is hosted by the site itself: drop it into site/downloads/ under this
# name (scripts/release.sh prints the copy command) and it is served from docs/downloads/.
# When the file is absent, the Download buttons fall back to the GitHub releases page.
DMG_NAME = "AITaskRunner.dmg"
DOWNLOADS = SITE / "downloads"
CONFIG = {
    "repo_url": f"https://github.com/{REPO}",
    "download_url": f"https://github.com/{REPO}/releases/latest",
    "site_title": "AITaskRunner",
    "site_description": "A Mac app for defining and running bare-bones tasks on local models: the instructions and the inputs, nothing else, so small models on your Mac stay on track. Run them on demand or on a schedule.",
}


def app_version():
    """MARKETING_VERSION from the Xcode project, so the site never disagrees with the build."""
    text = (ROOT / "AITaskRunner.xcodeproj" / "project.pbxproj").read_text()
    match = re.search(r"MARKETING_VERSION = ([\d.]+);", text)
    return match.group(1) if match else "1.0"


# ---- Small helpers -----------------------------------------------------------------------

def h(text):
    return html.escape(str(text), quote=True)


def slugify(text):
    text = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return text or "section"


def read(path):
    return Path(path).read_text(encoding="utf-8")


def write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def human_size(n):
    return f"{n / 1024:.1f} KB" if n >= 1024 else f"{n} bytes"


_templates = {}


def template(name):
    if name not in _templates:
        _templates[name] = string.Template(read(SITE / "templates" / f"{name}.html"))
    return _templates[name]


_assets_version = None


def assets_version():
    """Short content hash of site.css + site.js, appended to their URLs so browsers never serve a stale copy."""
    global _assets_version
    if _assets_version is None:
        digest = hashlib.sha256()
        for name in ("site.css", "site.js"):
            digest.update((SITE / "static" / name).read_bytes())
        _assets_version = digest.hexdigest()[:10]
    return _assets_version


def render_page(out_path, body_template, mapping, *, title, description, root, active=None):
    """Fills a body template, wraps it in base.html, writes it."""
    base = dict(CONFIG)
    if (DOWNLOADS / DMG_NAME).is_file():
        base["download_url"] = f"{root}downloads/{DMG_NAME}"
    base.update({
        "root": root,
        "version": app_version(),
        "assets_v": assets_version(),
        "year": str(date.today().year),
        "title": title,
        "description": h(description),
    })
    for page in ("features", "tasks", "spec", "skill"):
        base[f"active_{page}"] = 'aria-current="page"' if page == active else ""
    values = dict(base)
    values.update(mapping)
    body = template(body_template).safe_substitute(values)
    page = template("base").safe_substitute(dict(base, body=body))
    write(out_path, page)


def toc_from(html_text):
    """<li> entries for every <h2 id=…> in the rendered HTML."""
    items = []
    for match in re.finditer(r'<h2 id="([^"]+)">(.*?)</h2>', html_text):
        text = re.sub(r"<[^>]+>", "", match.group(2))
        items.append(f'        <li><a href="#{match.group(1)}">{text}</a></li>')
    return "\n".join(items)


# ---- A small Markdown renderer for the skill's reference files ---------------------------

_INLINE_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_INLINE_BOLD = re.compile(r"\*\*(.+?)\*\*")
_INLINE_ITALIC = re.compile(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])")


def inline(text):
    """Escapes text and applies code spans, bold, italic and links."""
    parts = re.split(r"(`[^`]*`)", text)
    out = []
    for part in parts:
        if part.startswith("`") and part.endswith("`") and len(part) >= 2:
            out.append(f"<code>{h(part[1:-1])}</code>")
        else:
            escaped = h(part)
            escaped = _INLINE_LINK.sub(lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>', escaped)
            escaped = _INLINE_BOLD.sub(r"<strong>\1</strong>", escaped)
            escaped = _INLINE_ITALIC.sub(r"<em>\1</em>", escaped)
            out.append(escaped)
    return "".join(out)


_FENCE = re.compile(r"^(\s*)```(\w*)\s*$")
_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
_UL = re.compile(r"^(\s*)[-*+]\s+(.*)$")
_OL = re.compile(r"^(\s*)(\d+)[.)]\s+(.*)$")
_TABLE_SEP = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")


def split_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith("\\|"):
        line = line[:-1]
    cells = re.split(r"(?<!\\)\|", line)
    return [c.replace("\\|", "|").strip() for c in cells]


def md_to_html(text, heading_offset=0):
    """Renders the subset of Markdown the skill files use. Returns HTML; h1 is dropped (the page has its own)."""
    lines = text.splitlines()
    return "".join(render_blocks(lines, heading_offset))


def render_blocks(lines, heading_offset=0):
    out = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue

        fence = _FENCE.match(line)
        if fence:
            indent = len(fence.group(1))
            lang = fence.group(2)
            code = []
            i += 1
            while i < n and not _FENCE.match(lines[i]):
                code.append(lines[i][indent:] if lines[i][:indent].strip() == "" else lines[i])
                i += 1
            i += 1  # closing fence
            cls = f' class="language-{lang}"' if lang else ""
            out.append(f"<pre><code{cls}>{h(chr(10).join(code))}</code></pre>\n")
            continue

        heading = _HEADING.match(line)
        if heading:
            level = len(heading.group(1)) + heading_offset
            title = heading.group(2)
            i += 1
            if level <= 1:
                continue  # the page template supplies the title
            level = min(level, 4)
            plain = re.sub(r"`", "", title)
            out.append(f'<h{level} id="{slugify(plain)}">{inline(title)}</h{level}>\n')
            continue

        if line.lstrip().startswith("|") and i + 1 < n and _TABLE_SEP.match(lines[i + 1]):
            header = split_row(line)
            i += 2
            rows = []
            while i < n and lines[i].lstrip().startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            out.append('<div class="table-scroll"><table><thead><tr>')
            out.append("".join(f"<th>{inline(c)}</th>" for c in header))
            out.append("</tr></thead><tbody>")
            for row in rows:
                row = row + [""] * (len(header) - len(row))
                out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row[:len(header)]) + "</tr>")
            out.append("</tbody></table></div>\n")
            continue

        if line.startswith(">"):
            quote = []
            while i < n and lines[i].startswith(">"):
                quote.append(lines[i][1:].lstrip())
                i += 1
            out.append('<div class="callout">' + "".join(render_blocks(quote, heading_offset)) + "</div>\n")
            continue

        item = _UL.match(line) or _OL.match(line)
        if item and len(item.group(1)) == 0 or (item and i == 0):
            ordered = bool(_OL.match(line))
            marker = _OL if ordered else _UL
            items = []
            while i < n:
                m = marker.match(lines[i])
                if not m or len(m.group(1)) != len(item.group(1)):
                    break
                content_indent = len(lines[i]) - len(lines[i].lstrip()) + len(m.group(0)) - len(m.group(1)) - len(m.group(m.lastindex))
                body = [m.group(m.lastindex)]
                i += 1
                while i < n:
                    nxt = lines[i]
                    if not nxt.strip():
                        # blank line: part of the item only if an indented line follows
                        if i + 1 < n and lines[i + 1].startswith(" " * 2) and lines[i + 1].strip():
                            body.append("")
                            i += 1
                            continue
                        break
                    lead = len(nxt) - len(nxt.lstrip())
                    if lead >= 2:
                        body.append(nxt[min(lead, content_indent):])
                        i += 1
                    elif not (_UL.match(nxt) or _OL.match(nxt) or _HEADING.match(nxt) or _FENCE.match(nxt) or nxt.startswith("|")):
                        body.append(nxt)  # lazy continuation
                        i += 1
                    else:
                        break
                inner = "".join(render_blocks(body, heading_offset)).strip()
                if inner.startswith("<p>") and inner.count("<p>") == 1 and inner.endswith("</p>"):
                    inner = inner[3:-4]
                items.append(f"<li>{inner}</li>")
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>\n" + "\n".join(items) + f"\n</{tag}>\n")
            continue

        # paragraph
        para = []
        while i < n and lines[i].strip() and not (_HEADING.match(lines[i]) or _FENCE.match(lines[i]) or _UL.match(lines[i]) or _OL.match(lines[i]) or lines[i].lstrip().startswith("|") or lines[i].startswith(">")):
            para.append(lines[i].strip())
            i += 1
        if not para:  # a block starter we did not consume (e.g. an indented list at top level)
            para.append(lines[i].strip())
            i += 1
        out.append(f"<p>{inline(' '.join(para))}</p>\n")
    return out


def split_frontmatter(text):
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            meta = {}
            for line in text[3:end].strip().splitlines():
                if ":" in line:
                    key, value = line.split(":", 1)
                    meta[key.strip()] = value.strip()
            return meta, text[end + 4:].lstrip("\n")
    return {}, text


# ---- Tasks -------------------------------------------------------------------------------

def load_validator():
    spec = importlib.util.spec_from_file_location("validate_task", SKILL_DIR / "scripts" / "validate_task.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VARIABLE_PATTERN = re.compile(r"\{\{\s*([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*\}\}")
TOOL_PATTERN = re.compile(r"([A-Za-z0-9][A-Za-z0-9_-]*?)__([A-Za-z0-9][A-Za-z0-9_.-]*)")


def highlight_prompt(text, variable_keys, tool_slugs, steering):
    """Escapes a prompt and wraps {{variables}} and slug__tool names the way the app's editor does."""
    escaped = h(text)

    def var(m):
        key = m.group(1)
        if key in variable_keys:
            return f'<span class="var">{m.group(0)}</span>'
        return m.group(0)

    def tool(m):
        name = m.group(0).rstrip(".-")
        tail = m.group(0)[len(name):]
        if m.group(1).lower() in tool_slugs:
            return f'<span class="tool">{name}</span>{tail}'
        return m.group(0)

    escaped = VARIABLE_PATTERN.sub(var, escaped)
    escaped = TOOL_PATTERN.sub(tool, escaped)
    if steering:
        escaped = re.sub(r"\bask_user\b", '<span class="tool">ask_user</span>', escaped)
    return escaped


def build_tasks(check_only=False):
    validator = load_validator()
    catalog = json.loads(read(SITE / "tasks" / "catalog.json"))
    categories = catalog["categories"]
    tasks = []
    failed = False

    for entry in catalog["tasks"]:
        path = SITE / "tasks" / entry["file"]
        text = read(path)
        report = validator.Report()
        summary = validator.validate(text, report)
        label = path.name
        for warning in report.warnings:
            print(f"  warning {label}: {warning}")
        if report.errors or summary is None:
            failed = True
            for error in report.errors:
                print(f"  ERROR {label}: {error}")
            continue
        unknown_tags = [t for t in entry.get("tags", []) if t not in categories]
        if unknown_tags:
            failed = True
            print(f"  ERROR {label}: tags not in catalog.categories: {', '.join(unknown_tags)}")
            continue

        data = json.loads(text)
        task = data["task"]
        slug = path.stem
        attachments = summary["attachments"]
        servers = summary["servers"]
        mcp = [a for a in attachments if a["source"] != "built-in"]
        needs = "mcp" if mcp else "app"
        tasks.append({
            "slug": slug,
            "file": path.name,
            "name": summary["name"] or "Untitled Task",
            "description": entry["description"],
            "tags": entry.get("tags", []),
            "featured": bool(entry.get("featured")),
            "needs": needs,
            "interactive": summary["steering"],
            "variables": summary["variables"],
            "attachments": attachments,
            "servers": servers,
            "task": task,
            "data": data,
            "text": text,
            "size": len(text.encode("utf-8")),
            "search": " ".join([a["slug"] for a in attachments] + [v["key"] for v in summary["variables"]]),
        })

    if failed:
        sys.exit("Task catalog has errors; nothing was written.")
    print(f"  {len(tasks)} tasks validated")
    if check_only:
        return tasks, categories

    for task in tasks:
        write_task_page(task, categories)
    return tasks, categories


def chips_for(task, categories, link_root):
    chips = []
    for a in task["attachments"]:
        if a["source"] != "built-in":
            chips.append(f'<span class="chip tool">MCP · {h(a["slug"])}</span>')
    if task["interactive"]:
        chips.append('<span class="chip interactive">Interactive</span>')
    if task["variables"]:
        n = len(task["variables"])
        chips.append(f'<span class="chip var">{n} variable{"s" if n != 1 else ""}</span>')
    for tag in task["tags"]:
        chips.append(f'<a class="chip tag" href="{link_root}tasks/?tag={h(tag)}">{h(categories[tag])}</a>')
    return "".join(chips)


def task_card(task, categories, root):
    meta = []
    for a in task["attachments"]:
        if a["source"] != "built-in":
            meta.append(f'<span class="chip tool">MCP · {h(a["slug"])}</span>')
    if task["interactive"]:
        meta.append('<span class="chip interactive">Interactive</span>')
    for tag in task["tags"]:
        meta.append(f'<span class="chip tag">{h(categories[tag])}</span>')
    return (
        f'      <a class="card task-card" href="{root}tasks/{task["slug"]}/" data-slug="{task["slug"]}">\n'
        f'        <svg class="arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14m-6-6 6 6-6 6"/></svg>\n'
        f'        <h3>{h(task["name"])}</h3>\n'
        f'        <p class="desc">{h(task["description"])}</p>\n'
        f'        <div class="meta">{"".join(meta)}</div>\n'
        f'      </a>'
    )


def write_task_page(task, categories):
    root = "../../"
    t = task["task"]
    variable_keys = {v["key"] for v in task["variables"]}
    tool_slugs = {a["slug"] for a in task["attachments"]}
    steering = task["interactive"]

    system_prompt = t.get("systemPrompt", "").strip()
    if system_prompt:
        system_html = f'<div class="prompt">{highlight_prompt(system_prompt, variable_keys, tool_slugs, steering)}</div>'
        system_note = "Sent before the user prompt on every run"
    else:
        system_html = '<p class="muted">None. The model runs with the provider\'s default behaviour.</p>'
        system_note = ""
    user_html = f'<div class="prompt">{highlight_prompt(t["userPrompt"], variable_keys, tool_slugs, steering)}</div>'

    if task["variables"]:
        rows = []
        for v in task["variables"]:
            if v["kind"] == "list":
                default = ", ".join(v["default"].split(", ")) if v["default"] else "—"
                default = f"<em>list:</em> {h(default)}"
            else:
                default = f"<code>{h(v['default'])}</code>" if v["default"] else "—"
            rows.append(f'<tr><td><code class="var-key">{{{{{h(v["key"])}}}}}</code></td><td>{h(v["kind"])}</td><td>{default}</td><td>{h(v["description"])}</td></tr>')
        variables_section = (
            '      <h3>Variables</h3>\n'
            '      <p class="muted small">The app asks for these before each run. Defaults are pre-filled; the values you last used are remembered.</p>\n'
            '      <div class="table-scroll"><table><thead><tr><th>Placeholder</th><th>Type</th><th>Default</th><th>What to enter</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>"
        )
    else:
        variables_section = ""

    servers_section = ""
    mcp = [a for a in task["attachments"] if a["source"] != "built-in"]
    if mcp:
        items = []
        runtimes = {"uvx": 'started with <code>uvx</code>, so <a href="https://docs.astral.sh/uv/">uv</a> must be installed',
                    "npx": 'started with <code>npx</code>, so <a href="https://nodejs.org">Node.js</a> must be installed',
                    "node": 'needs <a href="https://nodejs.org">Node.js</a>', "docker": "needs Docker"}
        for a in mcp:
            server = task["servers"][a["slug"]]
            definition = task["data"].get("mcpServers", {}).get(a["slug"], {})
            command = server["summary"].split(" ")[0] if server["transport"] == "stdio" else ""
            note = f'<p class="muted small">This server is {runtimes[command]}.</p>' if command in runtimes else ""
            items.append(f"<h4>{h(server['name'])} <span class=\"muted\">(<code>{h(a['slug'])}</code>)</span></h4>\n{note}<pre><code>{h(json.dumps(definition, indent=2))}</code></pre>")
        servers_section = (
            '      <h3>MCP servers this task defines</h3>\n'
            '      <p class="muted small">Added to Settings › Tools on import, unless you already have a server with the same slug, in which case yours is used. Add any API keys there, not in the file.</p>\n'
            + "\n".join(items)
        )

    render_page(
        OUT / "tasks" / task["slug"] / "index.html",
        "task",
        {
            "name": h(task["name"]),
            "description": h(task["description"]),
            "chips": chips_for(task, categories, root),
            "system_prompt": system_html,
            "system_note": system_note,
            "user_prompt": user_html,
            "variables_section": variables_section,
            "servers_section": servers_section,
            "json": h(task["text"]),
            "file_name": task["file"],
            "file_size": human_size(task["size"]),
        },
        title=f"{task['name']} · AITaskRunner task",
        description=task["description"],
        root=root,
        active="tasks",
    )
    shutil.copyfile(SITE / "tasks" / task["file"], OUT / "tasks" / task["slug"] / task["file"])


def write_tasks_index(tasks, categories):
    root = "../"
    cards = "\n".join(task_card(t, categories, root) for t in tasks)
    used_tags = sorted({tag for t in tasks for tag in t["tags"]}, key=lambda k: categories[k])
    filters = "\n".join(
        f'        <button class="chip filter" data-kind="tag" data-value="{h(tag)}" aria-pressed="false">{h(categories[tag])}</button>'
        for tag in used_tags
    )
    data = [
        {k: t[k] for k in ("slug", "name", "description", "tags", "needs", "interactive", "search")}
        for t in tasks
    ]
    render_page(
        OUT / "tasks" / "index.html",
        "tasks",
        {
            "task_cards": cards,
            "tag_filters": filters,
            "task_count": str(len(tasks)),
            "task_noun": "task" if len(tasks) == 1 else "tasks",
            "task_json": json.dumps(data).replace("</", "<\\/"),
        },
        title="Task repository · AITaskRunner",
        description="Ready-made AITaskRunner tasks: download the JSON, import it, run it on your local model.",
        root=root,
        active="tasks",
    )


# ---- Skill -------------------------------------------------------------------------------

def zip_skill():
    out = OUT / "downloads" / "ai-task-author.zip"
    out.parent.mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in SKILL_DIR.rglob("*") if p.is_file() and "__pycache__" not in p.parts and p.name != ".DS_Store")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in files:
            info = zipfile.ZipInfo(str(Path("ai-task-author") / path.relative_to(SKILL_DIR)))
            info.date_time = (2026, 1, 1, 0, 0, 0)  # fixed, so rebuilding does not churn git
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o755 if path.suffix == ".py" else 0o644) << 16
            zf.writestr(info, path.read_bytes())
    return out.stat().st_size


def write_doc(out_dir, source, title, lede, root):
    meta, body = split_frontmatter(read(source))
    body_html = md_to_html(body)
    render_page(
        out_dir / "index.html",
        "doc",
        {
            "doc_title": h(title),
            "doc_lede": h(lede or meta.get("description", "")),
            "doc_html": body_html,
            "toc": toc_from(body_html),
            "doc_source": h(str(source.relative_to(ROOT))),
        },
        title=f"{title} · ai-task-author",
        description=lede or meta.get("description", title),
        root=root,
        active="skill",
    )


def build_skill():
    size = zip_skill()
    root = "../"
    render_page(
        OUT / "skill" / "index.html",
        "skill",
        {"skill_zip_size": human_size(size)},
        title="ai-task-author skill · AITaskRunner",
        description="A skill for Claude Code, Codex and other coding agents that writes and validates AITaskRunner task files.",
        root=root,
        active="skill",
    )
    docs = [
        ("instructions", SKILL_DIR / "SKILL.md", "SKILL.md", "The instructions a coding agent follows when it uses the skill."),
        ("task-format", SKILL_DIR / "references" / "task-format.md", "Task file format", "Every field of an AITaskDefinition file, as the skill's reference."),
        ("builtin-tools", SKILL_DIR / "references" / "builtin-tools.md", "Built-in tools", "The Shell tool, file recipes that small models follow, and ask_user."),
        ("mcp-servers", SKILL_DIR / "references" / "mcp-servers.md", "MCP servers", "When to reach for an external server, known servers with ready definitions, and how to find others."),
    ]
    for slug, source, title, lede in docs:
        write_doc(OUT / "skill" / slug, source, title, lede, "../../")


# ---- Spec and landing ----------------------------------------------------------------------

def build_spec():
    body = template("spec").safe_substitute({"toc": "", "root": "../", "version": app_version()})
    render_page(
        OUT / "spec" / "index.html",
        "spec",
        {"toc": toc_from(body)},
        title="AITaskDefinition specification · AITaskRunner",
        description="The complete reference for AITaskRunner task files: every field, import rules, and a checklist.",
        root="../",
        active="spec",
    )


def build_index(tasks, categories):
    featured = [t for t in tasks if t["featured"]][:4] or tasks[:4]
    render_page(
        OUT / "index.html",
        "index",
        {
            "featured_cards": "\n".join(task_card(t, categories, "./") for t in featured),
            "task_count": str(len(tasks)),
            "task_noun": "task" if len(tasks) == 1 else "tasks",
            "download_note": download_note(),
        },
        title="AITaskRunner · saved tasks for local models on your Mac",
        description=CONFIG["site_description"],
        root="./",
        active="features",
    )


def download_note():
    """File name, size and SHA-256 of the hosted disk image, or nothing when it is not hosted here."""
    dmg = DOWNLOADS / DMG_NAME
    if not dmg.is_file():
        return ""
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    size = f"{dmg.stat().st_size / 1_048_576:.1f} MB"
    return (f'<div class="download-note"><p>{h(DMG_NAME)} · {size}</p>'
            f'<p class="hash"><b>SHA-256</b> {digest}</p></div>')


def copy_downloads():
    """Release files kept under site/downloads/ (the disk image) are served from docs/downloads/."""
    dest = OUT / "downloads"
    dest.mkdir(parents=True, exist_ok=True)
    if DOWNLOADS.is_dir():
        for path in DOWNLOADS.iterdir():
            if path.is_file() and path.name != ".DS_Store":
                shutil.copyfile(path, dest / path.name)


def copy_static():
    dest = OUT / "assets"
    dest.mkdir(parents=True, exist_ok=True)
    for path in (SITE / "static").iterdir():
        if path.is_file() and path.name != ".DS_Store":
            shutil.copyfile(path, dest / path.name)
    write(OUT / ".nojekyll", "")


def main(argv):
    check_only = "--check" in argv
    print("Tasks")
    if check_only:
        build_tasks(check_only=True)
        return
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir()
    tasks, categories = build_tasks()
    write_tasks_index(tasks, categories)
    print("Skill")
    build_skill()
    print("Spec")
    build_spec()
    print("Landing")
    build_index(tasks, categories)
    copy_static()
    copy_downloads()
    pages = sum(1 for _ in OUT.rglob("index.html"))
    print(f"Wrote {pages} pages to {OUT.relative_to(ROOT)}/")


if __name__ == "__main__":
    main(sys.argv[1:])
