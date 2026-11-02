const std = @import("std");

pub const StyleKind = enum {
    fancy,
    minimal,

    pub fn parse(s: []const u8) ?StyleKind {
        if (std.mem.eql(u8, s, "fancy")) return .fancy;
        if (std.mem.eql(u8, s, "minimal")) return .minimal;
        return null;
    }
};

pub const Render = struct {
    is_fancy: bool,
    dash: []const u8,
    bullet: []const u8,
    body_prefix: []const u8,
    horiz_rule: []const u8,
    red: []const u8,
    bright_red: []const u8,
    green: []const u8,
    bright_green: []const u8,
    blue: []const u8,
    bright_blue: []const u8,
    cyan: []const u8,
    yellow: []const u8,
    magenta: []const u8,
    black: []const u8,
    dark_grey: []const u8,
    white: []const u8,
    no_fg: []const u8,
    reset: []const u8,
    dark_grey_bg: []const u8,
    bold: []const u8,
    italic: []const u8,

    pub fn init(kind: StyleKind, is_tty: bool) Render {
        if (!is_tty or kind == .minimal) return minimal();
        return fancy();
    }

    pub fn fancy() Render {
        return .{
            .is_fancy = true,
            .dash = "—",
            .bullet = "•",
            .body_prefix = "▌",
            .horiz_rule = "─",
            .red = "\x1b[31m",
            .bright_red = "\x1b[91m",
            .green = "\x1b[32m",
            .bright_green = "\x1b[92m",
            .blue = "\x1b[34m",
            .bright_blue = "\x1b[94m",
            .cyan = "\x1b[36m",
            .yellow = "\x1b[33m",
            .magenta = "\x1b[35m",
            .black = "\x1b[30m",
            .dark_grey = "\x1b[90m",
            .white = "\x1b[97m",
            .no_fg = "\x1b[39m",
            .reset = "\x1b[0m",
            .dark_grey_bg = "\x1b[100m",
            .bold = "\x1b[1m",
            .italic = "\x1b[3m",
        };
    }

    pub fn minimal() Render {
        return .{
            .is_fancy = false,
            .dash = "-",
            .bullet = "-",
            .body_prefix = ">",
            .horiz_rule = "-",
            .red = "",
            .bright_red = "",
            .green = "",
            .bright_green = "",
            .blue = "",
            .bright_blue = "",
            .cyan = "",
            .yellow = "",
            .magenta = "",
            .black = "",
            .dark_grey = "",
            .white = "",
            .no_fg = "",
            .reset = "",
            .dark_grey_bg = "",
            .bold = "",
            .italic = "",
        };
    }
};

pub fn markdown(r: Render, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        std.debug.print("{s}{s} {s}{s}\n", .{ r.dark_grey, r.body_prefix, r.reset, line });
    }
}

pub fn parseColor(color: []const u8) ?struct { u8, u8, u8 } {
    const hex = if (color.len == 7 and color[0] == '#') color[1..] else color;
    if (hex.len != 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    return .{ r, g, b };
}

pub fn luma(c: struct { u8, u8, u8 }) f32 {
    return ((0.299 * @as(f32, @floatFromInt(c[0]))) +
        (0.578 * @as(f32, @floatFromInt(c[1]))) +
        (0.114 * @as(f32, @floatFromInt(c[2])))) / 255.0;
}

pub fn renderLabel(r: Render, name: []const u8, color: []const u8, exclusive: bool) void {
    const rgb = parseColor(color) orelse .{ 255, 255, 255 };
    const text_color: []const u8 = if (luma(rgb) > 0.5) r.black else r.white;
    if (!r.is_fancy) {
        std.debug.print("{s}\n", .{name});
        return;
    }
    if (exclusive) {
        if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
            const category = name[0..slash];
            const rest = name[slash + 1 ..];
            const r2: u8 = @intFromFloat(@as(f32, @floatFromInt(rgb[0])) * 0.85);
            const g2: u8 = @intFromFloat(@as(f32, @floatFromInt(rgb[1])) * 0.85);
            const b2: u8 = @intFromFloat(@as(f32, @floatFromInt(rgb[2])) * 0.85);
            std.debug.print("\x1b[48;2;{d};{d};{d}m{s} {s} \x1b[48;2;{d};{d};{d}m {s} {s}", .{
                r2, g2, b2, text_color, category, rgb[0], rgb[1], rgb[2], rest, r.reset,
            });
            return;
        }
    }
    std.debug.print("\x1b[48;2;{d};{d};{d}m{s} {s} {s}", .{
        rgb[0], rgb[1], rgb[2], text_color, name, r.reset,
    });
}
