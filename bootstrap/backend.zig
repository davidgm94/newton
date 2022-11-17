const std = @import("std");

const ir = @import("ir.zig");

pub const x86_64 = @import("x86_64.zig");

const RelocationType = enum {
    rel32_post_0,
};

const Relocation = struct {
    relocation_type: RelocationType,
    output_offset: usize,

    fn size(self: @This()) usize {
        return switch(self.relocation_type) {
            .rel32_post_0 => 4,
        };
    }

    fn resolve(self: @This(), output_bytes: []u8, relocation_target_offset: usize) !void {
        switch(self.relocation_type) {
            .rel32_post_0 => {
                const rel = relocation_target_offset -% (self.output_offset +% 4);
                output_bytes[self.output_offset..][0..4].* = std.mem.toBytes(@intCast(i32, rel));
            },
        }
    }
};

pub fn Writer(comptime Platform: type) type {
    return struct {
        allocator: std.mem.Allocator = std.heap.page_allocator,
        output_bytes: std.ArrayListUnmanaged(u8) = .{},
        enqueued_blocks: std.AutoHashMapUnmanaged(ir.BlockIndex.Index, std.ArrayListUnmanaged(Relocation)) = .{},
        placed_blocks: std.AutoHashMapUnmanaged(ir.BlockIndex.Index, usize) = .{},

        pub fn blockUnplaced(self: @This(), block: ir.BlockIndex.Index) bool {
            if(self.placed_blocks.get(block)) |_| {
                return true;
            }
            return false;
        }

        pub fn writeRelocatedValue(self: *@This(), reloc_target: ir.BlockIndex.Index, reloc_type: Relocation) !void {
            const reloc = Relocation{
                .output_offset = self.output_bytes.items.len,
                .relocation_type = reloc_type,
            };

            const sz = reloc.size();
            self.output_bytes.appendNTimes(self.allocator, 0xCC, sz);

            if(self.placed_blocks.get(reloc_target)) |offset| {
                reloc.resolve(self.output_bytes.items, offset);
            } else if(self.enqueued_blocks.get(reloc_target)) |q| {
                q.append(self.allocator, reloc);     
            } else {
                var queue = std.ArrayListUnmanaged(Relocation){};
                queue.append(self.allocator, reloc);
                self.enqueued_blocks.put(self.allocator, reloc_target, queue);
            }
        }

        pub fn writeInt(self: *@This(), comptime T: type, value: T) !void {
            try self.output_bytes.appendSlice(self.allocator, &std.mem.toBytes(value));
        }

        fn writeBlock(self: *@This(), bidx: ir.BlockIndex.Index) !?ir.BlockIndex.Index {
            var block = ir.blocks.get(bidx);
            var current_instr = block.first_decl;
            while(ir.decls.getOpt(current_instr)) |instr| {
                const next_block: ?ir.BlockIndex.Index = try Platform.writeDecl(self, ir.decls.getIndex(instr));
                if(next_block) |nb| return nb;
                current_instr = instr.next;
                std.debug.print("Output so far: {}\n", .{std.fmt.fmtSliceHexUpper(self.output_bytes.items)});
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
                    block_relocs = self.enqueued_blocks.fetchRemove(current_block).?.value;
                    preferred_block = null;
                } else {
                    var it = self.enqueued_blocks.iterator();
                    const block = it.next() orelse break;
                    current_block = block.key_ptr.*;
                    block_relocs = block.value_ptr.*;
                    self.enqueued_blocks.removeByPtr(block.key_ptr);
                }

                for(block_relocs.items) |reloc| {
                    try reloc.resolve(self.output_bytes.items, self.output_bytes.items.len);
                }
                block_relocs.deinit(self.allocator);

                preferred_block = try self.writeBlock(current_block);
            }
        }
    };
}
