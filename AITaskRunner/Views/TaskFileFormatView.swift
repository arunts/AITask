import SwiftUI

/// Help › Task File Format: a plain-language reference for task definition files.
struct TaskFileFormatView: View {
    static let id = "task-file-format"

    var body: some View {
        ScrollView {
            MarkdownView(text: Self.reference)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle("Task File Format")
    }

    private static var builtinToolTables: String {
        BuiltinToolPack.allCases.map { pack in
            let slug = pack.config.slug
            var text = "### \(pack.name) (`\(slug)`)\n\n\(pack.description)\n\n"
            text += "| Tool | What it does |\n|---|---|\n"
            for tool in pack.definitions {
                text += "| `\(slug)__\(tool.name)` | \(tool.description) |\n"
            }
            return text
        }.joined(separator: "\n")
    }

    static var reference: String {
        #"""
        # Task files

        A task file is a small JSON text file (`.json`) that holds one task: its prompts, the values it asks you for, and the tools the model may use. Share one with a colleague, keep a library of them, or write one by hand.

        - **File › Export Task…** saves the selected task as a file.
        - **File › Import Task…** (⌘⇧I) reads one back in and shows you what it contains before adding it.

        The format is JSON. Every part is described below, with the exact spelling the app expects.

        ## A complete example

        ```json
        {
          "format": "AITaskDefinition",
          "version": 1,
          "task": {
            "name": "Summarise Notes Folder",
            "systemPrompt": "You are a concise technical writer. Reply in Markdown.",
            "userPrompt": "1. Run `ls {{notes_folder}}/*.md` with shell__run to find the notes.\n2. Read each file with `cat`.\n3. Write a Markdown summary to {{notes_folder}}/SUMMARY.md using `cat > file <<'EOF'`.",
            "allowsSteering": false,
            "requires": ["tools"],
            "variables": [
              { "key": "notes_folder", "type": "folder", "default": "~/Notes", "description": "Folder to summarise" },
              { "key": "topics", "type": "list", "options": ["weather", "sport"], "description": "Topics to cover" }
            ],
            "tools": [
              { "builtin": "shell" }
            ]
          },
          "mcpServers": {}
        }
        ```

        ## The outer wrapper

        | Field | What it is |
        |---|---|
        | `format` | Always `"AITaskDefinition"`. Tells the app this is a task file and not some other JSON. Files saved by earlier versions say `"oddjobs-task"` and still import. |
        | `version` | The file format version. Currently `1`. Only changes if the layout of the file itself changes. |
        | `task` | The task. See below. |
        | `mcpServers` | Definitions of any external MCP servers the task uses. Leave it as `{}` when the task only uses built-in tools. |

        ## The task

        | Field | Required | What it is |
        |---|---|---|
        | `name` | no | The name shown in the sidebar. Empty becomes "Untitled Task". |
        | `systemPrompt` | no | The model's standing brief: who it is, rules it must follow, how to answer. Sent before every run. |
        | `userPrompt` | **yes** | The job itself. Can mention variables as `{{key}}` and tools by name. |
        | `allowsSteering` | no | `true` makes the task interactive: the run window gets a chat box and the model gets an `ask_user` tool so it can ask you questions. Default `false`. |
        | `requires` | no | What the model must support, as a list of `"tools"`, `"vision"` and `"thinking"`. Tool calling is assumed whenever tools are attached or the task is interactive, so it need not be listed. See Model requirements. |
        | `variables` | no | Values you fill in before each run. See Variables. |
        | `tools` | no | What the model may call. See Tools. |

        Not in the file: which model runs the task, settings such as temperature, and any schedule. Those are choices about your Mac, so you set them in the app after importing.

        ## Variables

        A variable is a blank the task asks you to fill in each time it runs, such as a folder or a topic. In the prompts you refer to it as `{{key}}`, and the app swaps in your value before the model sees anything.

        | Field | What it is |
        |---|---|
        | `key` | The name used inside `{{ }}`. Letters, digits, `_`, `.` and `-` only; spaces are turned into `_`. |
        | `type` | `"text"` (the default), `"file"`, `"folder"` or `"list"`. File and folder variables get a Choose… button; a list variable holds several values at once. |
        | `options` | List variables only: the values, as an array of strings, at most 100. Blanks and repeats are dropped. In the prompt `{{key}}` becomes all of them separated by commas. Values added or removed while running are saved back to the task. |
        | `default` | Text, file and folder variables: the value pre-filled in the run sheet. You can change it every run, and the value you last used is remembered. Lists have no default; their `options` are the value. |
        | `description` | One line explaining what to enter. Shown under the field. |

        A `{{placeholder}}` with no matching variable is left in the prompt as-is, so keep the two in step.

        ## Tools

        Each entry in `tools` gives the model one source of tools. There are two kinds:

        ```json
        { "builtin": "shell" }
        { "server": "fetch", "tools": null }
        ```

        | Field | What it is |
        |---|---|
        | `builtin` | A pack that ships inside the app: `"shell"`, `"context"` or `"progress"`. Nothing to install. |
        | `server` | The short name (slug) of an MCP server defined under `mcpServers`, or one you already have in Settings › Tools. |
        | `tools` | The exact tools to allow, as a list. `null` or leaving it out means every tool the source offers, including ones added later. Fewer tools help small models choose well. |

        The model sees each tool as `source__tool`, for example `shell__run` or `fetch__fetch`. Using those exact names in the prompts is the most reliable way to get a small model to call the right one.

        ## Model requirements

        A task can say what the model must be able to do, so it is never run on one that cannot:

        | Name | Means |
        |---|---|
        | `tools` | The model can call tools. Assumed whenever `tools` is not empty or `allowsSteering` is `true`. |
        | `vision` | The model accepts images, so it sees the images tools return instead of a text placeholder. |
        | `thinking` | The model reasons before it answers. Only reasoning models are offered. |

        The app learns what each model supports from its server (Ollama reports all three; LM Studio and llama.cpp report vision) and from runs. A model known to lack a requirement is marked in the model picker and Run is turned off for it; a model whose server says nothing runs anyway, with a note in the transcript. A name in `requires` this version does not know is ignored with a warning when importing.

        ## Built-in tools

        \#(builtinToolTables)
        The shell is the built-in way to work with files: `ls`, `cat`, `find`, `grep`, `mv` and a heredoc to write a file all run through `shell__run`. Each command waits for your approval in the run window unless you turn that off in Settings › Tools, and commands start in the folder chosen there.

        ## MCP servers

        For anything the shell cannot do well, such as fetching web pages or talking to a service, the task can use an MCP server. Define it under `mcpServers` in the same shape Claude Desktop, Cursor and VS Code use. The key is the server's name; its slug (lowercase, with anything but letters, digits and `-` turned into `_`) is what `tools` refers to.

        A server started as a local program:

        ```json
        "fetch": { "type": "stdio", "command": "uvx", "args": ["mcp-server-fetch"] }
        ```

        A server reached over HTTP:

        ```json
        "docs": { "type": "http", "url": "https://mcp.example.com/mcp", "headers": { "Authorization": "Bearer REPLACE_ME" } }
        ```

        - `command` and `args` run a program; `env` can add environment variables.
        - `url` connects to a remote server; `headers` can add request headers.

        ### How tool results reach the model

        Text content is sent as the tool result (cut at about 60 000 characters). Images a server returns as MCP image content (PNG, JPEG, WebP, GIF) go to an OpenAI-compatible vision model as `image_url` parts in a follow-up user message right after the tool result, whose text keeps a placeholder such as `[image 1: image/png]`. A model without vision gets the placeholder and a note, and the run continues text-only. The Apple on-device model never receives images. Tool images show as thumbnails under the tool call in the run window.
        - Keep API keys out of shared files. Leave `env` and `headers` empty and add them in Settings › Tools after importing.
        - If you already have a server with the same slug, the app reuses yours and ignores the definition in the file.

        ## What happens when you import

        - You see a preview of the task first. Nothing is added until you click Import Task.
        - Servers the task defines and you do not have yet are added to Settings › Tools.
        - A warning appears in the preview when the Shell pack is turned off in Settings › Tools. The task still imports.
        - The app refuses a file with no user prompt, an unknown built-in tool, a server that is neither defined nor already configured, or a file `version` newer than this version of the app.

        ## Tips for writing one by hand

        - Start from an exported task and change it, rather than typing from scratch.
        - Keep JSON strict: double quotes, no trailing commas, no comments. Line breaks inside a prompt are written as `\n`.
        - One job per task, numbered steps, and the tool names spelled out. Small local models follow that far better than prose.
        """#
    }
}
