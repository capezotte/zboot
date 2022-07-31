const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const math = std.math;
const utf = std.unicode;
const L = utf.utf8ToUtf16LeStringLiteral;
const Lalloc = utf.utf8ToUtf16LeWithNull;

const versionOrder = @import("version_order.zig").versionOrder;
test {
    _ = versionOrder;
}

pub const BootEntry = struct {
    payload: Payload,
    arena: std.heap.ArenaAllocator,
    filename: [256:0]u16,
    @"sort-key": ?[]const u8 = null,
    title: ?[]const u8 = null,
    version: ?[]const u8 = null,
    initrd: ?[]const u8 = null,
    options: ?[]const u8 = null,

    pub const Payload = union(enum) {
        efi: [:0]const u16,
        linux: [:0]const u16,
    };

    pub fn deinit(self: *const BootEntry) void {
        self.arena.deinit();
    }

    pub fn fromFile(base_alloc: mem.Allocator, fname: []const u16, reader: anytype) !BootEntry {
        var found_payload = false;
        if (fname.len > 255)
            return error.NameTooLong;
        var ret = BootEntry{ .filename = undefined, .arena = std.heap.ArenaAllocator.init(base_alloc), .payload = undefined };
        errdefer ret.deinit();
        mem.copy(u16, &ret.filename, fname);
        next_line: while (try reader.readUntilDelimiterOrEofAlloc(base_alloc, '\n', 4096)) |line| {
            defer base_alloc.free(line);
            if (line.len > 0 and line[0] == '#') {
                continue;
            }
            inline for (@typeInfo(BootEntry).Struct.fields) |field| {
                // We only want to fill in the optionals
                if (@typeInfo(@TypeOf(@field(ret, field.name))) != .Optional) continue;
                if (mem.startsWith(u8, line, field.name ++ " ")) {
                    const field_get = mem.trim(u8, line[field.name.len..], " \t");
                    if (field_get.len > 0) {
                        @field(ret, field.name) = try ret.arena.allocator().dupe(u8, field_get);
                        continue :next_line;
                    } // else: keep null
                }
            }
            inline for (@typeInfo(Payload).Union.fields) |field| {
                if (mem.startsWith(u8, line, field.name ++ " ")) {
                    const field_get = mem.trim(u8, line[field.name.len..], " \t");
                    const field_u16 = try Lalloc(ret.arena.allocator(), field_get);
                    mem.replaceScalar(u16, field_u16, '/', '\\'); // Microsoft Windows for Firmware™
                    if (field_get.len > 0) {
                        ret.payload = @unionInit(Payload, field.name, field_u16);
                        found_payload = true;
                        continue :next_line;
                    } // else keep undefined
                }
            }
        }
        if (!found_payload) {
            return error.NoPayload;
        }
        return ret;
    }

    /// Order two boot entries.
    pub fn order(left: BootEntry, right: BootEntry) math.Order {
        inline for (@typeInfo(BootEntry).Struct.fields) |field| {
            if (@typeInfo(@TypeOf(@field(@as(BootEntry, undefined), field.name))) != .Optional) continue;
            const ord = versionOrder(@field(left, field.name) orelse "", @field(right, field.name) orelse "");
            if (ord != .eq) return ord;
        }
        return mem.order(u16, &left.filename, &right.filename);
    }

    /// Returns filename without considering underlying payload type.
    pub fn payloadFilename(self: *const BootEntry) [:0]const u16 {
        return switch (self.payload) {
            .linux => |s| s,
            .efi => |s| s,
        };
    }

    /// Allocates the command line entries that would be used by this bootentry.
    pub fn commandLine(self: *const BootEntry, alloc: mem.Allocator) ![:0]u16 {
        var ret = std.ArrayList(u16).init(alloc);
        errdefer ret.deinit();
        if (self.options) |o| {
            const o_u16 = try Lalloc(alloc, o);
            defer alloc.free(o_u16);
            try ret.appendSlice(o_u16);
            try ret.append(' ');
        }
        if (self.initrd) |i| {
            const i_u16 = try Lalloc(alloc, i);
            defer alloc.free(i_u16);
            mem.replaceScalar(u16, i_u16, '/', '\\');
            try ret.appendSlice(L("initrd="));
            try ret.appendSlice(i_u16);
            try ret.append(' ');
        }
        _ = ret.popOrNull() orelse {}; // pop the space
        return ret.toOwnedSliceSentinel(0);
    }

    /// Prints a name for the entry. Buffer must be freed by caller.
    pub fn repr(self: *const BootEntry, alloc: mem.Allocator) ![]const u16 {
        var ret = std.ArrayList(u16).init(alloc);
        errdefer ret.deinit();
        if (self.title) |t| {
            const t_u16 = try Lalloc(alloc, t);
            defer alloc.free(t_u16);
            try ret.appendSlice(t_u16);
        } else {
            try ret.appendSlice(switch (self.payload) {
                .linux => |l| b: {
                    try ret.appendSlice(L("Linux "));
                    break :b l;
                },
                .efi => |e| b: {
                    try ret.appendSlice(L("EFI executable "));
                    break :b e;
                },
            });
        }
        if (self.version) |v| {
            try ret.appendSlice(L(" ("));
            const v_u16 = try Lalloc(alloc, v);
            defer alloc.free(v_u16);
            try ret.appendSlice(v_u16);
            try ret.append(')');
        }
        // fall back to filename if nothing shows
        if (ret.items.len == 0) {
            ret.appendSlice(self.filename);
        }
        return ret.toOwnedSlice();
    }
};

