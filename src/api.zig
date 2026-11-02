const std = @import("std");
const App = @import("app.zig").App;
const util = @import("util.zig");
const build_options = @import("build_options");

pub const user_agent = build_options.name ++ "/" ++ build_options.version ++ " (" ++ build_options.repository ++ ")";

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

pub const Api = struct {
    app: *App,
    base: []const u8, // https://host with no trailing slash
    token: ?[]const u8,

    pub fn init(app: *App, host_url: []const u8, token: ?[]const u8) Api {
        var base = util.stripSuffix(host_url, "/");
        if (std.mem.indexOf(u8, base, "://") == null) {
            base = std.fmt.allocPrint(app.arena, "https://{s}", .{base}) catch util.fatal("oom", .{});
        }
        return .{ .app = app, .base = util.stripSuffix(base, "/"), .token = token };
    }

    pub fn get(self: *Api, comptime path_fmt: []const u8, path_args: anytype) ![]const u8 {
        return self.call(.GET, path_fmt, path_args, "", null, null);
    }

    pub fn getQuery(self: *Api, comptime path_fmt: []const u8, path_args: anytype, qs: []const u8) ![]const u8 {
        return self.call(.GET, path_fmt, path_args, qs, null, null);
    }

    pub fn post(self: *Api, comptime path_fmt: []const u8, path_args: anytype, body: ?[]const u8) ![]const u8 {
        return self.call(.POST, path_fmt, path_args, "", body, if (body != null) "application/json" else null);
    }

    pub fn postMultipart(
        self: *Api,
        comptime path_fmt: []const u8,
        path_args: anytype,
        qs: []const u8,
        field: []const u8,
        filename: []const u8,
        data: []const u8,
    ) ![]const u8 {
        const boundary = "----fjUploadBoundary";
        var body: std.ArrayList(u8) = .empty;
        try body.print(self.app.arena, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{
            boundary, field, filename,
        });
        try body.appendSlice(self.app.arena, data);
        try body.print(self.app.arena, "\r\n--{s}--\r\n", .{boundary});
        const ctype = try std.fmt.allocPrint(self.app.arena, "multipart/form-data; boundary={s}", .{boundary});
        return self.call(.POST, path_fmt, path_args, qs, body.items, ctype);
    }

    pub fn patch(self: *Api, comptime path_fmt: []const u8, path_args: anytype, body: []const u8) ![]const u8 {
        return self.call(.PATCH, path_fmt, path_args, "", body, "application/json");
    }

    pub fn put(self: *Api, comptime path_fmt: []const u8, path_args: anytype, body: ?[]const u8) ![]const u8 {
        return self.call(.PUT, path_fmt, path_args, "", body, if (body != null) "application/json" else null);
    }

    pub fn delete(self: *Api, comptime path_fmt: []const u8, path_args: anytype) !void {
        _ = try self.call(.DELETE, path_fmt, path_args, "", null, null);
    }

    pub fn parse(self: *Api, comptime T: type, body: []const u8) T {
        if (body.len == 0) util.fatal("empty API response", .{});
        return std.json.parseFromSliceLeaky(T, self.app.arena, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| util.fatal("failed to parse API response: {t}", .{err});
    }

    fn call(
        self: *Api,
        method: std.http.Method,
        comptime path_fmt: []const u8,
        path_args: anytype,
        qs: []const u8,
        payload: ?[]const u8,
        content_type: ?[]const u8,
    ) ![]const u8 {
        const path = try std.fmt.allocPrint(self.app.arena, path_fmt, path_args);
        const url = try std.fmt.allocPrint(self.app.arena, "{s}/api/v1{s}{s}", .{ self.base, path, qs });

        var auth_buf: [512]u8 = undefined;
        var extra: [4]std.http.Header = undefined;
        var extra_len: usize = 0;
        extra[extra_len] = .{ .name = "Accept", .value = "application/json" };
        extra_len += 1;

        var aw: std.Io.Writer.Allocating = .init(self.app.arena);
        const result = self.app.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .headers = .{
                .authorization = if (self.token) |t| blk: {
                    const hdr = std.fmt.bufPrint(&auth_buf, "token {s}", .{t}) catch util.fatal("token too long", .{});
                    break :blk .{ .override = hdr };
                } else .omit,
                .user_agent = .{ .override = user_agent },
                .content_type = if (content_type) |ct| .{ .override = ct } else .default,
            },
            .extra_headers = extra[0..extra_len],
            .response_writer = &aw.writer,
        }) catch |err| {
            util.fatal("HTTP request failed ({s}): {t}", .{ url, err });
        };

        const body = aw.written();
        const code = @backingInt(result.status);
        if (code < 200 or code >= 300) {
            if (body.len > 0) {
                util.fatal("API error {d} {s}: {s}", .{ code, result.status.phrase() orelse "", body });
            } else {
                util.fatal("API error {d} {s}", .{ code, result.status.phrase() orelse "" });
            }
        }
        return body;
    }
};

pub fn query(allocator: std.mem.Allocator) Query {
    return .{ .allocator = allocator };
}

