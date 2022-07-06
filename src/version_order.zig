//! Implementation of GNU version sort.
//! Based on: https://www.gnu.org/software/coreutils/manual/html_node/Version_002dsort-ordering-rules.html

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const math = std.math;

fn versionOrderSplit(src: []const u8) struct { byte_part: []const u8, int_part: usize, rem: usize } {
    const digit_span = spn: {
        const digit_start = ds: for (src) |c, i| {
            for ("1234567890") |a| {
                if (c == a) break :ds i;
            }
        } else null;

        if (digit_start) |ds| {
            const digit_end = de: for (src[ds..]) |c, i| {
                for ("1234567890") |a| {
                    if (c == a) continue :de;
                } else break :de ds + i;
            } else src.len;

            break :spn [2]usize{ ds, digit_end };
        } else {
            break :spn null;
        }
    };
    return .{
        .byte_part = if (digit_span) |ds| src[0..ds[0]] else src, //
        .int_part = if (digit_span) |ds|
            std.fmt.parseUnsigned(usize, src[ds[0]..ds[1]], 10) catch unreachable
        else
            0, //
        .rem = if (digit_span) |ds| ds[1] else src.len,
    };
}

pub fn versionOrder(a: []const u8, b: []const u8) math.Order {
    const isAlpha = std.ascii.isAlpha;
    var a_rem = a;
    var b_rem = b;
    while (a_rem.len > 0 or b_rem.len > 0) {
        // special case: tilde
        {
            const a_tilde = a_rem.len > 0 and a[0] == '~';
            const b_tilde = b_rem.len > 0 and b[0] == '~';
            if (a_tilde != b_tilde)
                return if (a_tilde) .gt else .lt;
        }
        // start "bytes→int→bytes" cycle
        const a_points = versionOrderSplit(a_rem);
        const b_points = versionOrderSplit(b_rem);
        // Slightly changed lexicographical sort
        {
            var i: usize = 0;
            const max = math.min(a_points.byte_part.len, b_points.byte_part.len);
            // char by char comparison
            while (i < max) : (i += 1) {
                const x = a_points.byte_part[i];
                const y = b_points.byte_part[i];
                if (isAlpha(x) == isAlpha(y)) {
                    const ord = math.order(x, y);
                    if (ord != .eq) return ord;
                } else {
                    return if (isAlpha(x)) .gt else .lt;
                }
            }
        }
        // Tiebreaker: length
        var ord = math.order(a_points.byte_part.len, b_points.byte_part.len);
        // Tiebreaker #2: int part
        if (ord == .eq)
            ord = math.order(a_points.int_part, b_points.int_part);
        if (ord != .eq)
            return ord;
        a_rem = a_rem[a_points.rem..];
        b_rem = b_rem[b_points.rem..];
    }
    return .eq;
}

test "version sort" {
    try testing.expect(versionOrder("gnu/linux", "gnu/linux") == .eq);
    try testing.expect(versionOrder("foo07.7z", "foo7a.7z") == .lt);
    try testing.expect(versionOrder("glibc-2.19", "glibc-2.8") == .gt);
    try testing.expect(versionOrder("~", "") == .gt);
    try testing.expect(versionOrder("~copman", "cop") == .gt);
    try testing.expect(versionOrder("blender-2.79-linux-glibc219-x86_64", "blender-2.83") == .lt);
}
