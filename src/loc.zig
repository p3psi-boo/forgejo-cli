const std = @import("std");
const fluent = @import("fluent");
const ftl = @import("ftl");
const style = @import("style.zig");

threadlocal var current_render: ?*const style.Render = null;

pub const Loc = struct {
    gpa: std.mem.Allocator,
    bundles: []fluent.Bundle,
    chosen: *fluent.Bundle,
    fallback: *fluent.Bundle,

    pub fn init(
        gpa: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        is_tty: bool,
    ) !Loc {
        _ = is_tty;
        var list: std.ArrayList(fluent.Bundle) = .empty;
        errdefer {
            for (list.items) |*bundle| bundle.deinit();
            list.deinit(gpa);
        }

        for (ftl.catalog) |entry| {
            const locale = fluent.Locale.parse(entry.tag) catch continue;
            var bundle: fluent.Bundle = try .init(gpa, locale);
            // CLI output: isolation marks show up as junk in terminals.
            bundle.use_isolating = false;
            bundle.addFunction("STYLE", styleFn) catch |err| {
                bundle.deinit();
                return err;
            };
            bundle.addFunction("IS_MINIMAL", isMinimalFn) catch |err| {
                bundle.deinit();
                return err;
            };
            bundle.addFunction("OPT", optFn) catch |err| {
                bundle.deinit();
                return err;
            };

            var errors: fluent.Errors = .empty;
            defer errors.deinit(gpa);
            bundle.addResource(entry.source, .{}, &errors) catch |err| {
                bundle.deinit();
                return err;
            };
            if (errors.items.len != 0) {
                if (std.mem.eql(u8, entry.tag, "en-US")) {
                    for (errors.items) |err| std.debug.print("ftl error ({s}): {f}\n", .{ entry.tag, err });
                    bundle.deinit();
                    return error.InvalidFtl;
                }
                bundle.deinit();
                continue;
            }
            list.append(gpa, bundle) catch |err| {
                bundle.deinit();
                return err;
            };
        }
        if (list.items.len == 0) return error.InvalidFtl;

        const bundles = try list.toOwnedSlice(gpa);
        errdefer {
            for (bundles) |*bundle| bundle.deinit();
            gpa.free(bundles);
        }

        var requested_buf: [8]fluent.Locale = undefined;
        const wanted = fluent.system.preferredLocales(&requested_buf, environ);
        const chosen = negotiate(bundles, wanted);
        fluent.system.applyCategories(chosen, fluent.system.categories(environ));

        return .{
            .gpa = gpa,
            .bundles = bundles,
            .chosen = chosen,
            .fallback = &bundles[0],
        };
    }

    pub fn deinit(self: *Loc) void {
        for (self.bundles) |*bundle| bundle.deinit();
        self.gpa.free(self.bundles);
        self.* = undefined;
    }

    pub fn setRender(self: *const Loc, render: *const style.Render) void {
        _ = self;
        current_render = render;
    }

    pub fn format(self: *const Loc, allocator: std.mem.Allocator, id: []const u8, args: fluent.Args) []const u8 {
        if (self.chosen.format(allocator, id, args, null) catch null) |text| return text;
        if (self.chosen != self.fallback) {
            if (self.fallback.format(allocator, id, args, null) catch null) |text| return text;
        }
        return id;
    }

    pub fn print(self: *const Loc, allocator: std.mem.Allocator, id: []const u8, args: fluent.Args) void {
        const text = self.format(allocator, id, args);
        std.debug.print("{s}\n", .{text});
    }

    pub fn fatal(self: *const Loc, allocator: std.mem.Allocator, id: []const u8, args: fluent.Args) noreturn {
        self.print(allocator, id, args);
        std.process.exit(1);
    }
};

pub fn str(name: []const u8, value: []const u8) fluent.Argument {
    return .{ .name = name, .value = .{ .string = value } };
}

pub fn num(name: []const u8, value: anytype) fluent.Argument {
    return .{ .name = name, .value = .of(value) };
}

pub fn opt(name: []const u8, value: ?[]const u8) fluent.Argument {
    if (value) |v| {
        if (v.len != 0) return .{ .name = name, .value = .{ .string = v } };
    }
    return .{ .name = name, .value = .{ .none = name } };
}

