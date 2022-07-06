const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const uefi = std.os.uefi;
const allocator = uefi.pool_allocator;
const File = uefi.protocols.FileProtocol;
const Device = uefi.protocols.DevicePathProtocol;
const L = std.unicode.utf8ToUtf16LeStringLiteral; // Like L"str" in C compilers

const BootEntry = @import("boot_entry.zig").BootEntry;
test {
    _ = BootEntry;
}

var con_out: *uefi.protocols.SimpleTextOutputProtocol = undefined;

fn bootEntrySortReverse(_: void, lhs: BootEntry, rhs: BootEntry) bool {
    return BootEntry.order(lhs, rhs) == .gt;
}

pub fn puts(msg: []const u8) void {
    for (msg) |c| {
        // https://github.com/ziglang/zig/issues/4372
        const c_ = [2]u16{ c, 0 };
        _ = con_out.outputString(@ptrCast(*const [1:0]u16, &c_));
    }
    _ = con_out.outputString(&[_:0]u16{ '\r', '\n', 0 });
}

pub fn putsLiteral(comptime msg: []const u8) void {
    _ = con_out.outputString(L(msg ++ "\r\n"));
}

pub fn printf(comptime format: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    const ret = std.fmt.bufPrint(&buf, format, args) catch {
        putsLiteral("[[not enough memory to display message]]");
        return;
    };
    puts(ret);
}

pub fn getFileInfoAlloc(alloc: mem.Allocator, file: *File) !*uefi.protocols.FileInfo {
    var bufsiz: usize = 256;
    var ret = try alloc.alignedAlloc(u8, 8, 256);
    while (true) {
        file.getInfo(&uefi.protocols.FileInfo.guid, &bufsiz, ret.ptr).err() catch |e| switch (e) {
            error.BufferTooSmall => {
                ret = try alloc.realloc(ret, bufsiz);
                continue;
            },
            else => return e,
        };
        break;
    }
    return @ptrCast(*uefi.protocols.FileInfo, ret.ptr);
}

pub fn main() usize {
    const boot_services = uefi.system_table.boot_services orelse return 1;
    con_out = uefi.system_table.con_out orelse return 1;
    // Get metadata about image
    const image_meta = boot_services.openProtocolSt(uefi.protocols.LoadedImageProtocol, uefi.handle) catch {
        putsLiteral("error: can't query information about boot image");
        return 1;
    };
    // Find device where it's stored
    const root_handle = image_meta.device_handle orelse {
        putsLiteral("error: can't get handle of root device");
        return 1;
    };
    const uefi_root = boot_services.openProtocolSt(uefi.protocols.SimpleFileSystemProtocol, root_handle) catch {
        putsLiteral("error: can't init root volume");
        return 1;
    };

    // Get root dir
    var root_dir: *File = undefined;
    if (uefi_root.openVolume(&root_dir) != uefi.Status.Success) {
        puts("error: can't open root volume");
        return 1;
    }
    var entries_dir: *File = undefined;
    if (root_dir.open(&entries_dir, L("\\loader\\entries"), File.efi_file_mode_read, File.efi_file_directory) != uefi.Status.Success) {
        puts("error: can't load entries directory");
        return 1;
    }

    _ = con_out.reset(false);

    var buf: [4096]u8 align(8) = undefined;
    const entries = b: {
        var entries_tmp = std.ArrayList(BootEntry).init(uefi.pool_allocator);
        while (true) {
            var bufsiz = buf.len;
            entries_dir.read(&bufsiz, &buf).err() catch |e| {
                putsLiteral("yo man err:");
                puts(@errorName(e));
                break;
            };
            if (bufsiz == 0) break;
            const file_info = @ptrCast(*uefi.protocols.FileInfo, &buf);
            const filename = mem.span(file_info.getFileName());
            if (!mem.eql(u16, filename, L(".")) and !mem.eql(u16, filename, L(".."))) {
                var entry_file: *File = undefined;
                if (entries_dir.open(&entry_file, filename, File.efi_file_mode_read, File.efi_file_archive) == uefi.Status.Success) {
                    const new_entry = BootEntry.fromFile(uefi.pool_allocator, filename, entry_file.reader()) catch |e| {
                        putsLiteral("Failed to parse the following file:");
                        _ = con_out.outputString(filename);
                        printf("\r\nDue to following error: {s}", .{@errorName(e)});
                        continue;
                    };
                    entries_tmp.append(new_entry) catch {
                        putsLiteral("Out of memory. Entries may be missing");
                    };
                }
            }
        }
        break :b entries_tmp.toOwnedSlice();
    };
    defer uefi.pool_allocator.free(entries);
    std.sort.sort(BootEntry, entries, {}, bootEntrySortReverse);

    for (entries) |boot_entry| {
        puts(boot_entry.title.?);
    }
    putsLiteral("I'm Going To Start The First Entry!");

    //var img_file: *File = undefined;
    //root_dir.open(&img_file, entries[0].payload.linux, File.efi_file_mode_read, File.efi_file_archive).err() catch |e| {
    //    _ = con_out.outputString(entries[0].payload.linux);
    //    printf("File pointed to by first entry can't be loaded: {s}", .{@errorName(e)});
    //    return 1;
    //};
    //const img_contents = img_file.reader().readAllAlloc(uefi.pool_allocator, 2048 * 1024 * 1024) catch {
    //    putsLiteral("out of memery");
    //    return 1;
    //};
    const root_devpath = boot_services.openProtocolSt(uefi.protocols.DevicePathProtocol, root_handle) catch {
        putsLiteral("root_devpath cringe!");
        return 1;
    };
    const img_devpath = root_devpath.create_file_device_path(uefi.pool_allocator, entries[0].payload.linux) catch {
        putsLiteral("img_devpath cringe!");
        return 1;
    };
    var next_handle: ?uefi.Handle = undefined;
    boot_services.loadImage(false, uefi.handle, img_devpath, null, 0, &next_handle).err() catch |e| {
        printf("Error loading image: {s}", .{@errorName(e)});
        return 1;
    };
    _ = boot_services.startImage(next_handle orelse {
        putsLiteral("Image is not loaded.");
        return 1;
    }, null, null);

    putsLiteral("I'm alive, oh no.");
    _ = uefi.system_table.boot_services.?.stall(5 * 1000 * 1000);
    return 0;
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
