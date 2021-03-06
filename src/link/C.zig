const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const fs = std.fs;
const codegen = @import("../codegen/c.zig");
const link = @import("../link.zig");
const trace = @import("../tracy.zig").trace;
const C = @This();
const Type = @import("../type.zig").Type;

pub const base_tag: link.File.Tag = .c;
pub const zig_h = @embedFile("C/zig.h");

base: link.File,

/// Per-declaration data. For functions this is the body, and
/// the forward declaration is stored in the FnBlock.
pub const DeclBlock = struct {
    code: std.ArrayListUnmanaged(u8),

    pub const empty: DeclBlock = .{
        .code = .{},
    };
};

/// Per-function data.
pub const FnBlock = struct {
    fwd_decl: std.ArrayListUnmanaged(u8),
    typedefs: codegen.TypedefMap.Unmanaged,

    pub const empty: FnBlock = .{
        .fwd_decl = .{},
        .typedefs = .{},
    };
};

pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*C {
    assert(options.object_format == .c);

    if (options.use_llvm) return error.LLVMHasNoCBackend;
    if (options.use_lld) return error.LLDHasNoCBackend;

    const file = try options.emit.?.directory.handle.createFile(sub_path, .{
        // Truncation is done on `flush`.
        .truncate = false,
        .mode = link.determineMode(options),
    });
    errdefer file.close();

    var c_file = try allocator.create(C);
    errdefer allocator.destroy(c_file);

    c_file.* = C{
        .base = .{
            .tag = .c,
            .options = options,
            .file = file,
            .allocator = allocator,
        },
    };

    return c_file;
}

pub fn deinit(self: *C) void {
    const module = self.base.options.module orelse return;
    for (module.decl_table.items()) |entry| {
        self.freeDecl(entry.value);
    }
}

pub fn allocateDeclIndexes(self: *C, decl: *Module.Decl) !void {}

pub fn freeDecl(self: *C, decl: *Module.Decl) void {
    decl.link.c.code.deinit(self.base.allocator);
    decl.fn_link.c.fwd_decl.deinit(self.base.allocator);
    var it = decl.fn_link.c.typedefs.iterator();
    while (it.next()) |some| {
        self.base.allocator.free(some.value.rendered);
    }
    decl.fn_link.c.typedefs.deinit(self.base.allocator);
}

pub fn updateDecl(self: *C, module: *Module, decl: *Module.Decl) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const fwd_decl = &decl.fn_link.c.fwd_decl;
    const typedefs = &decl.fn_link.c.typedefs;
    const code = &decl.link.c.code;
    fwd_decl.shrinkRetainingCapacity(0);
    {
        var it = typedefs.iterator();
        while (it.next()) |entry| {
            module.gpa.free(entry.value.rendered);
        }
    }
    typedefs.clearRetainingCapacity();
    code.shrinkRetainingCapacity(0);

    var object: codegen.Object = .{
        .dg = .{
            .module = module,
            .error_msg = null,
            .decl = decl,
            .fwd_decl = fwd_decl.toManaged(module.gpa),
            .typedefs = typedefs.promote(module.gpa),
        },
        .gpa = module.gpa,
        .code = code.toManaged(module.gpa),
        .value_map = codegen.CValueMap.init(module.gpa),
        .indent_writer = undefined, // set later so we can get a pointer to object.code
    };
    object.indent_writer = .{ .underlying_writer = object.code.writer() };
    defer {
        object.value_map.deinit();
        object.code.deinit();
        object.dg.fwd_decl.deinit();
        var it = object.dg.typedefs.iterator();
        while (it.next()) |some| {
            module.gpa.free(some.value.rendered);
        }
        object.dg.typedefs.deinit();
    }

    codegen.genDecl(&object) catch |err| switch (err) {
        error.AnalysisFail => {
            try module.failed_decls.put(module.gpa, decl, object.dg.error_msg.?);
            return;
        },
        else => |e| return e,
    };

    fwd_decl.* = object.dg.fwd_decl.moveToUnmanaged();
    typedefs.* = object.dg.typedefs.unmanaged;
    object.dg.typedefs.unmanaged = .{};
    code.* = object.code.moveToUnmanaged();

    // Free excess allocated memory for this Decl.
    fwd_decl.shrinkAndFree(module.gpa, fwd_decl.items.len);
    code.shrinkAndFree(module.gpa, code.items.len);
}

pub fn updateDeclLineNumber(self: *C, module: *Module, decl: *Module.Decl) !void {
    // The C backend does not have the ability to fix line numbers without re-generating
    // the entire Decl.
    return self.updateDecl(module, decl);
}

pub fn flush(self: *C, comp: *Compilation) !void {
    return self.flushModule(comp);
}

