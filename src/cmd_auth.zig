const std = @import("std");
const App = @import("app.zig").App;
const cli = @import("cli.zig");
const util = @import("util.zig");
const config = @import("config.zig");
const git_mod = @import("git.zig");
const api_mod = @import("api.zig");

pub fn run(app: *App, args: *cli.ArgList) !void {
    const sub = args.takePositional() orelse {
        cli.help("auth");
        return;
    };
    if (util.eql(sub, "login")) {
        try login(app, args);
    } else if (util.eql(sub, "logout")) {
        const host = args.expectPositional("HOST");
        args.rejectUnknownFlags();
        if (app.keys.hosts.swapRemove(host)) {
            try app.keys.save(app);
            std.debug.print("signed out of {s}\n", .{host});
        } else {
            std.debug.print("already not signed in to {s}\n", .{host});
        }
    } else if (util.eql(sub, "add-token") or util.eql(sub, "add-key")) {
        try addToken(app, args);
    } else if (util.eql(sub, "use-ssh")) {
        try useSsh(app, args);
    } else if (util.eql(sub, "list")) {
        args.rejectUnknownFlags();
        if (app.keys.hosts.count() == 0) {
            std.debug.print("No logins.\n", .{});
            return;
        }
        var it = app.keys.hosts.iterator();
        while (it.next()) |kv| std.debug.print("{s}\n", .{kv.key_ptr.*});
    } else {
        util.fatal("unknown auth command: {s}", .{sub});
    }
}

fn addToken(app: *App, args: *cli.ArgList) !void {
    const info = try git_mod.getCurrent(app, app.host_flag, null, null);
    var token = args.takePositional();
    args.rejectUnknownFlags();
    if (token == null) {
        token = try util.promptLine(app, "new key: ");
    }
    const t = util.trim(token.?);
    if (t.len == 0) util.fatal("empty token", .{});
    const host = git_mod.hostName(info.url);
    if (app.keys.hosts.contains(host)) {
        util.fatal("key for {s} already exists", .{host});
    }
    try app.keys.hosts.put(app.arena, try app.arena.dupe(u8, host), .{
        .kind = .Application,
        .token = try app.arena.dupe(u8, t),
    });
    try app.keys.save(app);
}

fn useSsh(app: *App, args: *cli.ArgList) !void {
    const info = try git_mod.getCurrent(app, app.host_flag, null, null);
    const enable = if (args.takePositional()) |p|
        util.parseBool(p) orelse util.fatal("expected true/false", .{})
    else
        true;
    args.rejectUnknownFlags();
    const host = git_mod.hostName(info.url);
    if (!app.keys.hosts.contains(host)) {
        util.fatal("not logged in to {s}", .{host});
    }
    if (enable) {
        const gop = try app.keys.default_ssh.getOrPut(app.arena, host);
        if (gop.found_existing) {
            std.debug.print("already using SSH for {s} by default\n", .{host});
        } else {
            gop.key_ptr.* = try app.arena.dupe(u8, host);
            gop.value_ptr.* = {};
            try app.keys.save(app);
            std.debug.print("now will use SSH for {s} by default\n", .{host});
        }
    } else {
        if (app.keys.default_ssh.swapRemove(host)) {
            try app.keys.save(app);
            std.debug.print("will no longer use SSH for {s} by default\n", .{host});
        } else {
            std.debug.print("already not using SSH for {s} by default\n", .{host});
        }
    }
}

