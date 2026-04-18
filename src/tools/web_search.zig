//! Web Tools - Search and Extract
//!
//! Provides web search and content extraction using multiple backends.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const getInt = root.getInt;
const shared = @import("../shared/root.zig");

pub const WebBackend = enum {
    firecrawl,
    tavily,
    exa,
    parallel,
    duckduckgo,
};

fn detectBackend() WebBackend {
    if (shared.context.getenv("FIRECRAWL_API_KEY") != null or shared.context.getenv("FIRECRAWL_API_URL") != null) {
        return .firecrawl;
    }
    if (shared.context.getenv("TAVILY_API_KEY") != null) {
        return .tavily;
    }
    if (shared.context.getenv("EXA_API_KEY") != null) {
        return .exa;
    }
    if (shared.context.getenv("PARALLEL_API_KEY") != null) {
        return .parallel;
    }
    return .duckduckgo;
}

pub const WebSearchTool = struct {
    pub const tool_name = "web_search";
    pub const tool_description = "Search the web for information using multiple backends (Firecrawl, Tavily, Exa, Parallel, or DuckDuckGo fallback). Returns list of URLs with titles and descriptions.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query string\"},\"backend\":{\"type\":\"string\",\"enum\":[\"firecrawl\",\"tavily\",\"exa\",\"parallel\",\"auto\"],\"description\":\"Backend to use (auto-detect by default)\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum number of results (default: 5)\"}},\"required\":[\"query\"]}";

    pub fn tool(self: *WebSearchTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *WebSearchTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const query = getString(args, "query") orelse return ToolResult.fail("query required");
        const limit = @as(u32, @intCast(@min(getInt(args, "limit") orelse 5, 20)));

        const backend_str = getString(args, "backend") orelse "auto";
        const backend: WebBackend = if (std.mem.eql(u8, backend_str, "auto"))
            detectBackend()
        else if (std.mem.eql(u8, backend_str, "firecrawl"))
            .firecrawl
        else if (std.mem.eql(u8, backend_str, "tavily"))
            .tavily
        else if (std.mem.eql(u8, backend_str, "exa"))
            .exa
        else if (std.mem.eql(u8, backend_str, "parallel"))
            .parallel
        else
            .duckduckgo;

        switch (backend) {
            .firecrawl => return searchFirecrawl(allocator, query, limit),
            .tavily => return searchTavily(allocator, query, limit),
            .exa => return searchExa(allocator, query, limit),
            .parallel => return searchParallel(allocator, query, limit),
            .duckduckgo => return searchDuckDuckGo(allocator, query, limit),
        }
    }

    fn searchFirecrawl(allocator: std.mem.Allocator, query: []const u8, limit: u32) !ToolResult {
        const api_key = shared.context.getenv("FIRECRAWL_API_KEY") orelse "";
        const api_url = shared.context.getenv("FIRECRAWL_API_URL") orelse "https://api.firecrawl.dev";

        const url = try std.fmt.allocPrint(allocator, "{s}/v0/search", .{api_url});
        defer allocator.free(url);

        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"query":"{s}","limit":{d}}}
        , .{ query, limit });
        defer allocator.free(json_body);

        return makeHttpRequest(allocator, "POST", url, api_key, json_body, "application/json");
    }

    fn searchTavily(allocator: std.mem.Allocator, query: []const u8, limit: u32) !ToolResult {
        const api_key = shared.context.getenv("TAVILY_API_KEY") orelse "";

        const url = "https://api.tavily.com/search";
        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"api_key":"{s}","query":"{s}","search_depth":"basic","max_results":{d}}}
        , .{ api_key, query, limit });

        return makeHttpRequest(allocator, "POST", url, "", json_body, "application/json");
    }

    fn searchExa(allocator: std.mem.Allocator, query: []const u8, limit: u32) !ToolResult {
        const api_key = shared.context.getenv("EXA_API_KEY") orelse "";

        const url = "https://api.exa.ai/search";
        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"api_key":"{s}","query":"{s}","numResults":{d}}}
        , .{ api_key, query, limit });

        return makeHttpRequest(allocator, "POST", url, "", json_body, "application/json");
    }

    fn searchParallel(allocator: std.mem.Allocator, query: []const u8, limit: u32) !ToolResult {
        const api_key = shared.context.getenv("PARALLEL_API_KEY") orelse "";

        const url = "https://api.parallel.ai/uko/v1/search";
        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"api_key":"{s}","query":"{s}","limit":{d}}}
        , .{ api_key, query, limit });

        return makeHttpRequest(allocator, "POST", url, "", json_body, "application/json");
    }

    fn searchDuckDuckGo(allocator: std.mem.Allocator, query: []const u8, limit: u32) !ToolResult {
        const encoded = try percentEncode(allocator, query);
        defer allocator.free(encoded);

        const url = try std.fmt.allocPrint(allocator, "https://html.duckduckgo.com/html/?q={s}", .{encoded});
        defer allocator.free(url);

        const argv = &[_][]const u8{
            "curl", "-s",           "-L", "--max-time", "15",
            "-A",   "knot3bot/1.0", url,
        };

        const result = std.process.run(allocator, shared.context.io(), .{
            .argv = argv,
        }) catch {
            return ToolResult.fail("Failed to execute search");
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        return parseSearchResults(allocator, result.stdout, limit);
    }

    fn parseSearchResults(allocator: std.mem.Allocator, html: []const u8, limit: u32) !ToolResult {
        var results: std.ArrayList(u8) = .empty;
        defer results.deinit(allocator);
        var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &results);

        try allocating.writer.writeAll("{\"results\":[");
        var count: u32 = 0;
        var pos: usize = 0;

        while (count < limit) {
            const link_start = std.mem.indexOf(u8, html[pos..], "<a href=\"") orelse break;
            const link_end = std.mem.indexOf(u8, html[pos + link_start + 9 ..], "\"") orelse break;
            const actual_pos = pos + link_start + 9;
            const href = html[actual_pos .. actual_pos + link_end];

            if (!std.mem.startsWith(u8, href, "http")) {
                pos = actual_pos + link_end;
                continue;
            }

            pos = actual_pos + link_end;
            const title_start = std.mem.indexOf(u8, html[pos..], ">") orelse break;
            const title_end = std.mem.indexOf(u8, html[pos + title_start + 1 ..], "</a>") orelse break;
            const actual_title_start = pos + title_start + 1;
            const title = html[actual_title_start .. actual_title_start + title_end];

            const clean_title = try stripHtmlTags(allocator, title);

            if (count > 0) try allocating.writer.writeAll(",");
            try allocating.writer.print(
                \\{{"url":"{s}","title":"{s}"}}
            , .{ href, clean_title });

            allocator.free(clean_title);
            count += 1;
            pos = actual_title_start + title_end + 4;
        }

        try allocating.writer.writeAll("]}");
        results = allocating.toArrayList();
        return ToolResult.ok(try results.toOwnedSlice(allocator));
    }

    fn percentEncode(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);
        var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &result);

        for (str) |c| {
            switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                    try allocating.writer.writeByte(c);
                },
                else => {
                    try allocating.writer.print("%{X}", .{@as(u8, c)});
                },
            }
        }

        result = allocating.toArrayList();
        return try result.toOwnedSlice(allocator);
    }

    fn stripHtmlTags(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < html.len) {
            if (html[i] == '<') {
                while (i < html.len and html[i] != '>') i += 1;
                i += 1;
            } else {
                try result.append(allocator, html[i]);
                i += 1;
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    pub const vtable = root.ToolVTable(@This());
};

pub const WebExtractTool = struct {
    pub const tool_name = "web_extract";
    pub const tool_description = "Extract content from specific URLs using multiple backends. Returns formatted content (markdown by default).";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"urls\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"List of URLs to extract from\"},\"backend\":{\"type\":\"string\",\"enum\":[\"firecrawl\",\"tavily\",\"exa\",\"parallel\",\"auto\"],\"description\":\"Backend to use (auto-detect by default)\"},\"format\":{\"type\":\"string\",\"enum\":[\"markdown\",\"text\",\"html\"],\"description\":\"Output format (default: markdown)\"}},\"required\":[\"urls\"]}";

    pub fn tool(self: *WebExtractTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *WebExtractTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const urls_val = args.get("urls") orelse return ToolResult.fail("urls required");
        const urls: []const std.json.Value = if (urls_val == .array) urls_val.array.items else return ToolResult.fail("urls must be an array");

        var urls_list: std.ArrayList([]const u8) = .empty;
        defer urls_list.deinit(allocator);

        for (urls) |url_val| {
            if (url_val == .string) {
                try urls_list.append(allocator, url_val.string);
            }
        }

        if (urls_list.items.len == 0) {
            return ToolResult.fail("No valid URLs provided");
        }

        const backend_str = getString(args, "backend") orelse "auto";
        const backend: WebBackend = if (std.mem.eql(u8, backend_str, "auto"))
            detectBackend()
        else if (std.mem.eql(u8, backend_str, "firecrawl"))
            .firecrawl
        else if (std.mem.eql(u8, backend_str, "tavily"))
            .tavily
        else if (std.mem.eql(u8, backend_str, "exa"))
            .exa
        else if (std.mem.eql(u8, backend_str, "parallel"))
            .parallel
        else
            .duckduckgo;

        switch (backend) {
            .firecrawl => return extractFirecrawl(allocator, urls_list.items),
            .tavily => return extractTavily(allocator, urls_list.items),
            .exa => return extractExa(allocator, urls_list.items),
            .parallel => return extractParallel(allocator, urls_list.items),
            .duckduckgo => return extractFallback(allocator, urls_list.items),
        }
    }

    fn extractFirecrawl(allocator: std.mem.Allocator, urls: []const []const u8) !ToolResult {
        const api_key = shared.context.getenv("FIRECRAWL_API_KEY") orelse "";
        const api_url = shared.context.getenv("FIRECRAWL_API_URL") orelse "https://api.firecrawl.dev";

        const url = try std.fmt.allocPrint(allocator, "{s}/v0/extract", .{api_url});
        defer allocator.free(url);

        var urls_json: std.ArrayList(u8) = .empty;
        defer urls_json.deinit(allocator);
        var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &urls_json);

        try allocating.writer.writeAll("[");
        for (urls, 0..) |u, i| {
            if (i > 0) try allocating.writer.writeAll(",");
            try allocating.writer.print("\\\"{s}\\\"", .{u});
        }
        try allocating.writer.writeAll("]");
        urls_json = allocating.toArrayList();

        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"urls":{s},"format":"markdown"}}
        , .{urls_json.items});
        defer allocator.free(json_body);

        return makeHttpRequest(allocator, "POST", url, api_key, json_body, "application/json");
    }

    fn extractTavily(allocator: std.mem.Allocator, urls: []const []const u8) !ToolResult {
        const api_key = shared.context.getenv("TAVILY_API_KEY") orelse "";

        var urls_json: std.ArrayList(u8) = .empty;
        defer urls_json.deinit(allocator);
        var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &urls_json);

        try allocating.writer.writeAll("[");
        for (urls, 0..) |u, i| {
            if (i > 0) try allocating.writer.writeAll(",");
            try allocating.writer.print("\\\"{s}\\\"", .{u});
        }
        try allocating.writer.writeAll("]");
        urls_json = allocating.toArrayList();

        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"api_key":"{s}","urls":{s}}}
        , .{ api_key, urls_json.items });

        return makeHttpRequest(allocator, "POST", "https://api.tavily.com/extract", "", json_body, "application/json");
    }

    fn extractExa(allocator: std.mem.Allocator, urls: []const []const u8) !ToolResult {
        const api_key = shared.context.getenv("EXA_API_KEY") orelse "";

        var urls_json: std.ArrayList(u8) = .empty;
        defer urls_json.deinit(allocator);
        var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &urls_json);

        for (urls, 0..) |u, i| {
            if (i > 0) try allocating.writer.writeAll(",");
            try allocating.writer.print("\\\"{s}\\\"", .{u});
        }
        urls_json = allocating.toArrayList();

        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"api_key":"{s}","urls":{s}}}
        , .{ api_key, urls_json.items });

        return makeHttpRequest(allocator, "POST", "https://api.exa.ai/extract", "", json_body, "application/json");
    }

    fn extractParallel(allocator: std.mem.Allocator, urls: []const []const u8) !ToolResult {
        const api_key = shared.context.getenv("PARALLEL_API_KEY") orelse "";

        var urls_json: std.ArrayList(u8) = .empty;
        defer urls_json.deinit(allocator);
        var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &urls_json);

        for (urls, 0..) |u, i| {
            if (i > 0) try allocating.writer.writeAll(",");
            try allocating.writer.print("\\\"{s}\\\"", .{u});
        }
        urls_json = allocating.toArrayList();

        const json_body = try std.fmt.allocPrint(allocator,
            \\{{"api_key":"{s}","urls":{s}}}
        , .{ api_key, urls_json.items });

        return makeHttpRequest(allocator, "POST", "https://api.parallel.ai/uko/v1/extract", "", json_body, "application/json");
    }

    fn extractFallback(allocator: std.mem.Allocator, urls: []const []const u8) !ToolResult {
        if (urls.len == 0) return ToolResult.fail("No URLs provided");

        const url = urls[0];
        const argv = &[_][]const u8{
            "curl", "-s",           "-L", "--max-time", "30",
            "-A",   "knot3bot/1.0", url,
        };

        const result = std.process.run(allocator, shared.context.io(), .{
            .argv = argv,
        }) catch {
            return ToolResult.fail("Failed to fetch URL");
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        return ToolResult.ok(try std.fmt.allocPrint(allocator,
            \\{{"url":"{s}","content":"{s}","extracted":true}}
        , .{ url, result.stdout }));
    }

    pub const vtable = root.ToolVTable(@This());
};

