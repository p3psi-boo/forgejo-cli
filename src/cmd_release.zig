const std = @import("std");
const App = @import("app.zig").App;
const cli = @import("cli.zig");
const util = @import("util.zig");
const git_mod = @import("git.zig");
const api_mod = @import("api.zig");
const style = @import("style.zig");

pub fn run(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_flag = if (args.takeOpt("repo", 'r')) |s| git_mod.RepoName.parseArg(s) else null;
    const sub = args.takePositional() orelse util.fatal("usage: fj release <create|edit|delete|list|view|browse|asset>", .{});
    const info = try git_mod.getCurrent(app, app.host_flag, repo_flag, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);

    if (util.eql(sub, "create")) {
        const create_tag = args.takeOptMaybe("create-tag", 'T');
        const tag = args.takeOpt("tag", 't');
        const attach = try args.takeAll("attach", 'a');
        const body = args.takeOptMaybe("body", 'b');
        const branch = args.takeOpt("branch", 'B');
        const draft = args.takeFlag("draft", 'd');
        const prerelease = args.takeFlag("prerelease", 'p');
        const rname = args.expectPositional("NAME");
        var contents: []const u8 = "";
        if (body) |b| {
            contents = if (b.len == 0) "" else b;
            if (b.len == 0) try util.editor(app, &contents, "md");
        }
        const tag_name = tag orelse rname;
        const payload = try util.jsonStringify(app.arena, .{
            .name = rname,
            .tag_name = tag_name,
            .body = contents,
            .draft = draft,
            .prerelease = prerelease,
            .target_commitish = branch,
        });
        _ = create_tag;
        const rel = api.parse(api_mod.Release, try api.post("/repos/{s}/{s}/releases", .{ name.owner, name.name }, payload));
        std.debug.print("created {s}\n", .{rel.html_url orelse rname});
        const id = rel.id orelse return;
        for (attach) |path| try uploadAsset(app, &api, name, id, path, null);
    } else if (util.eql(sub, "edit")) {
        const rename = args.takeOpt("rename", 'n');
        const tag = args.takeOpt("tag", 't');
        const body = args.takeOptMaybe("body", 'b');
        const draft = args.takeBool("draft", 'd');
        const prerelease = args.takeBool("prerelease", 'p');
        const rname = args.expectPositional("NAME");
        const rel = try findRelease(&api, name, rname, false);
        var contents: ?[]const u8 = null;
        if (body) |b| {
            var c: []const u8 = if (b.len == 0) rel.body orelse "" else b;
            if (b.len == 0) try util.editor(app, &c, "md");
            contents = c;
        }
        const payload = try util.jsonStringify(app.arena, .{
            .name = rename,
            .tag_name = tag,
            .body = contents,
            .draft = draft,
            .prerelease = prerelease,
        });
        _ = try api.patch("/repos/{s}/{s}/releases/{d}", .{ name.owner, name.name, rel.id orelse 0 }, payload);
        std.debug.print("updated release {s}\n", .{rname});
    } else if (util.eql(sub, "delete")) {
        const by_tag = args.takeFlag("by-tag", 't');
        const rname = args.expectPositional("NAME");
        const rel = try findRelease(&api, name, rname, by_tag);
        try api.delete("/repos/{s}/{s}/releases/{d}", .{ name.owner, name.name, rel.id orelse 0 });
        std.debug.print("deleted release {s}\n", .{rname});
    } else if (util.eql(sub, "list")) {
        const include_pre = args.takeFlag("include-prerelease", 'p');
        const include_draft = args.takeFlag("include-draft", 'd');
        args.rejectUnknownFlags();
        const all = api.parse([]api_mod.Release, try api.get("/repos/{s}/{s}/releases", .{ name.owner, name.name }));
        for (all) |rel| {
            if ((rel.prerelease orelse false) and !include_pre) continue;
            if ((rel.draft orelse false) and !include_draft) continue;
            std.debug.print("{s} {s}\n", .{ rel.tag_name orelse "?", rel.name orelse "" });
        }
    } else if (util.eql(sub, "view")) {
        const by_tag = args.takeFlag("by-tag", 't');
        const rname = args.expectPositional("NAME");
        const rel = try findRelease(&api, name, rname, by_tag);
        std.debug.print("{s}{s}{s} ({s})\n", .{ app.render.bold, rel.name orelse "?", app.render.reset, rel.tag_name orelse "" });
        if (rel.body) |b| {
            if (b.len > 0) {
                std.debug.print("\n", .{});
                style.markdown(app.render, b);
            }
        }
        if (rel.assets) |assets| for (assets) |a| {
            std.debug.print("{s} {s} ({d} bytes)\n", .{ app.render.bullet, a.name orelse "?", a.size orelse 0 });
        };
    } else if (util.eql(sub, "browse")) {
        const rname = args.takePositional();
        args.rejectUnknownFlags();
        if (rname) |n| {
            const rel = try findRelease(&api, name, n, false);
            try util.openUrl(app, rel.html_url orelse util.fatal("no url", .{}));
        } else {
            try util.openUrl(app, try std.fmt.allocPrint(app.arena, "{s}/{s}/{s}/releases", .{ info.url, name.owner, name.name }));
        }
    } else if (util.eql(sub, "asset")) {
        const asub = args.expectPositional("ACTION");
        if (util.eql(asub, "create")) {
            const release = args.expectPositional("RELEASE");
            const path = args.expectPositional("PATH");
            const aname = args.takePositional();
            const rel = try findRelease(&api, name, release, false);
            try uploadAsset(app, &api, name, rel.id orelse 0, path, aname);
        } else if (util.eql(asub, "delete")) {
            const release = args.expectPositional("RELEASE");
            const asset = args.expectPositional("ASSET");
            const rel = try findRelease(&api, name, release, false);
            const id = try findAsset(rel, asset);
            try api.delete("/repos/{s}/{s}/releases/assets/{d}", .{ name.owner, name.name, id });
            std.debug.print("deleted asset {s}\n", .{asset});
        } else if (util.eql(asub, "download")) {
            const output = args.takeOpt("output", 'o');
            const release = args.expectPositional("RELEASE");
            const asset = args.expectPositional("ASSET");
            const rel = try findRelease(&api, name, release, false);
            var url: []const u8 = "";
            if (rel.assets) |assets| {
                for (assets) |a| {
                    if (a.name) |n| {
                        if (util.eql(n, asset) or (util.parseI64(asset) orelse -1) == (a.id orelse -2)) {
                            url = a.browser_download_url orelse util.fatal("asset has no url", .{});
                        }
                    }
                }
            }
            if (url.len == 0) util.fatal("asset not found", .{});
            try util.openUrl(app, url);
            _ = output;
        } else util.fatal("unknown asset command: {s}", .{asub});
    } else util.fatal("unknown release command: {s}", .{sub});
}

