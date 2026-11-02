const std = @import("std");
const App = @import("app.zig").App;

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn startsWith(hay: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, hay, needle);
}

pub fn endsWith(hay: []const u8, needle: []const u8) bool {
    return std.mem.endsWith(u8, hay, needle);
}

pub fn stripPrefix(s: []const u8, prefix: []const u8) []const u8 {
    return if (startsWith(s, prefix)) s[prefix.len..] else s;
}

pub fn stripSuffix(s: []const u8, suffix: []const u8) []const u8 {
    return if (endsWith(s, suffix)) s[0 .. s.len - suffix.len] else s;
}

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn parseBool(s: []const u8) ?bool {
    if (eql(s, "true") or eql(s, "1") or eql(s, "yes") or eql(s, "on")) return true;
    if (eql(s, "false") or eql(s, "0") or eql(s, "no") or eql(s, "off")) return false;
    return null;
}

pub fn urlEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try out.append(allocator, c);
        } else {
            try out.print(allocator, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn pathJoin3(allocator: std.mem.Allocator, a: []const u8, b: []const u8, c: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ a, b, c });
}

pub fn readFile(app: *App, path: []const u8) ![]u8 {
    if (eql(path, "-")) {
        var buf: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().reader(app.io, &buf);
        return reader.interface.allocRemaining(app.arena, .unlimited) catch |err| switch (err) {
            error.ReadFailed => fatal("failed to read stdin", .{}),
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => fatal("stdin too large", .{}),
        };
    }
    var file = std.Io.Dir.cwd().openFile(app.io, path, .{}) catch |err| {
        fatal("Error reading file `{s}`: {t}", .{ path, err });
    };
    defer file.close(app.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(app.io, &buf);
    return reader.interface.allocRemaining(app.arena, .unlimited) catch |err| switch (err) {
        error.ReadFailed => fatal("Error reading file `{s}`", .{path}),
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => fatal("file `{s}` too large", .{path}),
    };
}

pub fn privateFilePerms() std.Io.File.Permissions {
    if (comptime @hasDecl(std.Io.File.Permissions, "fromMode")) {
        return .fromMode(0o600);
    }
    return .default_file;
}

pub fn writeFileMode(app: *App, path: []const u8, data: []const u8, mode: std.Io.File.Permissions) !void {
    var file = std.Io.Dir.cwd().createFile(app.io, path, .{
        .truncate = true,
        .permissions = mode,
    }) catch |err| {
        fatal("failed to write {s}: {t}", .{ path, err });
    };
    defer file.close(app.io);
    file.writeStreamingAll(app.io, data) catch |err| {
        fatal("failed to write {s}: {t}", .{ path, err });
    };
}

pub fn promptLine(app: *App, prompt_text: []const u8) ![]u8 {
    std.debug.print("{s}", .{prompt_text});
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(app.io, &buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return app.arena.dupe(u8, ""),
        error.StreamTooLong => fatal("input too long", .{}),
        error.ReadFailed => fatal("failed to read stdin", .{}),
    };
    return app.arena.dupe(u8, trim(line));
}

pub fn promptBool(app: *App, prompt_text: []const u8, default: bool) !bool {
    const suffix = if (default) " [y/N]: " else " [y/N]: ";
    _ = suffix;
    const def = if (default) "Y/n" else "y/N";
    const line = try promptLine(app, try std.fmt.allocPrint(app.arena, "{s} [{s}]: ", .{ prompt_text, def }));
    if (line.len == 0) return default;
    if (std.ascii.eqlIgnoreCase(line, "y") or std.ascii.eqlIgnoreCase(line, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(line, "n") or std.ascii.eqlIgnoreCase(line, "no")) return false;
    return default;
}

pub fn openUrl(app: *App, url: []const u8) !void {
    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };
    var child = std.process.spawn(app.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        fatal("failed to open browser: {t}", .{err});
    };
    _ = child.wait(app.io) catch {};
}

pub fn editor(app: *App, contents: *[]const u8, ext: ?[]const u8) !void {
    const editor_cmd = getEditor(app) orelse fatal("unable to locate editor (set $EDITOR or git core.editor)", .{});
    const tmp_dir = app.environ.get("TMPDIR") orelse app.environ.get("TMP") orelse "/tmp";
    var rand_buf: [16]u8 = undefined;
    app.io.random(&rand_buf);
    const name = try std.fmt.allocPrint(app.arena, "fj-{x}", .{std.mem.readInt(u128, &rand_buf, .little)});
    const path = if (ext) |e|
        try std.fs.path.join(app.arena, &.{ tmp_dir, try std.fmt.allocPrint(app.arena, "{s}.{s}", .{ name, e }) })
    else
        try std.fs.path.join(app.arena, &.{ tmp_dir, name });

    writeFileMode(app, path, contents.*, privateFilePerms()) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, editor_cmd, ' ');
    while (it.next()) |part| try argv.append(app.arena, part);
    if (argv.items.len == 1) {
        const stem = std.fs.path.stem(argv.items[0]);
        if (eql(stem, "code") or eql(stem, "code-oss") or eql(stem, "codium") or eql(stem, "zed") or eql(stem, "gram")) {
            try argv.append(app.arena, "--wait");
        }
    }
    try argv.append(app.arena, path);

    std.debug.print("waiting on editor\r", .{});
    var child = std.process.spawn(app.io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        fatal("failed to spawn editor: {t}", .{err});
    };
    const term = child.wait(app.io) catch |err| {
        fatal("editor wait failed: {t}", .{err});
    };
    if (!term.success()) fatal("editor exited unsuccessfully", .{});

    contents.* = readFile(app, path) catch "";
    std.debug.print("                 \r", .{});
    std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
}

