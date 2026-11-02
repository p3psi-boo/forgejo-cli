const std = @import("std");
const fluent = @import("fluent");
const style = @import("style.zig");
const config = @import("config.zig");
const git_mod = @import("git.zig");
const api_mod = @import("api.zig");
const loc_mod = @import("loc.zig");

pub const App = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    http: std.http.Client,
    keys: config.KeyInfo,
    git: git_mod.Git,
    render: style.Render,
    loc: loc_mod.Loc,
    host_flag: ?[]const u8 = null,

    pub fn apiFor(self: *App, host_url: []const u8) api_mod.Api {
        const host = git_mod.hostName(host_url);
        const token = self.keys.tokenFor(host);
        return api_mod.Api.init(self, host_url, token);
    }

    pub fn t(self: *App, id: []const u8, args: fluent.Args) []const u8 {
        return self.loc.format(self.arena, id, args);
    }

    pub fn say(self: *App, id: []const u8, args: fluent.Args) void {
        self.loc.print(self.arena, id, args);
    }

    pub fn die(self: *App, id: []const u8, args: fluent.Args) noreturn {
        self.loc.fatal(self.arena, id, args);
    }
};