fn findRelease(api: *api_mod.Api, name: git_mod.RepoName, key: []const u8, by_tag: bool) !api_mod.Release {
    if (by_tag) {
        return api.parse(api_mod.Release, try api.get("/repos/{s}/{s}/releases/tags/{s}", .{ name.owner, name.name, key }));
    }
    if (util.parseI64(key)) |id| {
        return api.parse(api_mod.Release, try api.get("/repos/{s}/{s}/releases/{d}", .{ name.owner, name.name, id }));
    }
    const all = api.parse([]api_mod.Release, try api.get("/repos/{s}/{s}/releases", .{ name.owner, name.name }));
    for (all) |rel| {
        if (rel.name) |n| if (util.eql(n, key)) return rel;
        if (rel.tag_name) |n| if (util.eql(n, key)) return rel;
    }
    util.fatal("release not found: {s}", .{key});
}

fn findAsset(rel: api_mod.Release, key: []const u8) !i64 {
    if (rel.assets) |assets| for (assets) |a| {
        if (a.name) |n| if (util.eql(n, key)) return a.id orelse util.fatal("asset has no id", .{});
        if (util.parseI64(key)) |id| if (a.id == id) return id;
    };
    util.fatal("asset not found: {s}", .{key});
}

fn uploadAsset(app: *App, api: *api_mod.Api, name: git_mod.RepoName, release_id: i64, path: []const u8, aname: ?[]const u8) !void {
    const data = try util.readFile(app, path);
    const fname = aname orelse std.fs.path.basename(path);
    var qs = api_mod.query(app.arena);
    try qs.add("name", fname);
    _ = try api.postMultipart(
        "/repos/{s}/{s}/releases/{d}/assets",
        .{ name.owner, name.name, release_id },
        qs.slice(),
        "attachment",
        fname,
        data,
    );
    std.debug.print("attached {s}\n", .{fname});
}
