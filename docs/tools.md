# Tools Reference

knot3bot includes 30+ built-in tools for various tasks.

## File Operations

### read_file

Read contents of a file.

```json
{
  "name": "read_file",
  "description": "Read the contents of a file",
  "parameters": {
    "path": "string (required)"
  }
}
```

**Example:**
```
read_file(path="/path/to/file.txt")
```

### write_file

Create or overwrite a file.

```json
{
  "name": "write_file",
  "description": "Write content to a file",
  "parameters": {
    "path": "string (required)",
    "content": "string (required)"
  }
}
```

**Example:**
```
write_file(path="/path/to/file.txt", content="Hello, World!")
```

### edit_file

Edit specific lines in a file.

```json
{
  "name": "edit_file",
  "description": "Edit specific lines in a file",
  "parameters": {
    "path": "string (required)",
    "old_text": "string (required)",
    "new_text": "string (required)"
  }
}
```

**Example:**
```
edit_file(path="/path/to/file.txt", old_text="old content", new_text="new content")
```

### list_dir

List directory contents.

```json
{
  "name": "list_dir",
  "description": "List directory contents with details",
  "parameters": {
    "path": "string (optional, default: '.')"
  }
}
```

### search_files

Search for text in files.

```json
{
  "name": "search_files",
  "description": "Search for text in files using grep",
  "parameters": {
    "pattern": "string (required)",
    "path": "string (optional, default: '.')"
  }
}
```

## Shell Operations

### shell

Execute shell commands.

```json
{
  "name": "shell",
  "description": "Execute a shell command",
  "parameters": {
    "command": "string (required)",
    "timeout": "number (optional, seconds)"
  }
}
```

**Example:**
```
shell(command="ls -la", timeout=30)
```

### process_list

List running processes.

```json
{
  "name": "process_list",
  "description": "List running processes"
}
```

### process_kill

Kill a process by PID.

```json
{
  "name": "process_kill",
  "description": "Kill a process by PID",
  "parameters": {
    "pid": "number (required)"
  }
}
```

## Git Operations

### git_status

Show git working tree status.

```json
{
  "name": "git_status",
  "description": "Show git status"
}
```

### git_log

Show recent commits.

```json
{
  "name": "git_log",
  "description": "Show git commit history",
  "parameters": {
    "n": "number (optional, default: 10)"
  }
}
```

### git_diff

Show changes between commits.

```json
{
  "name": "git_diff",
  "description": "Show git diff",
  "parameters": {
    "target": "string (optional, branch/commit)"
  }
}
```

### git_branch

List git branches.

```json
{
  "name": "git_branch",
  "description": "List git branches"
}
```

## Web Operations

### web_search

Search the web.

```json
{
  "name": "web_search",
  "description": "Search the web using DuckDuckGo",
  "parameters": {
    "query": "string (required)"
  }
}
```

**Example:**
```
web_search(query="Zig programming language latest news")
```

### web_fetch

Fetch web page content.

```json
{
  "name": "web_fetch",
  "description": "Fetch content from a URL",
  "parameters": {
    "url": "string (required)",
    "timeout": "number (optional, default: 30)"
  }
}
```

**Example:**
```
web_fetch(url="https://example.com")
```

## Code Execution

### code_execution

Execute code in various languages.

```json
{
  "name": "code_execution",
  "description": "Execute code and return output",
  "parameters": {
    "code": "string (required)",
    "language": "string (optional, e.g., 'python', 'javascript', 'bash')"
  }
}
```

### code_review

Review code for issues.

```json
{
  "name": "code_review",
  "description": "Review code for bugs, style issues",
  "parameters": {
    "path": "string (required)"
  }
}
```

## System Operations

### cron_list

List scheduled cron jobs.

```json
{
  "name": "cron_list",
  "description": "List scheduled cron jobs"
}
```

### cron_add

Schedule a new cron job.

```json
{
  "name": "cron_add",
  "description": "Add a new cron job",
  "parameters": {
    "name": "string (required)",
    "schedule": "string (required, cron format)",
    "command": "string (required)"
  }
}
```

**Example:**
```
cron_add(name="daily-backup", schedule="0 2 * * *", command="tar -czf backup.tar.gz /data")
```

### cron_remove

Remove a cron job.

```json
{
  "name": "cron_remove",
  "description": "Remove a cron job",
  "parameters": {
    "job_id": "string (required)"
  }
}
```

## Memory Operations

### memory_search

Search session memory.

```json
{
  "name": "memory_search",
  "description": "Search session memory",
  "parameters": {
    "query": "string (required)"
  }
}
```

### memory_save

Save information to memory.

```json
{
  "name": "memory_save",
  "description": "Save information to memory",
  "parameters": {
    "key": "string (required)",
    "value": "string (required)"
  }
}
```

### memory_recall

Recall information from memory.

```json
{
  "name": "memory_recall",
  "description": "Recall information from memory",
  "parameters": {
    "key": "string (required)"
  }
}
```

## MCP Tools

### mcp_list

List available MCP tools.

```json
{
  "name": "mcp_list",
  "description": "List available MCP tools"
}
```

### mcp_call

Call an MCP tool.

```json
{
  "name": "mcp_call",
  "description": "Call an MCP tool",
  "parameters": {
    "server": "string (required)",
    "tool": "string (required)",
    "params": "object (required)"
  }
}
```

## Utility Tools

### browser_open

Open URL in browser.

```json
{
  "name": "browser_open",
  "description": "Open URL in default browser",
  "parameters": {
    "url": "string (required)"
  }
}
```

### browser_screenshot

Take a screenshot.

```json
{
  "name": "browser_screenshot",
  "description": "Take a screenshot"
}
```

### approve

Request approval for an action.

```json
{
  "name": "approve",
  "description": "Request approval for an action",
  "parameters": {
    "action": "string (required)",
    "reason": "string (required)"
  }
}
```

### interrupt

Interrupt current operation.

```json
{
  "name": "interrupt",
  "description": "Interrupt current operation"
}
```

### clarify

Ask user for clarification.

```json
{
  "name": "clarify",
  "description": "Ask user for clarification",
  "parameters": {
    "question": "string (required)"
  }
}
```

### delegate

Delegate task to sub-agent.

```json
{
  "name": "delegate",
  "description": "Delegate task to sub-agent",
  "parameters": {
    "task": "string (required)",
    "mode": "string (optional)"
  }
}
```

## Environment Variables

### env_get

Get environment variable.

```json
{
  "name": "env_get",
  "description": "Get environment variable",
  "parameters": {
    "key": "string (required)"
  }
}
```

### env_set

Set environment variable.

```json
{
  "name": "env_set",
  "description": "Set environment variable",
  "parameters": {
    "key": "string (required)",
    "value": "string (required)"
  }
}
```

## Skills

knot3bot supports loading external skills:

```bash
# Skills are loaded from ~/.knot3bot/skills/ or ./skills/
knot3bot
```

See [Skills documentation](skills.md) for creating custom skills.
