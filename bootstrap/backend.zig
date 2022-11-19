const std = @import("std");

const ir = @import("ir.zig");
const rega = @import("rega.zig");

pub const x86_64 = @import("x86_64.zig");

pub const RelocationType = enum {
    rel8_post_0,
    rel32_post_0,

    pub fn size(self: @This()) usize {
        return switch(self) {
            .rel8_post_0 => 1,
            .rel32_post_0 => 4,
        };
    }

    pub fn minDisplacement(self: @This()) isize {
        return switch(self) {
            .rel8_post_0 => -0x80,
            .rel32_post_0 => -0x80000000,
        };
    }

    pub fn maxDisplacement(self: @This()) usize {
        return switch(self) {
            .rel8_post_0 => 0x7F,
            .rel32_post_0 => 0x7FFFFFFF,
        };
    }
};

const Relocation = struct {
    relocation_type: RelocationType,
    output_offset: usize,

    fn resolve(self: @This(), output_bytes: []u8, relocation_target_offset: usize) void {
        switch(self.relocation_type) {
            .rel8_post_0 => {
                const rel = relocation_target_offset -% (self.output_offset +% 1);
                output_bytes[self.output_offset..][0..1].* = std.mem.toBytes(@intCast(i8, @bitCast(i64, rel)));
            },
            .rel32_post_0 => {
                const rel = relocation_target_offset -% (self.output_offset +% 4);
                output_bytes[self.output_offset..][0..4].* = std.mem.toBytes(@intCast(i32, @bitCast(i64, rel)));
            },
        }
    }
};

pub fn Writer(comptime Platform: type) type {
    return struct {
        allocator: std.mem.Allocator = std.heap.page_allocator,
        output_bytes: std.ArrayListUnmanaged(u8) = .{},
        enqueued_blocks: std.AutoArrayHashMapUnmanaged(ir.BlockIndex.Index, std.ArrayListUnmanaged(Relocation)) = .{},
        placed_blocks: std.AutoHashMapUnmanaged(ir.BlockIndex.Index, usize) = .{},
        uf: rega.UnionFind,

        pub fn attemptInlineEdge(self: *@This(), edge: ir.BlockEdgeIndex.Index) !?ir.BlockIndex.Index {
            const target_block = ir.edges.get(edge).target_block;
            if(self.placed_blocks.get(target_block)) |_| {
                return null;
            }
            if(!self.placed_blocks.contains(target_block)) {
                _ = try self.enqueued_blocks.getOrPutValue(self.allocator, target_block, .{});
            }
            return target_block;
        }

        pub fn currentOffset(self: *const @This()) usize {
            return self.output_bytes.items.len;
        }

        pub fn blockOffset(self: *const @This(), edge: ir.BlockEdgeIndex.Index) ?usize {
            const target = ir.edges.get(edge).target_block;
            return self.placed_blocks.get(target);
        }

        pub fn pickSmallestRelocationType(
            self: *const @This(),
            edge: ir.BlockEdgeIndex.Index,
            comptime types: []const std.meta.Tuple(&.{usize, RelocationType}),
        ) ?RelocationType {
            if(self.blockOffset(edge)) |offset| {
                inline for(types) |t| {
                    const instr_size = t[1].size() + t[0];
                    const disp = @bitCast(isize, offset -% (self.currentOffset() + instr_size));
                    if(disp >= t[1].minDisplacement() and disp <= t[1].maxDisplacement()) return t[1];
                }
            }
            return null;
        }

        pub fn writeRelocatedValue(self: *@This(), edge: ir.BlockEdgeIndex.Index, reloc_type: RelocationType) !void {
            const reloc_target = ir.edges.get(edge).target_block;
            const reloc = Relocation{
                .output_offset = self.output_bytes.items.len,
                .relocation_type = reloc_type,
            };

            const sz = reloc_type.size();
            try self.output_bytes.appendNTimes(self.allocator, 0xCC, sz);

            if(self.placed_blocks.get(reloc_target)) |offset| {
                reloc.resolve(self.output_bytes.items, offset);
            } else if(self.enqueued_blocks.getPtr(reloc_target)) |q| {
                try q.append(self.allocator, reloc);
            } else {
                var queue = std.ArrayListUnmanaged(Relocation){};
                try queue.append(self.allocator, reloc);
                try self.enqueued_blocks.put(self.allocator, reloc_target, queue);
            }
        }

        pub fn writeInt(self: *@This(), comptime T: type, value: T) !void {
            try self.output_bytes.appendSlice(self.allocator, &std.mem.toBytes(value));
        }

        fn writeBlock(self: *@This(), bidx: ir.BlockIndex.Index) !?ir.BlockIndex.Index {
            var block = ir.blocks.get(bidx);
            var current_instr = block.first_decl;

            try self.placed_blocks.put(self.allocator, bidx, self.output_bytes.items.len);
            while(ir.decls.getOpt(current_instr)) |instr| {
                const next_block: ?ir.BlockIndex.Index = try Platform.writeDecl(self, ir.decls.getIndex(instr), self.uf);
                if(next_block) |nb| return nb;
                current_instr = instr.next;
            }
            return null;
        }

        pub fn writeFunction(self: *@This(), head_block: ir.BlockIndex.Index) !void {
            try self.enqueued_blocks.put(self.allocator, head_block, .{});
            var preferred_block: ?ir.BlockIndex.Index = null;

            while(true) {
                var current_block: ir.BlockIndex.Index = undefined;
                var block_relocs: std.ArrayListUnmanaged(Relocation) = undefined;

                if(preferred_block) |blk| {
                    current_block = blk;
                    block_relocs = self.enqueued_blocks.fetchSwapRemove(current_block).?.value;
                    preferred_block = null;
                } else {
                    const block = self.enqueued_blocks.popOrNull() orelse break;
                    current_block = block.key;
                    block_relocs = block.value;
                }

                for(block_relocs.items) |reloc| {
                    reloc.resolve(self.output_bytes.items, self.output_bytes.items.len);
                }
                block_relocs.deinit(self.allocator);

                preferred_block = try self.writeBlock(current_block);
            }

            std.debug.print("Output: {}\n", .{std.fmt.fmtSliceHexUpper(self.output_bytes.items)});
        }
    };
}