test "create BootEntry" {
    {
        const testFile = std.io.fixedBufferStream("title s").reader();
        try testing.expectError(error.NoPayload, BootEntry.fromFile(testing.allocator, L(""), testFile));
    }
    {
        const testFile = std.io.fixedBufferStream("title Windows 10\nefi  \\efi\\microsoft\\bootmgfw.efi").reader();
        const entry = try BootEntry.fromFile(testing.allocator, L("tmp.conf"), testFile);
        defer entry.deinit();
        try testing.expectEqualStrings(entry.title.?, "Windows 10");
        try testing.expectEqualSlices(u16, entry.payload.efi, L("\\efi\\microsoft\\bootmgfw.efi"));
        try testing.expect(entry.version == null);
        try testing.expect(entry.options == null);
        try testing.expect(entry.initrd == null);
    }
    {
        const testFile = std.io.fixedBufferStream("title     Gentoo Linux\nversion 4.20\noptions rw initrd=\\dracut.img\nlinux  /vmlinuz-4.20").reader();
        const entry = try BootEntry.fromFile(testing.allocator, L("tmp.conf"), testFile);
        defer entry.deinit();
        try testing.expectEqualStrings(entry.title.?, "Gentoo Linux");
        try testing.expectEqualStrings(entry.version.?, "4.20");
        try testing.expectEqualStrings(entry.options.?, "rw initrd=\\dracut.img");
        try testing.expectEqualSlices(u16, entry.payload.linux, L("\\vmlinuz-4.20"));
        try testing.expect(entry.initrd == null);
    }
}

test "sort BootEntry" {
    {
        var testFile = std.io.fixedBufferStream("title     Gentoo Linux\nversion 4.20\noptions rw initrd=\\dracut.img\nlinux  /vmlinuz-4.20");
        const entry1 = try BootEntry.fromFile(testing.allocator, L("a.conf"), testFile.reader());
        defer entry1.deinit();
        try testFile.seekTo(0);
        const entry2 = try BootEntry.fromFile(testing.allocator, L("b.conf"), testFile.reader());
        defer entry2.deinit();
        try testing.expectEqual(BootEntry.order(entry1, entry2), .lt);
    }
}
