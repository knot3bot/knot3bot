# Tools Reference

`createDefaultRegistry` registers 37 tools. The model only sees this list. Argument names come from each tool's own JSON schema; in the TUI, `/tools` prints the registered names.

`code_execution` is registered. Its execute path reports that the sandbox is not available in this build.

These tools exist in the tree and return `not_available`. They are not registered, so the model is not offered them:

`homeassistant`, `image_generation`, `send_message`, `tts`, `transcription`, `vision`, `screen_capture`

## Files and search

| Name | Role |
|------|------|
| `read_file` | Read a workspace file |
| `write_file` | Write a workspace file |
| `list_directory` | List a workspace directory |
| `grep` | Search file contents |
| `glob` | Match paths |
| `diff` | Text diff |

## Shell and processes

| Name | Role |
|------|------|
| `shell` | Run a command. The process is `/bin/sh -c` after a blocklist check |
| `spawn` | Start a background process |
| `interrupt` | Interrupt the current run |
| `env_passthrough` | Pass an allowlisted environment into a command |

## Git, web, and scheduling

| Name | Role |
|------|------|
| `git` | Git commands in the workspace |
| `cron` | Scheduled tasks |
| `http_request` | HTTP request |
| `web_fetch` | Fetch a URL |
| `web_search` | Web search |
| `web_extract` | Extract page text |
| `browser` | Browser action |
| `url_safety` | Check a URL against the blocklist |

## Planning and review

| Name | Role |
|------|------|
| `todo` | Task list |
| `task_planner` | Multi-step plan |
| `calculator` | Arithmetic |
| `clarify` | Ask a clarifying question |
| `approval` | Approval gate |
| `checkpoint` | Workspace checkpoint |
| `delegate` | Record a delegated task |
| `delegate_result` | Read a delegated task result |

## Memory and skills

| Name | Role |
|------|------|
| `memory` | Curated `MEMORY.md` / `USER.md` entries |
| `session_search` | Search session history |
| `skills_list` | List skills |
| `skill_view` | Read a skill |
| `skill_manager` | Create, update, or delete a skill |
| `skill_run` | Run a skill |
| `skill_self_improve` | Recorded-outcome suggestions. `generateSkillContent` returns an empty string |
| `credential_files` | Register credential file mounts |

## MCP

| Name | Role |
|------|------|
| `mcp` | Call a configured MCP tool |
| `mcp_list_servers` | List MCP servers |

## Harness and the tool list

With `--enable-harness-rsi`, an empty harness `tool_order` leaves this whole registry visible. A candidate may hide the first failing tool only when at least one other tool remains and the remaining list is at most 16 names. A longer remainder keeps the full registry.