pub fn flushModule(self: *C, comp: *Compilation) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const module = self.base.options.module.?;

    // This code path happens exclusively with -ofmt=c. The flush logic for
    // emit-h is in `flushEmitH` below.

    // We collect a list of buffers to write, and write them all at once with pwritev ????
    var all_buffers = std.ArrayList(std.os.iovec_const).init(comp.gpa);
    defer all_buffers.deinit();

    // This is at least enough until we get to the function bodies without error handling.
    try all_buffers.ensureCapacity(module.decl_table.count() + 2);

    var file_size: u64 = zig_h.len;
    all_buffers.appendAssumeCapacity(.{
        .iov_base = zig_h,
        .iov_len = zig_h.len,
    });

    var err_typedef_buf = std.ArrayList(u8).init(comp.gpa);
    defer err_typedef_buf.deinit();
    const err_typedef_writer = err_typedef_buf.writer();
    const err_typedef_item = all_buffers.addOneAssumeCapacity();

    render_errors: {
        if (module.global_error_set.size == 0) break :render_errors;
        var it = module.global_error_set.iterator();
        while (it.next()) |entry| {
            try err_typedef_writer.print("#define zig_error_{s} {d}\n", .{ entry.key, entry.value });
        }
        try err_typedef_writer.writeByte('\n');
    }

    var fn_count: usize = 0;
    var typedefs = std.HashMap(Type, []const u8, Type.hash, Type.eql, std.hash_map.default_max_load_percentage).init(comp.gpa);
    defer typedefs.deinit();

    // Typedefs, forward decls and non-functions first.
    // TODO: performance investigation: would keeping a list of Decls that we should
    // generate, rather than querying here, be faster?
    for (module.decl_table.items()) |kv| {
        const decl = kv.value;
        switch (decl.typed_value) {
            .most_recent => |tvm| {
                const buf = buf: {
                    if (tvm.typed_value.val.castTag(.function)) |_| {
                        var it = decl.fn_link.c.typedefs.iterator();
                        while (it.next()) |new| {
                            if (typedefs.get(new.key)) |previous| {
                                try err_typedef_writer.print("typedef {s} {s};\n", .{ previous, new.value.name });
                            } else {
                                try typedefs.ensureCapacity(typedefs.capacity() + 1);
                                try err_typedef_writer.writeAll(new.value.rendered);
                                typedefs.putAssumeCapacityNoClobber(new.key, new.value.name);
                            }
                        }
                        fn_count += 1;
                        break :buf decl.fn_link.c.fwd_decl.items;
                    } else {
                        break :buf decl.link.c.code.items;
                    }
                };
                all_buffers.appendAssumeCapacity(.{
                    .iov_base = buf.ptr,
                    .iov_len = buf.len,
                });
                file_size += buf.len;
            },
            .never_succeeded => continue,
        }
    }

    err_typedef_item.* = .{
        .iov_base = err_typedef_buf.items.ptr,
        .iov_len = err_typedef_buf.items.len,
    };
    file_size += err_typedef_buf.items.len;

    // Now the function bodies.
    try all_buffers.ensureCapacity(all_buffers.items.len + fn_count);
    for (module.decl_table.items()) |kv| {
        const decl = kv.value;
        switch (decl.typed_value) {
            .most_recent => |tvm| {
                if (tvm.typed_value.val.castTag(.function)) |_| {
                    const buf = decl.link.c.code.items;
                    all_buffers.appendAssumeCapacity(.{
                        .iov_base = buf.ptr,
                        .iov_len = buf.len,
                    });
                    file_size += buf.len;
                }
            },
            .never_succeeded => continue,
        }
    }

    const file = self.base.file.?;
    try file.setEndPos(file_size);
    try file.pwritevAll(all_buffers.items, 0);
}

pub fn flushEmitH(module: *Module) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const emit_h_loc = module.emit_h orelse return;

    // We collect a list of buffers to write, and write them all at once with pwritev ????
    var all_buffers = std.ArrayList(std.os.iovec_const).init(module.gpa);
    defer all_buffers.deinit();

    try all_buffers.ensureCapacity(module.decl_table.count() + 1);

    var file_size: u64 = zig_h.len;
    all_buffers.appendAssumeCapacity(.{
        .iov_base = zig_h,
        .iov_len = zig_h.len,
    });

    for (module.decl_table.items()) |kv| {
        const emit_h = kv.value.getEmitH(module);
        const buf = emit_h.fwd_decl.items;
        all_buffers.appendAssumeCapacity(.{
            .iov_base = buf.ptr,
            .iov_len = buf.len,
        });
        file_size += buf.len;
    }

    const directory = emit_h_loc.directory orelse module.comp.local_cache_directory;
    const file = try directory.handle.createFile(emit_h_loc.basename, .{
        // We set the end position explicitly below; by not truncating the file, we possibly
        // make it easier on the file system by doing 1 reallocation instead of two.
        .truncate = false,
    });
    defer file.close();

    try file.setEndPos(file_size);
    try file.pwritevAll(all_buffers.items, 0);
}

pub fn updateDeclExports(
    self: *C,
    module: *Module,
    decl: *Module.Decl,
    exports: []const *Module.Export,
) !void {}
