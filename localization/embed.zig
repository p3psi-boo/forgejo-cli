pub const catalog = [_]struct { tag: []const u8, source: []const u8 }{
    .{ .tag = "en-US", .source = @embedFile("en-US/messages.ftl") },
    .{ .tag = "de-DE", .source = @embedFile("de-DE/messages.ftl") },
    .{ .tag = "fi", .source = @embedFile("fi/messages.ftl") },
    .{ .tag = "fr", .source = @embedFile("fr/messages.ftl") },
    .{ .tag = "id", .source = @embedFile("id/messages.ftl") },
    .{ .tag = "it", .source = @embedFile("it/messages.ftl") },
    .{ .tag = "pl", .source = @embedFile("pl/messages.ftl") },
    .{ .tag = "ru", .source = @embedFile("ru/messages.ftl") },
    .{ .tag = "tok", .source = @embedFile("tok/messages.ftl") },
    .{ .tag = "zh-Hans", .source = @embedFile("zh-Hans/messages.ftl") },
};
