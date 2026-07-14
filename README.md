# Genki AI Tools Configuration Installers

The installers are organized into two independent directories:

- `claude/`: Claude Code installers, `settings.json`, and tests.
- `codex/`: Codex installers, `config.toml`, and tests.

## Merge behavior

- Claude target: `~/.claude/settings.json` or `$CLAUDE_CONFIG_DIR/settings.json`.
- Codex target: `~/.codex/config.toml` or `$CODEX_HOME/config.toml`.
- Keys that exist only in the user's local configuration are preserved.
- New keys from the repository are added.
- When a key exists in both files, the repository value overrides the local value.
- Keys listed in the deletion manifest are removed after the merge, so deletion takes precedence over addition or override.
- Objects and tables are merged recursively; arrays are replaced entirely by repository arrays.
- Existing files are backed up as `*.bak.YYYYMMDDHHMMSS` before they are updated.
- Files are parsed and serialized again, so key order, formatting, and existing TOML comments may change. Backups retain the original content.
- Codex string values are written as TOML basic strings with double quotes.
- If `model_providers.genki.experimental_bearer_token` is missing from the current Codex config, the installer securely prompts for it. Existing values are preserved.
- If `env.ANTHROPIC_AUTH_TOKEN` is missing from the current Claude settings, the installer securely prompts for it. Existing values are preserved.
- A Claude matcher block containing one command with the marker `GENKI_HOOK_ID=<id>;` is managed as a complete block. A matching ID replaces the complete existing block; a missing ID appends the complete block. Duplicate IDs cause the installer to fail without changing the existing settings.
- The managed `deny_nested_agent` hook uses Bash and the standard `grep` command on macOS/Linux/WSL. The PowerShell installer automatically converts it to a native PowerShell command on Windows. No additional hook runtime dependency is required.
- The installers download a pinned version of `fq` and verify its SHA-256 checksum before execution.

## Prepare the configuration

Edit the source configuration files:

- `claude/settings.json`: a valid Claude Code JSON object.
- `claude/delete.json`: Claude keys to remove after merging.
- `codex/config.toml`: a valid Codex TOML document.
- `codex/delete.toml`: Codex keys or tables to remove after merging.

After pushing changes to the `main` branch, the installers can be executed directly from GitHub Raw.

## Install Claude configuration

### macOS, Linux, WSL

```sh
curl -fsSL https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main/claude/config.sh | bash
```

### Windows PowerShell

```powershell
irm https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main/claude/config.ps1 | iex
```

### Windows CMD

```bat
curl -fsSL https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main/claude/config.cmd -o config.cmd && config.cmd && del config.cmd
```

## Install Codex configuration

### macOS, Linux, WSL

```sh
curl -fsSL https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main/codex/config.sh | bash
```

### Windows PowerShell

```powershell
irm https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main/codex/config.ps1 | iex
```

### Windows CMD

```bat
curl -fsSL https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main/codex/config.cmd -o config.cmd && config.cmd && del config.cmd
```

The two directories are fully independent and do not download a shared script from the repository root. When using a custom domain, host the required directory and preserve the source configuration path, or override it with an environment variable.

## Delete configuration keys

Claude deletions mirror the normal nested structure of `settings.json`. A key is deleted only when its merged value exactly matches:

```json
{
  "env": {
    "OLD_API_KEY": "old-value"
  },
  "permissions": {
    "oldSetting": false
  }
}
```

Use the same reserved string for unconditional Claude deletion:

```json
{
  "env": {
    "OLD_API_KEY": "__GENKI_DELETE_ANY__"
  }
}
```

Assign the reserved string directly to an object key to delete the entire object regardless of its contents:

```json
{
  "env": "__GENKI_DELETE_ANY__"
}
```

Codex deletions are declared by writing normal TOML keys or tables directly in `codex/delete.toml`. A key is deleted only when its merged value exactly matches the value in `delete.toml`:

```toml
[features.multi_agent_v2]
hide_spawn_agent_metadata = false
tool_namespace = "agents"
```

Deletion is applied after merging. Each key is evaluated independently. When all keys in `[features.multi_agent_v2]` match and are removed, the now-empty table and its empty parent tables are removed as well.

Use the reserved string `__GENKI_DELETE_ANY__` to delete a key regardless of its current value:

```toml
[features.multi_agent_v2]
hide_spawn_agent_metadata = "__GENKI_DELETE_ANY__"
tool_namespace = "__GENKI_DELETE_ANY__"
```

A top-level scalar key can be deleted using an exact expected value or the reserved string:

```toml
model = "__GENKI_DELETE_ANY__"
```

## Supported environment variables

| Variable | Purpose |
| --- | --- |
| `GENKI_CONFIG_BASE_URL` | Base URL containing the `claude/` and `codex/` directories |
| `GENKI_CLAUDE_SETTINGS_URL` | Override the URL of `settings.json` |
| `GENKI_CLAUDE_DELETE_URL` | Override the URL of `claude/delete.json` |
| `GENKI_CODEX_CONFIG_URL` | Override the URL of `config.toml` |
| `GENKI_CODEX_DELETE_URL` | Override the URL of `codex/delete.toml` |
| `GENKI_CONFIG_CLAUDE_PS1_URL` | CMD: override the URL of `claude/config.ps1` |
| `GENKI_CONFIG_CODEX_PS1_URL` | CMD: override the URL of `codex/config.ps1` |
| `CLAUDE_SETTINGS_PATH` | Override the complete Claude target file path |
| `CODEX_CONFIG_PATH` | Override the complete Codex target file path |
| `GENKI_FQ_PATH` | Use a local `fq` binary instead of downloading the pinned version |
| `GENKI_CODEX_EXPERIMENTAL_BEARER_TOKEN` | Provide the Genki bearer token for non-interactive Codex installation |
| `GENKI_CLAUDE_ANTHROPIC_AUTH_TOKEN` | Provide `ANTHROPIC_AUTH_TOKEN` for non-interactive Claude installation |

To test another branch or host on macOS/Linux, pass the variable to the `bash` process after the pipe:

```sh
curl -fsSL https://example.com/claude/config.sh | \
  GENKI_CONFIG_BASE_URL=https://example.com/ai-config bash
```
