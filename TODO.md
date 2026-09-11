
Add multiple local endpoint settings. Call it something else instead of localhost maybe just base don the OpenAI protocol that it is accepting. Also how do we namespace the model provider and the model names within it when we add it to a scheduled task to be used.

Is there a way to auto launch that provide even if it is closed
What if the provider and model name is not availble for the scheduled task. 


## Revisit before release: data persistence and migrations

No database; everything is JSON decoded with Codable. Files: tasks.json (tolerant decoder), mcp-servers.json (synthesized, strict), builtin-tools.json (tolerant), UserDefaults (tolerant, migrates old local.* keys), .json task definition files (format "AITaskDefinition", versioned, refuses newer). No schema version, backups or tests for the Application Support files.

Risks
- JSONFile.load swallows decode errors and returns nil, so the store starts empty and the next save overwrites the old file. Any decoding bug becomes permanent data loss.
- MCPServerConfig uses a synthesized decoder: adding a non-optional field (even with a default) makes old files fail to decode.
- Enums (TaskSchedule.Outcome, TaskVariable.Kind, MCPServerConfig.Transport, AppleOptions.Sampling) decode strictly: an old build reading a file with a new case throws, then wipes it (downgrade, or beta + release with the same bundle id).
- Old builds drop unknown fields when they re-save a file written by a newer build.

To do, in order
1. Non-destructive load failures: keep the unreadable file as <name>.unreadable-<date>, show an alert, never overwrite it.
2. Envelope each file with schemaVersion; accept today's bare arrays as version 1; if newer than the build understands, load nothing and never save.
3. Ordered per-file migration steps (raw JSON N -> N+1) run before decoding; tolerant decoders keep handling additive changes.
4. Tolerant decoder for MCPServerConfig, like AgentTask's.
5. Copy each file to a Backups folder once per app version before the first write after an upgrade.
6. Test target with one fixture per released schema; decode each.
7. Delete RebrandMigration (AppSettings.swift): it moves Application Support/OddJobs and copies the ArunThotta.OddJobs defaults domain for pre-rename installs.

Rules for future model changes: add fields only via decodeIfPresent with a default; keep legacy keys readable when renaming; never remove an enum case; give enum decoders an unknown fallback; bump schemaVersion only for structural changes.