fn makeHttpRequest(allocator: std.mem.Allocator, method: []const u8, url: []const u8, api_key: []const u8, json_body: []const u8, content_type: []const u8) !ToolResult {
    var argv: [12][]const u8 = undefined;

    argv[0] = "curl";
    argv[1] = "-s";
    argv[2] = "-X";
    argv[3] = method;
    argv[4] = "-H";
    argv[5] = try std.fmt.allocPrint(allocator, "Content-Type: {s}", .{content_type});
    argv[6] = "-H";
    argv[7] = "Accept: application/json";
    argv[8] = "-d";
    argv[9] = json_body;

    var argc: usize = 10;

    if (api_key.len > 0) {
        argv[10] = "-H";
        argv[11] = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
        argc = 12;
    }

    argv[argc] = url;
    argc += 1;

    const result = std.process.run(allocator, shared.context.io(), .{
        .argv = argv[0..argc],
    }) catch {
        return ToolResult.fail("Failed to execute HTTP request");
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                return ToolResult.ok(result.stdout);
            } else {
                allocator.free(result.stdout);
                return ToolResult.fail(try std.fmt.allocPrint(allocator, "API request failed with code {d}: {s}", .{ code, result.stderr }));
            }
        },
        else => {
            allocator.free(result.stdout);
            return ToolResult.fail("API request failed");
        },
    }
}