fn getEditor(app: *App) ?[]const u8 {
    const git_editor = app.git.config("core.editor") catch null;
    if (git_editor) |e| {
        const t = trim(e);
        if (t.len > 0) return t;
    }
    if (app.environ.get("EDITOR")) |e| {
        const t = trim(e);
        if (t.len > 0) return t;
    }
    if (app.environ.get("VISUAL")) |e| {
        const t = trim(e);
        if (t.len > 0) return t;
    }
    return "vi";
}

pub fn jsonStringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{
        .emit_null_optional_fields = false,
    });
}

pub fn splitOnce(s: []const u8, sep: u8) ?struct { []const u8, []const u8 } {
    const i = std.mem.indexOfScalar(u8, s, sep) orelse return null;
    return .{ s[0..i], s[i + 1 ..] };
}

pub fn rsplitOnce(s: []const u8, sep: u8) ?struct { []const u8, []const u8 } {
    const i = std.mem.lastIndexOfScalar(u8, s, sep) orelse return null;
    return .{ s[0..i], s[i + 1 ..] };
}

pub fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

pub fn parseI64(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

pub fn joinComma(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    if (items.len == 0) return allocator.dupe(u8, "");
    var n: usize = 0;
    for (items) |it| n += it.len;
    n += items.len - 1;
    var out = try allocator.alloc(u8, n);
    var i: usize = 0;
    for (items, 0..) |it, idx| {
        @memcpy(out[i..][0..it.len], it);
        i += it.len;
        if (idx + 1 < items.len) {
            out[i] = ',';
            i += 1;
        }
    }
    return out;
}

test "urlEncode leaves unreserved characters" {
    const s = try urlEncode(std.testing.allocator, "abc-_.~");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("abc-_.~", s);
}

test "urlEncode encodes spaces" {
    const s = try urlEncode(std.testing.allocator, "a b");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("a%20b", s);
}

test "splitOnce and rsplitOnce" {
    const a = splitOnce("owner/name", '/') orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("owner", a[0]);
    try std.testing.expectEqualStrings("name", a[1]);
    const b = rsplitOnce("a/b/c", '/') orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a/b", b[0]);
    try std.testing.expectEqualStrings("c", b[1]);
}