pub const Query = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    started: bool = false,

    pub fn add(self: *Query, key: []const u8, value: []const u8) !void {
        try self.buf.append(self.allocator, if (self.started) '&' else '?');
        self.started = true;
        const k = try util.urlEncode(self.allocator, key);
        const v = try util.urlEncode(self.allocator, value);
        try self.buf.appendSlice(self.allocator, k);
        try self.buf.append(self.allocator, '=');
        try self.buf.appendSlice(self.allocator, v);
    }

    pub fn addOpt(self: *Query, key: []const u8, value: ?[]const u8) !void {
        if (value) |v| try self.add(key, v);
    }

    pub fn addInt(self: *Query, key: []const u8, value: u32) !void {
        var tmp: [16]u8 = undefined;
        try self.add(key, std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable);
    }

    pub fn slice(self: *Query) []const u8 {
        return self.buf.items;
    }
};

pub const User = struct {
    login: ?[]const u8 = null,
    full_name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    id: ?i64 = null,
    html_url: ?[]const u8 = null,
    avatar_url: ?[]const u8 = null,
    description: ?[]const u8 = null,
    website: ?[]const u8 = null,
    location: ?[]const u8 = null,
    pronouns: ?[]const u8 = null,
    visibility: ?[]const u8 = null,
    followers_count: ?i64 = null,
    following_count: ?i64 = null,
};

pub const Repository = struct {
    id: ?i64 = null,
    name: ?[]const u8 = null,
    full_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    html_url: ?[]const u8 = null,
    clone_url: ?[]const u8 = null,
    ssh_url: ?[]const u8 = null,
    private: ?bool = null,
    fork: ?bool = null,
    archived: ?bool = null,
    empty: ?bool = null,
    default_branch: ?[]const u8 = null,
    stars_count: ?i64 = null,
    forks_count: ?i64 = null,
    watchers_count: ?i64 = null,
    open_issues_count: ?i64 = null,
    website: ?[]const u8 = null,
    owner: ?User = null,
    parent: ?struct {
        full_name: ?[]const u8 = null,
        html_url: ?[]const u8 = null,
    } = null,
    language: ?[]const u8 = null,
};

pub const Label = struct {
    id: ?i64 = null,
    name: ?[]const u8 = null,
    color: ?[]const u8 = null,
    description: ?[]const u8 = null,
    exclusive: ?bool = null,
    is_archived: ?bool = null,
};

pub const Issue = struct {
    id: ?i64 = null,
    number: ?i64 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    state: ?[]const u8 = null,
    html_url: ?[]const u8 = null,
    comments: ?i64 = null,
    user: ?User = null,
    labels: ?[]Label = null,
    assignees: ?[]User = null,
    pull_request: ?struct { merged: ?bool = null, merged_at: ?[]const u8 = null } = null,
    milestone: ?Milestone = null,
};

pub const Comment = struct {
    id: ?i64 = null,
    body: ?[]const u8 = null,
    user: ?User = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

pub const PullRequest = struct {
    id: ?i64 = null,
    number: ?i64 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    state: ?[]const u8 = null,
    html_url: ?[]const u8 = null,
    mergeable: ?bool = null,
    merged: ?bool = null,
    draft: ?bool = null,
    user: ?User = null,
    labels: ?[]Label = null,
    assignees: ?[]User = null,
    base: ?struct { ref: ?[]const u8 = null, repo: ?Repository = null } = null,
    head: ?struct { ref: ?[]const u8 = null, repo: ?Repository = null, sha: ?[]const u8 = null } = null,
    comments: ?i64 = null,
};

pub const Milestone = struct {
    id: ?i64 = null,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    state: ?[]const u8 = null,
    open_issues: ?i64 = null,
    closed_issues: ?i64 = null,
};

pub const Release = struct {
    id: ?i64 = null,
    name: ?[]const u8 = null,
    tag_name: ?[]const u8 = null,
    body: ?[]const u8 = null,
    html_url: ?[]const u8 = null,
    draft: ?bool = null,
    prerelease: ?bool = null,
    assets: ?[]Attachment = null,
};

pub const Attachment = struct {
    id: ?i64 = null,
    name: ?[]const u8 = null,
    browser_download_url: ?[]const u8 = null,
    size: ?i64 = null,
};

pub const Tag = struct {
    name: ?[]const u8 = null,
    id: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const Organization = struct {
    name: ?[]const u8 = null,
    username: ?[]const u8 = null,
    full_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    website: ?[]const u8 = null,
    location: ?[]const u8 = null,
    email: ?[]const u8 = null,
    visibility: ?[]const u8 = null,
    html_url: ?[]const u8 = null,
};

pub const Team = struct {
    id: ?i64 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    permission: ?[]const u8 = null,
    includes_all_repositories: ?bool = null,
    can_create_org_repo: ?bool = null,
};

pub const WikiPage = struct {
    title: ?[]const u8 = null,
    content_base64: ?[]const u8 = null,
    html_url: ?[]const u8 = null,
};

pub const OAuthToken = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64,
    token_type: ?[]const u8 = null,
};

pub const Contents = struct {
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    type: ?[]const u8 = null,
    content: ?[]const u8 = null,
    encoding: ?[]const u8 = null,
    download_url: ?[]const u8 = null,
};