fn login(app: *App, args: *cli.ArgList) !void {
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, null, null);
    const host = git_mod.hostName(info.url);
    const client_id = try config.clientIdFor(app, host) orelse {
        std.debug.print(
            \\Your installation of fj doesn't support `login` for {s}
            \\
            \\Please visit https://{s}/user/settings/applications
            \\to create a token, and use it to log in with `fj auth add-token`
            \\
        , .{ host, host });
        return;
    };

    const state = try alphanumeric(app, 32);
    const code_verifier = try alphanumeric(app, 43);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(code_verifier, &hash, .{});
    var challenge_buf: [64]u8 = undefined;
    const challenge = std.base64.url_safe_no_pad.Encoder.encode(&challenge_buf, &hash);

    const auth_url = try std.fmt.allocPrint(
        app.arena,
        "{s}/login/oauth/authorize?client_id={s}&redirect_uri=http://127.0.0.1:26218/&response_type=code&code_challenge_method=S256&code_challenge={s}&state={s}",
        .{ info.url, client_id, challenge, state },
    );
    try util.openUrl(app, auth_url);

    const code = try waitForOAuthCode(app, state) orelse {
        std.debug.print("Login canceled\n", .{});
        return;
    };

    const body = try util.jsonStringify(app.arena, .{
        .client_id = client_id,
        .code_verifier = code_verifier,
        .code = code,
        .grant_type = "authorization_code",
        .redirect_uri = "http://127.0.0.1:26218/",
    });
    var api = api_mod.Api.init(app, info.url, null);
    const resp = try api.post("/oauth/access_token", .{}, body);
    const token = api.parse(api_mod.OAuthToken, resp);
    const expires = try rfc3339NowPlus(app, token.expires_in - 60);
    try app.keys.hosts.put(app.arena, try app.arena.dupe(u8, host), .{
        .kind = .OAuth,
        .token = try app.arena.dupe(u8, token.access_token),
        .refresh_token = try app.arena.dupe(u8, token.refresh_token),
        .expires_at = expires,
    });
    try app.keys.save(app);
    std.debug.print("logged in to {s}\n", .{host});
}

fn alphanumeric(app: *App, n: usize) ![]u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const out = try app.arena.alloc(u8, n);
    var buf: [64]u8 = undefined;
    app.io.random(buf[0..n]);
    for (out, 0..) |*c, i| c.* = alphabet[buf[i] % alphabet.len];
    return out;
}

fn rfc3339NowPlus(app: *App, extra_secs: i64) ![]u8 {
    const ts = std.Io.Clock.real.now(app.io);
    const secs: i64 = @intCast(@divTrunc(ts.toNanoseconds(), 1_000_000_000) + extra_secs);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    return std.fmt.allocPrint(app.arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        @backingInt(md.month),
        md.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

fn waitForOAuthCode(app: *App, expected_state: []const u8) !?[]const u8 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 26218);
    var server = std.Io.net.IpAddress.listen(&addr, app.io, .{ .reuse_address = true }) catch |err| {
        util.fatal("failed to listen on 127.0.0.1:26218: {t}", .{err});
    };
    defer server.deinit(app.io);

    var stream = server.accept(app.io) catch |err| {
        util.fatal("oauth accept failed: {t}", .{err});
    };
    defer stream.close(app.io);

    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(app.io, &rbuf);
    const head = reader.interface.takeDelimiterInclusive('\n') catch return null;
    // GET /?code=...&state=... HTTP/1.1
    const first = util.trim(head);
    var it = std.mem.tokenizeScalar(u8, first, ' ');
    _ = it.next(); // GET
    const path = it.next() orelse return null;

    var code: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    var err_desc: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| {
        var qit = std.mem.splitScalar(u8, path[q + 1 ..], '&');
        while (qit.next()) |pair| {
            const kv = util.splitOnce(pair, '=') orelse continue;
            if (util.eql(kv[0], "code")) code = kv[1];
            if (util.eql(kv[0], "state")) state = kv[1];
            if (util.eql(kv[0], "error_description")) err_desc = kv[1];
        }
    }

    const msg: []const u8 = if (err_desc != null)
        "Failed to authenticate."
    else if (code != null)
        "Authenticated! Close this tab and head back to your terminal."
    else
        "";
    const resp = try std.fmt.allocPrint(app.arena, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ msg.len, msg });
    var wbuf: [1024]u8 = undefined;
    var writer = stream.writer(app.io, &wbuf);
    writer.interface.writeAll(resp) catch {};
    writer.interface.flush() catch {};

    if (err_desc != null) util.fatal("Failed to authenticate: {s}", .{err_desc.?});
    const c = code orelse return null;
    const st = state orelse return null;
    if (!util.eql(st, expected_state)) util.fatal("returned with invalid state", .{});
    return c;
}