pub fn flag(name: []const u8, value: bool) fluent.Argument {
    return .{ .name = name, .value = .{ .string = if (value) "yes" else "no" } };
}

fn negotiate(bundles: []fluent.Bundle, requested: []const fluent.Locale) *fluent.Bundle {
    for (requested) |want| {
        var pass: usize = 0;
        while (pass < 3) : (pass += 1) {
            for (bundles) |*bundle| {
                if (matches(&bundle.locale, &want, pass)) return bundle;
            }
        }
    }
    return &bundles[0];
}

fn matches(have: *const fluent.Locale, want: *const fluent.Locale, pass: usize) bool {
    if (!std.mem.eql(u8, have.language(), want.language())) return false;
    return switch (pass) {
        0 => have.eql(want),
        1 => scriptsAgree(have, want),
        else => true,
    };
}

fn scriptsAgree(a: *const fluent.Locale, b: *const fluent.Locale) bool {
    const left = a.script() orelse return true;
    const right = b.script() orelse return true;
    return std.mem.eql(u8, left, right);
}

fn styleFn(c: fluent.Call) fluent.Value {
    const render = current_render orelse return .{ .none = "STYLE" };
    var aw: std.Io.Writer.Allocating = .init(c.arena);
    for (c.positional) |value| {
        const name = switch (value) {
            .string => |s| s,
            else => continue,
        };
        aw.writer.writeAll(styleCode(render, name) orelse continue) catch return .{ .none = "STYLE" };
    }
    const text = aw.toOwnedSlice() catch return .{ .none = "STYLE" };
    return .{ .string = text };
}

fn isMinimalFn(c: fluent.Call) fluent.Value {
    _ = c;
    const render = current_render orelse return .{ .string = "no" };
    return .{ .string = if (render.is_fancy) "no" else "yes" };
}

fn optFn(c: fluent.Call) fluent.Value {
    return .{ .string = switch (c.first()) {
        .none => "none",
        else => "some",
    } };
}

fn styleCode(r: *const style.Render, name: []const u8) ?[]const u8 {
    if (eqlI(name, "red")) return r.red;
    if (eqlI(name, "bright-red")) return r.bright_red;
    if (eqlI(name, "green")) return r.green;
    if (eqlI(name, "bright-green")) return r.bright_green;
    if (eqlI(name, "blue")) return r.blue;
    if (eqlI(name, "bright-blue")) return r.bright_blue;
    if (eqlI(name, "cyan")) return r.cyan;
    if (eqlI(name, "bright-cyan")) return r.bright_cyan;
    if (eqlI(name, "yellow")) return r.yellow;
    if (eqlI(name, "bright-yellow")) return r.bright_yellow;
    if (eqlI(name, "magenta")) return r.magenta;
    if (eqlI(name, "bright-magenta")) return r.bright_magenta;
    if (eqlI(name, "black")) return r.black;
    if (eqlI(name, "dark-grey") or eqlI(name, "dark-gray")) return r.dark_grey;
    if (eqlI(name, "dark-grey-bg") or eqlI(name, "dark-gray-bg")) return r.dark_grey_bg;
    if (eqlI(name, "light-grey") or eqlI(name, "light-gray")) return r.light_grey;
    if (eqlI(name, "white")) return r.white;
    if (eqlI(name, "no_fg")) return r.no_fg;
    if (eqlI(name, "no_bg")) return r.no_bg;
    if (eqlI(name, "reset")) return r.reset;
    if (eqlI(name, "italic")) return r.italic;
    if (eqlI(name, "bold")) return r.bold;
    if (eqlI(name, "strike")) return r.strike;
    if (eqlI(name, "no-italic-bold")) return r.no_italic_bold;
    if (eqlI(name, "no-strike")) return r.no_strike;
    return null;
}

fn eqlI(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "en-US whoami formats" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("LANG", "en_US.UTF-8");
    try environ.put("LC_ALL", "en_US.UTF-8");

    var loc = try Loc.init(std.testing.allocator, &environ, false);
    defer loc.deinit();
    const render = style.Render.minimal();
    loc.setRender(&render);

    const text = loc.format(std.testing.allocator, "msg-whoami", &.{
        str("name", "alice"),
        str("host", "codeberg.org"),
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("currently signed into alice@codeberg.org", text);
}
