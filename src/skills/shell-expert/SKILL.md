---
name: shell-expert
description: Advanced shell command patterns, safe execution practices, and output parsing for system automation.
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Shell, Bash, CLI, Automation, System Administration]
    category: development
---

# Shell Expert

Execute shell commands safely and effectively.

## When to Use
- Complex shell operations: pipes, redirections, find+xargs, awk/sed
- Building automation scripts
- System administration tasks
- Package management and build tools

## Safety Rules
- Never use shell for simple file operations (use read_file, write_file, grep, glob)
- Always quote paths containing spaces
- Use find from `.` or a specific path, not `/`
- Validate user input before passing to shell commands
- Prefer git commands directly over nesting in shell
- Use git add <specific-files> over git add -A

## Common Patterns
- Find files: `find . -name "*.zig" -not -path "./.zig-cache/*"`
- Count lines: `find . -name "*.zig" | xargs wc -l | tail -1`
- Search: `grep -rn "pattern" src/ --include="*.zig"`
- Process list: `ps aux | grep process_name`
- Disk usage: `du -sh .zig-cache/`
