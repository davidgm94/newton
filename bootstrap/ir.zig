const std = @import("std");

const ast = @import("ast.zig");
const backends = @import("backends/backends.zig");
const indexed_list = @import("indexed_list.zig");
const sema = @import("sema.zig");
const rega = @import("rega.zig");

pub const DeclIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const BlockIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const BlockEdgeIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const PhiOperandIndex = indexed_list.Indices(u32, opaque{}, .{});
pub const FunctionArgumentIndex = indexed_list.Indices(u32, opaque{}, .{});

// Based on
// "Simple and Efficient Construction of Static Single Assignment Form"
// https://pp.info.uni-karlsruhe.de/uploads/publikationen/braun13cc.pdf
// by
// Matthias Braun, Sebastian Buchwald, Sebastian Hack, Roland Leißa, Christoph Mallon and Andreas Zwinkau

pub const Bop = struct {
    lhs: DeclIndex.Index,
    rhs: DeclIndex.Index,
};

pub const VariableConstantBop = struct {
    lhs: DeclIndex.Index,
    rhs: u64,
};

pub const InstrType = enum {
    u8,
    u16,
    u32,
    u64,
};

const MemoryReference = struct {
    pointer_value: DeclIndex.Index,
    pointer_value_offset: i32,
    sema_pointer_type: sema.PointerType,

    fn instrType(self: @This()) InstrType {
        return typeFor(self.sema_pointer_type.child);
    }

    pub fn load(self: @This()) DeclInstr {
        std.debug.assert(!self.sema_pointer_type.is_volatile); // Not yet implemented
        return .{.load = .{.source = self.pointer_value, .type = self.instrType()}};
    }

    pub fn store(self: @This(), value: DeclIndex.Index) DeclInstr {
        std.debug.assert(!self.sema_pointer_type.is_volatile); // Not yet implemented
        std.debug.assert(!self.sema_pointer_type.is_const);
        return .{.store = .{.dest = self.pointer_value, .value = value}};
    }
};

fn typeForBits(bits: u32) InstrType {
    if(bits <= 8) return .u8;
    if(bits <= 16) return .u16;
    if(bits <= 32) return .u32;
    if(bits <= 64) return .u64;
    @panic("it's too big for me :pensive:");
}

fn typeFor(type_idx: sema.TypeIndex.Index) InstrType {
    return switch(sema.types.get(type_idx).*) {
        .signed_int, .unsigned_int => |bits| typeForBits(bits),
        .reference, .pointer, .void, .noreturn => backends.current_backend.pointer_type,
        .bool, => .u8,
        else => |other| std.debug.panic("TODO: typeFor {s}", .{@tagName(other)}),
    };
}

const Cast = struct {
    value: DeclIndex.Index,
    type: InstrType,
};

const FunctionArgument = struct {
    value: DeclIndex.Index,
    next: FunctionArgumentIndex.OptIndex = .none,
};

pub const InstrMaxRegs = 2;
pub const RegIndex = std.math.IntFittingRange(0, InstrMaxRegs - 1);

pub const DeclInstr = union(enum) {
    param_ref: struct {
        param_idx: u8,
        type: InstrType,
    },
    stack_ref: struct { offset: u32, orig_offset: u32, type: sema.PointerType },
    global_ref: struct { offset: u32, orig_offset: u32, type: sema.PointerType },
    function_ref: sema.InstantiatedFunction,
    load_int_constant: struct {
        value: u64,
        type: InstrType,
    },
    clobber: DeclIndex.Index,
    addr_of: DeclIndex.Index,
    zero_extend: Cast,
    sign_extend: Cast,
    truncate: Cast,
    load_bool_constant: bool,
    enter_function: u32,
    leave_function: struct {
        restore_stack: bool,
        value: DeclIndex.Index,
    },
    undefined,
    @"unreachable",

    function_call: struct {
        callee: sema.InstantiatedFunction,
        first_argument: FunctionArgumentIndex.OptIndex,
    },
    function_ptr_call: struct {
        callee: DeclIndex.Index,
        first_argument: FunctionArgumentIndex.OptIndex,
        sema_return_type: sema.TypeIndex.Index,
    },
    tail_call: struct {
        callee: sema.InstantiatedFunction,
        first_argument: FunctionArgumentIndex.OptIndex,
        tail: DeclIndex.Index,
    },
    syscall: FunctionArgumentIndex.OptIndex,

    add: Bop,
    sub: Bop,
    multiply: Bop,
    divide: Bop,
    modulus: Bop,
    shift_left: Bop,
    shift_right: Bop,
    bit_and: Bop,
    bit_or: Bop,
    bit_xor: Bop,

    inplace_add: Bop,
    inplace_sub: Bop,
    inplace_multiply: Bop,
    inplace_divide: Bop,
    inplace_modulus: Bop,
    inplace_shift_left: Bop,
    inplace_shift_right: Bop,
    inplace_bit_and: Bop,
    inplace_bit_or: Bop,
    inplace_bit_xor: Bop,

    less: Bop,
    less_equal: Bop,
    greater: Bop,
    greater_equal: Bop,
    equals: Bop,
    not_equal: Bop,

    negate: DeclIndex.Index,
    logical_not: DeclIndex.Index,

    store: struct {
        dest: DeclIndex.Index,
        value: DeclIndex.Index,
    },
    store_constant: struct {
        dest: DeclIndex.Index,
        type: InstrType,
        value: u64,
    },
    load: struct {
        source: DeclIndex.Index,
        type: InstrType,
    },
    reference_wrap: MemoryReference,

    add_constant: VariableConstantBop,
    sub_constant: VariableConstantBop,
    multiply_constant: VariableConstantBop,
    divide_constant: VariableConstantBop,
    modulus_constant: VariableConstantBop,
    shift_left_constant: VariableConstantBop,
    shift_right_constant: VariableConstantBop,
    bit_and_constant: VariableConstantBop,
    bit_or_constant: VariableConstantBop,
    bit_xor_constant: VariableConstantBop,

    inplace_add_constant: VariableConstantBop,
    inplace_sub_constant: VariableConstantBop,
    inplace_multiply_constant: VariableConstantBop,
    inplace_divide_constant: VariableConstantBop,
    inplace_modulus_constant: VariableConstantBop,
    inplace_shift_left_constant: VariableConstantBop,
    inplace_shift_right_constant: VariableConstantBop,
    inplace_bit_and_constant: VariableConstantBop,
    inplace_bit_or_constant: VariableConstantBop,
    inplace_bit_xor_constant: VariableConstantBop,

    less_constant: VariableConstantBop,
    less_equal_constant: VariableConstantBop,
    greater_constant: VariableConstantBop,
    greater_equal_constant: VariableConstantBop,
    equals_constant: VariableConstantBop,
    not_equal_constant: VariableConstantBop,

    incomplete_phi: DeclIndex.OptIndex, // Holds the next incomplete phi node in the same block
    copy: DeclIndex.Index, // Should be eliminated during optimization
    pick: struct {
        src: DeclIndex.Index,
        idx: RegIndex,
    },
    @"if": struct {
        condition: DeclIndex.Index,
        taken: BlockEdgeIndex.Index,
        not_taken: BlockEdgeIndex.Index,
    },
    goto: BlockEdgeIndex.Index,
    phi: PhiOperandIndex.OptIndex,

    const OperandIterator = struct {
        value: union(enum) {
            bounded_iterator: std.BoundedArray(*DeclIndex.Index, 2),
            arg_iterator: ?*FunctionArgument,
            phi_iterator: ?*PhiOperand,
            function_ptr_call_iterator: DeclIndex.Index,
        },

        pub fn next(self: *@This()) ?*DeclIndex.Index {
            switch(self.value) {
                .bounded_iterator => |*list| return if(list.len == 0) null else list.swapRemove(0),
                .phi_iterator => |*curr_opt| {
                    if(curr_opt.*) |curr| {
                        curr_opt.* = phi_operands.getOpt(curr.next);
                        return &curr.decl;
                    } else {
                        return null;
                    }
                },
                .arg_iterator => |*curr_opt| {
                    if(curr_opt.*) |curr| {
                        curr_opt.* = function_arguments.getOpt(curr.next);
                        return &curr.value;
                    } else {
                        return null;
                    }
                },
                .function_ptr_call_iterator => |decl| {
                    const fcall = &decls.get(decl).instr.function_ptr_call;
                    const result = &fcall.callee;
                    self.value = .{.arg_iterator = function_arguments.getOpt(fcall.first_argument)};
                    return result;
                },
            }
        }
    };

    pub fn operands(self: *@This()) OperandIterator {
        var bounded_result = OperandIterator{.value = .{.bounded_iterator = .{}}};

        switch(self.*) {
            .incomplete_phi => unreachable,

            .phi => |p| return .{.value = .{.phi_iterator = phi_operands.getOpt(p)}},
            .function_call => |fcall| return .{.value = .{.arg_iterator = function_arguments.getOpt(fcall.first_argument)}},
            .function_ptr_call => return .{.value = .{.function_ptr_call_iterator = decls.getIndex(@fieldParentPtr(Decl, "instr", self))}},
            .tail_call => |tcall| return .{.value = .{.arg_iterator = function_arguments.getOpt(tcall.first_argument)}},
            .syscall => |farg| return .{.value = .{.arg_iterator = function_arguments.getOpt(farg)}},

            .add, .sub, .multiply, .divide, .modulus,
            .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
            .inplace_add, .inplace_sub, .inplace_multiply, .inplace_divide, .inplace_modulus,
            .inplace_shift_left, .inplace_shift_right, .inplace_bit_and, .inplace_bit_or, .inplace_bit_xor,
            .less, .less_equal, .greater, .greater_equal, .equals, .not_equal,
            => |*bop| {
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&bop.lhs);
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&bop.rhs);
            },

            .reference_wrap => |*rr| {
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&rr.pointer_value);
            },

            .zero_extend, .sign_extend, .truncate => |*cast| bounded_result.value.bounded_iterator.appendAssumeCapacity(&cast.value),
            .clobber, .addr_of, .logical_not, .negate => |*op| bounded_result.value.bounded_iterator.appendAssumeCapacity(op),

            .add_constant, .sub_constant, .multiply_constant, .divide_constant, .modulus_constant,
            .shift_left_constant, .shift_right_constant, .bit_and_constant, .bit_or_constant, .bit_xor_constant,
            .inplace_add_constant, .inplace_sub_constant, .inplace_multiply_constant, .inplace_divide_constant, .inplace_modulus_constant,
            .inplace_shift_left_constant, .inplace_shift_right_constant, .inplace_bit_and_constant, .inplace_bit_or_constant, .inplace_bit_xor_constant,
            .less_constant, .less_equal_constant, .greater_constant, .greater_equal_constant, .equals_constant, .not_equal_constant,
            => |*bop| {
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&bop.lhs);
            },

            .store => |*p| {
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&p.dest);
                bounded_result.value.bounded_iterator.appendAssumeCapacity(&p.value);
            },
            .store_constant => |*p| bounded_result.value.bounded_iterator.appendAssumeCapacity(&p.dest),

            .copy => |*c| bounded_result.value.bounded_iterator.appendAssumeCapacity(c),
            .pick => |*p| bounded_result.value.bounded_iterator.appendAssumeCapacity(&p.src),
            .load => |*p| bounded_result.value.bounded_iterator.appendAssumeCapacity(&p.source),
            .@"if" => |*instr| bounded_result.value.bounded_iterator.appendAssumeCapacity(&instr.condition),
            .leave_function => |*value| bounded_result.value.bounded_iterator.appendAssumeCapacity(&value.value),

            .param_ref, .stack_ref, .global_ref, .function_ref,
            .load_int_constant, .load_bool_constant,
            .undefined, .goto, .enter_function,
            .@"unreachable",
            => {}, // No operands
        }

        return bounded_result;
    }

    pub fn memoryReference(self: *const @This()) ?MemoryReference {
        const self_index = decls.getIndex(@fieldParentPtr(Decl, "instr", self));
        switch(self.*) {
            .stack_ref => |sr| return .{
                .pointer_value = self_index,
                .pointer_value_offset = 0,
                .sema_pointer_type = sr.type,
            },
            .global_ref => |offref| return .{
                .pointer_value = self_index,
                .pointer_value_offset = 0,
                .sema_pointer_type = offref.type,
            },
            .reference_wrap => |rr| return .{
                .pointer_value = self_index,
                .pointer_value_offset = rr.pointer_value_offset,
                .sema_pointer_type = rr.sema_pointer_type,
            },
            else => return null,
        }
    }

    pub fn isVolatile(self: *const @This()) bool {
        switch(self.*) {
            .incomplete_phi => unreachable,
            .@"if", .leave_function, .goto, .enter_function, .store, .store_constant, .function_call, .function_ptr_call, .syscall,
            .inplace_add, .inplace_sub, .inplace_multiply, .inplace_divide, .inplace_modulus,
            .inplace_shift_left, .inplace_shift_right, .inplace_bit_and, .inplace_bit_or, .inplace_bit_xor,
            .inplace_add_constant, .inplace_sub_constant, .inplace_multiply_constant, .inplace_divide_constant, .inplace_modulus_constant,
            .inplace_shift_left_constant, .inplace_shift_right_constant, .inplace_bit_and_constant, .inplace_bit_or_constant, .inplace_bit_xor_constant,
            .@"unreachable",
            => return true,
            else => return false,
        }
    }

    pub fn numValues(self: *const @This()) RegIndex {
        switch(self.*) {
            .incomplete_phi => unreachable,
            .@"if", .leave_function, .goto, .stack_ref, .global_ref, .function_ref, .enter_function,
            .store, .store_constant, .reference_wrap,
            .inplace_add, .inplace_sub, .inplace_multiply, .inplace_divide, .inplace_modulus,
            .inplace_shift_left, .inplace_shift_right, .inplace_bit_and, .inplace_bit_or, .inplace_bit_xor,
            .inplace_add_constant, .inplace_sub_constant, .inplace_multiply_constant, .inplace_divide_constant, .inplace_modulus_constant,
            .inplace_shift_left_constant, .inplace_shift_right_constant, .inplace_bit_and_constant, .inplace_bit_or_constant, .inplace_bit_xor_constant,
            .tail_call, .@"unreachable",
            => return 0,
            else => return 1,
        }
    }

    pub fn isFlagsValue(self: *const @This()) bool {
        switch(self.*) {
            .less, .less_equal, .greater, .greater_equal, .equals, .not_equal,
            .less_constant, .less_equal_constant, .greater_constant,
            .greater_equal_constant, .equals_constant, .not_equal_constant,
            => return true,
            else => return false,
        }
    }

    pub fn outEdges(self: *@This()) std.BoundedArray(*BlockEdgeIndex.Index, 2) {
        var result = std.BoundedArray(*BlockEdgeIndex.Index, 2){};
        switch(self.*) {
            .incomplete_phi => unreachable,
            .@"if" => |*instr| {
                result.appendAssumeCapacity(&instr.taken);
                result.appendAssumeCapacity(&instr.not_taken);
            },
            .goto => |*out| result.appendAssumeCapacity(out),
            else => {}, // No out edges
        }
        return result;
    }

    pub fn getOperationType(self: *const @This()) InstrType {
        switch(self.*) {
            inline
            .param_ref, .load_int_constant, .load, .store_constant,
            .zero_extend, .sign_extend, .truncate,
            => |cast| return cast.type,
            .clobber => return .u64,
            .addr_of, .stack_ref, .global_ref, .function_ref,
            => return backends.current_backend.pointer_type,
            .reference_wrap => |rr| return rr.instrType(),
            .add, .sub, .multiply, .divide, .modulus,
            .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
            .inplace_add, .inplace_sub, .inplace_multiply, .inplace_divide, .inplace_modulus,
            .inplace_shift_left, .inplace_shift_right, .inplace_bit_and, .inplace_bit_or, .inplace_bit_xor,
            .less, .less_equal, .greater, .greater_equal, .equals, .not_equal,
            => |bop| {
                const lhs = decls.get(bop.lhs);
                const lhs_type = lhs.instr.getOperationType();
                const rhs = decls.get(bop.rhs);
                const rhs_type = rhs.instr.getOperationType();
                std.debug.assert(lhs_type == rhs_type);
                return lhs_type;
            },
            .function_call => |fcall| {
                const func = sema.values.get(fcall.callee.function_value).function;
                if(func.captures_return) return .u64;
                const rt = func.instantiations.items[fcall.callee.instantiation].return_type;
                return typeFor(sema.values.get(rt).type_idx);
            },
            .function_ptr_call => |fcall| return typeFor(fcall.sema_return_type),
            .tail_call => return .u64,
            .syscall, .undefined => return .u64,
            .store => |val| return decls.get(val.value).instr.getOperationType(),
            .add_constant, .sub_constant, .multiply_constant, .divide_constant, .modulus_constant,
            .shift_left_constant, .shift_right_constant, .bit_and_constant, .bit_or_constant, .bit_xor_constant,
            .inplace_add_constant, .inplace_sub_constant, .inplace_multiply_constant, .inplace_divide_constant, .inplace_modulus_constant,
            .inplace_shift_left_constant, .inplace_shift_right_constant, .inplace_bit_and_constant, .inplace_bit_or_constant, .inplace_bit_xor_constant,
            .less_constant, .less_equal_constant, .greater_constant, .greater_equal_constant, .equals_constant, .not_equal_constant,
            => |bop| return decls.get(bop.lhs).instr.getOperationType(),
            .negate, .copy => |op| return decls.get(op).instr.getOperationType(),
            .load_bool_constant, .logical_not => return .u8,
            .phi => |phi_operand| {
                // TODO:
                // Block#1:
                //   ...
                //   u64 $5 = 0
                //   ...
                // Block#3:
                //   u64 $8 = phi([$5, Block#1], [$19, Block#7])
                //   ...
                // Block#7:
                //   u64 $19 = add($8, #1)
                //   ...
                var curr_operand = phi_operand;
                // var first_type: InstrType = undefined;
                // var first_iter = true;
                while(phi_operands.getOpt(curr_operand)) |operand| : (curr_operand = operand.next) {
                    const operand_type = decls.get(operand.decl).instr.getOperationType();
                    return operand_type;
                    // if(first_iter) {
                    //     first_type = operand_type;
                    // } else if() {
                    //     std.debug.assert(operand_type == first_type);
                    // }
                }
                // std.debug.assert(!first_iter);
                // return first_type;
                return undefined;
            },
            else => |other| std.debug.panic("TODO getOperationType of {s}", .{@tagName(other)}),
        }
    }
};

pub const Decl = struct {
    next: DeclIndex.OptIndex = .none,
    prev: DeclIndex.OptIndex = .none,
    block: BlockIndex.Index,

    sema_decl: sema.DeclIndex.OptIndex,
    instr: DeclInstr,
    reg_alloc_value: [InstrMaxRegs]?u8 = std.mem.zeroes([InstrMaxRegs]?u8),
};

const InstructionToBlockEdge = struct {
    source_block: BlockIndex.Index,
    target_block: BlockIndex.Index,
    next: BlockEdgeIndex.OptIndex, // next incoming edge for the target block
};

const PhiOperand = struct {
    edge: BlockEdgeIndex.Index,
    decl: DeclIndex.Index,
    next: PhiOperandIndex.OptIndex = .none,
};

pub const BasicBlock = struct {
    is_sealed: bool = false,
    is_filled: bool = false,
    first_incomplete_phi_node: DeclIndex.OptIndex = .none,
    first_predecessor: BlockEdgeIndex.OptIndex = .none,
    first_decl: DeclIndex.OptIndex = .none,
    last_decl: DeclIndex.OptIndex = .none,

    pub fn seal(self: *@This()) !void {
        while(decls.getOpt(self.first_incomplete_phi_node)) |decl| {
            self.first_incomplete_phi_node = decl.instr.incomplete_phi;
            _ = try addPhiOperands(
                sema.DeclIndex.unwrap(decl.sema_decl).?,
                blocks.getIndex(self),
                decls.getIndex(decl),
                false,
            );
        }
        self.is_sealed = true;
    }

    pub fn filled(self: *@This()) !void {
        self.is_filled = true;
    }
};

// Name from paper
fn readVariable(block_idx: BlockIndex.Index, decl: sema.DeclIndex.Index) anyerror!DeclIndex.Index {
    const odecl = sema.DeclIndex.toOpt(decl);
    // Look backwards to find value in current basic block
    var pred_idx = blocks.get(block_idx).last_decl;
    while(decls.getOpt(pred_idx)) |pred| {
        if(pred.sema_decl == odecl) return decls.getIndex(pred);
        pred_idx = pred.prev;
    }
    return readVariableRecursive(block_idx, decl);
}

// Name from paper
fn readVariableRecursive(block_idx: BlockIndex.Index, decl: sema.DeclIndex.Index) !DeclIndex.Index {
    const odecl = sema.DeclIndex.toOpt(decl);
    const block = blocks.get(block_idx);
    if(!block.is_sealed) {
        const new_phi = try appendToBlock(block_idx, .{
            .incomplete_phi = block.first_incomplete_phi_node,
        });
        decls.get(new_phi).sema_decl = odecl;
        block.first_incomplete_phi_node = DeclIndex.toOpt(new_phi);
        return new_phi;
    } else {
        const first_predecessor = block.first_predecessor;
        const first_edge = edges.getOpt(first_predecessor) orelse {
            var token = try sema.decls.get(decl).name.retokenize();
            defer token.deinit();
            std.debug.panic("Internal compiler error: Failed to look up variable {s}\n", .{token.identifier_value()});
        };

        if(edges.getOpt(first_edge.next)) |_| {
            // Block gets new phi node
            const new_phi = try appendToBlock(block_idx, .{
                .incomplete_phi = undefined,
            });
            decls.get(new_phi).sema_decl = odecl;
            return addPhiOperands(decl, block_idx, new_phi, true);
        } else {
            return readVariable(first_edge.source_block, decl);
        }
    }
}

// Name from paper
fn addPhiOperands(sema_decl: sema.DeclIndex.Index, block_idx: BlockIndex.Index, phi_idx: DeclIndex.Index, delete: bool) !DeclIndex.Index {
    const block = blocks.get(block_idx);
    var current_pred_edge = block.first_predecessor;
    var init_operand = PhiOperandIndex.OptIndex.none;

    while(edges.getOpt(current_pred_edge)) |edge| {
        const eidx = edges.getIndex(edge);

        const new_operand = try phi_operands.insert(.{
            .edge = eidx,
            .decl = try readVariable(edge.source_block, sema_decl),
            .next = init_operand,
        });

        init_operand = PhiOperandIndex.toOpt(new_operand);
        current_pred_edge = edge.next;
    }

    decls.get(phi_idx).instr = .{.phi = init_operand};
    return tryRemoveTrivialPhi(phi_idx, delete);
}

pub fn removeDecl(decl_idx: DeclIndex.Index) void {
    const decl = decls.get(decl_idx);
    const block = blocks.get(decl.block);

    if(decls.getOpt(decl.prev)) |prev| {
        prev.next = decl.next;
    } else {
        block.first_decl = decl.next;
    }
    if(decls.getOpt(decl.next)) |next| {
        next.prev = decl.prev;
    } else {
        block.last_decl = decl.prev;
    }
    decls.free(decl_idx);
}

/// Name from paper
fn tryRemoveTrivialPhi(phi_decl: DeclIndex.Index, delete: bool) DeclIndex.Index {
    if(checkTrivialPhi(phi_decl)) |trivial_decl| {
        if(trivial_decl) |trivial_idx| {
            if(delete) {
                removeDecl(phi_decl);
                return trivial_idx;
            } else {
                decls.get(phi_decl).instr = .{.copy = trivial_idx};
            }
        } else {
            // This is zero operand phi node. What does it meme?
            decls.get(phi_decl).instr = .{.undefined = {}};
        }
    }

    return phi_decl;
}

// Name from paper
fn checkTrivialPhi(phi_decl: DeclIndex.Index) ??DeclIndex.Index {
    var current_operand = decls.get(phi_decl).instr.phi;
    var only_decl: ?DeclIndex.Index = null;

    while(phi_operands.getOpt(current_operand)) |op| : (current_operand = op.next) {
        if(op.decl == phi_decl) continue;
        switch(decls.get(op.decl).instr) {
            .undefined => continue,
            else => { },
        }
        if(only_decl) |only| {
            if(only != op.decl) return null;
        } else {
            only_decl = op.decl;
        }
    }

    return only_decl;
}

// Assumes an arena allocator is passed
const DiscoverContext = struct {
    to_visit: std.ArrayList(BlockIndex.Index),
    visited: std.AutoArrayHashMap(BlockIndex.Index, void),

    fn init(allocator: std.mem.Allocator, first_block: BlockIndex.Index) !@This() {
        var result: @This() = undefined;
        result.to_visit = std.ArrayList(BlockIndex.Index).init(allocator);
        try result.to_visit.append(first_block);
        result.visited = std.AutoArrayHashMap(BlockIndex.Index, void).init(allocator);
        try result.visited.put(first_block, {});
        return result;
    }

    fn nextBlock(self: *@This()) ?*BasicBlock {
        if(self.to_visit.items.len > 0) {
            return blocks.get(self.to_visit.swapRemove(0));
        } else {
            return null;
        }
    }

    fn edge(self: *@This(), eidx: BlockEdgeIndex.Index) !void {
        const target_idx = edges.get(eidx).target_block;
        if(self.visited.get(target_idx) == null) {
            try self.to_visit.append(target_idx);
            try self.visited.put(target_idx, {});
        }
    }

    fn finalize(self: *@This()) []BlockIndex.Index {
        return self.visited.keys();
    }
};

pub const BlockList = std.ArrayListUnmanaged(BlockIndex.Index);

// Assumes an arena allocator is passed
pub fn allBlocksReachableFrom(allocator: std.mem.Allocator, head_block: BlockIndex.Index) !BlockList {
    var context = try DiscoverContext.init(allocator, head_block);

    while(context.nextBlock()) |block| {
        for(decls.getOpt(block.last_decl).?.instr.outEdges().slice()) |edge| {
            try context.edge(edge.*);
        }
    }

    const elements = context.finalize();
    return BlockList{.items = elements, .capacity = elements.len};
}

const function_optimizations = .{
    eliminateUnreferenced,
    eliminateDeadBlocks,
    deduplicateDecls,
    eliminateDeadStackStores,
};

const peephole_optimizations = .{
    eliminateUnreachablePhiOperands,
    eliminateTrivialPhis,
    eliminateIfNots,
    eliminateConstantIfs,
    eliminateRedundantIfs,
    eliminateIndirectBranches,
    inlineConstants,
    eliminateTrivialArithmetic,
    eliminateConstantExpressions,
    eliminateOffsetPointers,
    eliminateDerefOfAddrOf,
    eliminateTrivialLoads,
    stopUsingCopies,
};

var optimization_allocator = std.heap.GeneralPurposeAllocator(.{}){.backing_allocator = std.heap.page_allocator};

pub fn optimizeFunction(head_block: BlockIndex.Index) !void {
    var arena = std.heap.ArenaAllocator.init(optimization_allocator.allocator());
    defer arena.deinit();
    var fn_blocks = try allBlocksReachableFrom(arena.allocator(), head_block);

    while(true) {
        var did_something = false;
        for(fn_blocks.items) |block| {
            var current_decl = blocks.get(block).first_decl;
            while(decls.getOpt(current_decl)) |decl| {
                current_decl = decl.next;
                inline for(peephole_optimizations) |pass| {
                    if(@typeInfo(@TypeOf(pass)).Fn.params.len == 2) {
                        if(try pass(decls.getIndex(decl), fn_blocks)) did_something = true;
                    } else {
                        if(try pass(decls.getIndex(decl))) did_something = true;
                    }
                }
            }
        }
        inline for(function_optimizations) |pass| {
            var pass_allocator = std.heap.ArenaAllocator.init(optimization_allocator.allocator());
            defer pass_allocator.deinit();
            if(try pass(pass_allocator.allocator(), &fn_blocks)) did_something = true;
        }
        if(!did_something) break;
    }

    for(fn_blocks.items) |block| {
        var current_decl = blocks.get(block).first_decl;
        while(decls.getOpt(current_decl)) |decl| : (current_decl = decl.next) {
            const decl_idx = decls.getIndex(decl);
            switch(decl.instr) {
                inline .divide_constant, .modulus_constant => |dc, tag| {
                    if(!@field(backends.current_backend.optimizations, "has_" ++ @tagName(tag))) {
                        const constant = try insertBefore(decl_idx, .{
                            .load_int_constant = .{.type = decl.instr.getOperationType(), .value = dc.rhs},
                        });
                        decl.instr = @unionInit(DeclInstr, @tagName(tag)[0..@tagName(tag).len - 9], .{.lhs = dc.lhs, .rhs = constant});
                    }
                },
                // TODO: Reenable tail call optimizations when we can detect if any arguments can point onto the stack
                // .function_call => |fc| blk: {
                //     var next_decl = decl.next;
                //     var leave_decl = DeclIndex.OptIndex.none;
                //     while(decls.getOpt(next_decl)) |next| {
                //         switch(next.instr) {
                //             .leave_function => {
                //                 leave_decl = next_decl;
                //                 break;
                //             },
                //             .goto => |edge| next_decl = blocks.get(edges.get(edge).target_block).first_decl,
                //             .undefined, .copy, .clobber => next_decl = next.next,
                //             else => break :blk,
                //         }
                //     }
                //     if(DeclIndex.unwrap(leave_decl)) |leave_decl_idx| {
                //         blocks.get(decl.block).last_decl = current_decl;
                //         decl.next = .none;
                //         decl.instr = .{.tail_call = .{
                //             .callee = fc.callee,
                //             .first_argument = fc.first_argument,
                //             .tail = leave_decl_idx,
                //         }};
                //     }
                // },
                else => {},
            }
        }
    }
}

fn eliminateDeadBlocks(alloc: std.mem.Allocator, fn_blocks: *BlockList) !bool {
    const new_blocks = try allBlocksReachableFrom(alloc, fn_blocks.items[0]);
    if(new_blocks.items.len == fn_blocks.items.len) return false;
    std.mem.copy(BlockIndex.Index, fn_blocks.items, new_blocks.items);
    fn_blocks.shrinkRetainingCapacity(new_blocks.items.len);
    return true;
}

fn deduplicateDecls(alloc: std.mem.Allocator, fn_blocks: *BlockList) !bool {
    var decl_dict = std.AutoHashMap(DeclInstr, DeclIndex.Index).init(alloc);

    var did_something = false;
    for(fn_blocks.items) |block| {
        var current_decl = blocks.get(block).first_decl;
        while(decls.getOpt(current_decl)) |decl| : (current_decl = decl.next) {
            switch(decl.instr) {
                .stack_ref, .global_ref, .addr_of,

                .add, .sub, .multiply, .divide, .modulus,
                .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
                .less, .less_equal, .greater, .greater_equal, .equals, .not_equal,

                .add_constant, .sub_constant, .multiply_constant, .divide_constant, .modulus_constant,
                .shift_left_constant, .shift_right_constant,
                .bit_and_constant, .bit_or_constant, .bit_xor_constant,
                => {
                    const value = try decl_dict.getOrPut(decl.instr);
                    if(value.found_existing) {
                        decl.instr = .{.copy = value.value_ptr.*};
                        did_something = true;
                    } else {
                        value.value_ptr.* = decls.getIndex(decl);
                    }
                },
                else => {},
            }
        }
    }
    return did_something;
}

fn eliminateDeadStackStores(alloc: std.mem.Allocator, fn_blocks: *BlockList) !bool {
    var stores_to_kill = std.AutoHashMap(u32, ?std.ArrayListUnmanaged(DeclIndex.Index)).init(alloc);
    var did_something = false;

    for(fn_blocks.items) |block| {
        var current_decl = blocks.get(block).first_decl;
        while(decls.getOpt(current_decl)) |decl| : (current_decl = decl.next) {
            switch(decl.instr) {
                .stack_ref => |sr| _ = try stores_to_kill.getOrPutValue(sr.orig_offset, .{}),
                inline .store, .store_constant => |store| {
                    const dest = decls.get(store.dest);
                    if(dest.instr == .stack_ref) {
                        if(stores_to_kill.getPtr(dest.instr.stack_ref.orig_offset).?.*) |*stores| try stores.append(alloc, decls.getIndex(decl));
                    }
                },
                else => {
                    var op_it = decl.instr.operands();
                    while(op_it.next()) |op_idx| {
                        const operand = decls.get(op_idx.*);
                        if(operand.instr == .stack_ref) {
                            if((try stores_to_kill.fetchPut(operand.instr.stack_ref.orig_offset, null)).?.value) |value| {
                                var stores_array = value;
                                stores_array.deinit(alloc);
                            }
                        }
                    }
                },
            }
        }
    }

    var value_it = stores_to_kill.valueIterator();
    while(value_it.next()) |value| {
        var stores_array = value.* orelse continue;
        for(stores_array.items) |decl_idx| {
            removeDecl(decl_idx);
            did_something = true;
        }
        stores_array.deinit(alloc);
    }

    return did_something;
}

fn eliminateUnreferenced(alloc: std.mem.Allocator, fn_blocks: *BlockList) !bool {
    var unreferenced = std.AutoHashMap(DeclIndex.Index, void).init(alloc);
    var referenced_undiscovered = std.AutoHashMap(DeclIndex.Index, void).init(alloc);

    for(fn_blocks.items) |block| {
        var current_decl = blocks.get(block).first_decl;
        while(decls.getOpt(current_decl)) |decl| {
            const idx = decls.getIndex(decl);
            current_decl = decl.next;
            if(!referenced_undiscovered.remove(idx) and !decl.instr.isVolatile()) {
                try unreferenced.put(idx, {});
            }

            var ops = decl.instr.operands();
            while(ops.next()) |op| {
                if(!unreferenced.remove(op.*)) {
                    try referenced_undiscovered.put(op.*, {});
                }
            }
        }
    }

    var it = unreferenced.keyIterator();
    var did_something = false;
    while(it.next()) |key| {
        removeDecl(key.*);
        did_something = true;
    }
    return did_something;
}

fn eliminateUnreachablePhiOperands(decl_idx: DeclIndex.Index, fn_blocks: BlockList) !bool {
    const decl = decls.get(decl_idx);
    if(decl.instr != .phi) return false;

    var did_something = false;
    var curr_head = &decl.instr.phi;
    while(phi_operands.getOpt(curr_head.*)) |op| {
        const edge = edges.get(op.edge);
        if(std.mem.indexOfScalar(BlockIndex.Index, fn_blocks.items, edge.source_block) == null) {
            curr_head.* = op.next;
            did_something = true;
        } else {
            curr_head = &op.next;
        }
    }

    return did_something;
}

fn eliminateTrivialPhis(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    if(decl.instr == .phi) {
        _ = tryRemoveTrivialPhi(decl_idx, false);
        return decl.instr != .phi;
    }
    return false;
}

fn eliminateIfNots(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);

    if(decl.instr != .@"if") return false;
    const instr = &decl.instr.@"if";

    switch(decls.get(instr.condition).instr) {
        .logical_not => |not_operand| {
            instr.condition = not_operand;
            std.mem.swap(BlockEdgeIndex.Index, &instr.taken, &instr.not_taken);
            return true;
        },
        else => return false,
    }
}

fn eliminateConstantIfs(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    if(decl.instr == .@"if") {
        const if_instr = decl.instr.@"if";
        const cond_decl = decls.get(if_instr.condition);

        switch(cond_decl.instr) {
            .load_bool_constant => |value| {
                decl.instr = .{.goto = if(value) if_instr.taken else if_instr.not_taken};
                return true;
            },
            else => {},
        }
    }
    return false;
}

fn eliminateRedundantIfs(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    if(decl.instr == .@"if") {
        const if_instr = decl.instr.@"if";
        const taken_edge = edges.get(if_instr.taken);
        const not_taken_edge = edges.get(if_instr.not_taken);
        if(taken_edge.target_block == not_taken_edge.target_block) {
            decl.instr = .{.goto = if_instr.taken};
            return true;
        }
    }
    return false;
}

fn eliminateIndirectBranches(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    var did_something = false;
    for(decl.instr.outEdges().slice()) |edge| {
        const target_edge = edges.get(edge.*);
        const target_block = blocks.get(target_edge.target_block);
        if(target_block.first_decl == target_block.last_decl) {
            const first_decl = decls.getOpt(target_block.first_decl) orelse continue;
            if(first_decl.instr == .goto) {
                const goto_edge = edges.get(first_decl.instr.goto);
                if(target_edge != goto_edge and target_block.first_predecessor == BlockEdgeIndex.toOpt(edge.*) and target_edge.next == .none) {
                    goto_edge.source_block = decl.block;
                    edge.* = first_decl.instr.goto;
                    first_decl.instr = .{.@"unreachable" = {}};
                    did_something = true;
                }
            }
        }
    }
    return did_something;
}

fn inlineConstants(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    switch(decl.instr) {
        // Commutative ops
        inline
        .add, .multiply,
        .inplace_add, .inplace_multiply,
        .bit_and, .bit_or, .bit_xor,
        .inplace_bit_and, .inplace_bit_or, .inplace_bit_xor,
        .equals, .not_equal,
        => |bop, tag| {
            const lhs = decls.get(bop.lhs).instr;
            if(lhs == .load_int_constant) {
                decl.instr = @unionInit(DeclInstr, @tagName(tag) ++ "_constant", .{
                    .lhs = bop.rhs,
                    .rhs = lhs.load_int_constant.value,
                });
                return true;
            }
            const rhs = decls.get(bop.rhs).instr;
            if(rhs == .load_int_constant) {
                decl.instr = @unionInit(DeclInstr, @tagName(tag) ++ "_constant", .{
                    .lhs = bop.lhs,
                    .rhs = rhs.load_int_constant.value,
                });
               return true;
            }
        },

        // Noncommutative ops
        inline
        .less, .less_equal, .greater, .greater_equal,
        .sub, .divide, .modulus,
        .inplace_sub,
        .shift_left, .shift_right,
        .inplace_shift_left, .inplace_shift_right,
        => |bop, tag| {
            const swapped_tag: ?[]const u8 = comptime switch(tag) {
                .less => "greater_equal",
                .less_equal => "greater",
                .greater => "less_equal",
                .greater_equal => "less",
                else => null,
            };

            const lhs = decls.get(bop.lhs).instr;
            if(swapped_tag != null and lhs == .load_int_constant) {
                decl.instr = @unionInit(DeclInstr, swapped_tag.? ++ "_constant", .{
                    .lhs = bop.rhs,
                    .rhs = lhs.load_int_constant.value,
                });
                return true;
            }

            const rhs = decls.get(bop.rhs).instr;
            if(rhs == .load_int_constant) {
                decl.instr = @unionInit(DeclInstr, @tagName(tag) ++ "_constant", .{
                    .lhs = bop.lhs,
                    .rhs = rhs.load_int_constant.value,
                });
               return true;
            }
        },

        .store => |store| {
            const value = decls.get(store.value).instr;
            if(value == .load_int_constant) {
                if(value.load_int_constant.value == 0 or backends.current_backend.optimizations.has_nonzero_constant_store) {
                    decl.instr = .{.store_constant = .{
                        .dest = store.dest,
                        .type = value.load_int_constant.type,
                        .value = value.load_int_constant.value,
                    }};
                    return true;
                }
            }
        },

        else => {},
    }
    return false;
}

fn eliminateTrivialArithmetic(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    switch(decl.instr) {
        .add => |bop| {
            if(bop.lhs == bop.rhs) {
                decl.instr = .{.multiply_constant = .{.lhs = bop.lhs, .rhs = 2}};
                return true;
            }
        },
        .bit_and, .bit_or => |bop| {
            if(bop.lhs == bop.rhs) {
                decl.instr = .{.copy = bop.lhs};
                return true;
            }
        },
        .bit_xor, .sub => |bop| {
            if(bop.lhs == bop.rhs) {
                decl.instr = .{.load_int_constant = .{
                    .type = decl.instr.getOperationType(),
                    .value = 0,
                }};
                return true;
            }
        },
        .logical_not => |op| {
            switch(decls.get(op).instr) {
                .equals => |bop| decl.instr = .{.not_equal = .{.lhs = bop.lhs, .rhs = bop.rhs}},
                .not_equal => |bop| decl.instr = .{.equals = .{.lhs = bop.lhs, .rhs = bop.rhs}},
                .less => |bop| decl.instr = .{.greater_equal = .{.lhs = bop.lhs, .rhs = bop.rhs}},
                .less_equal => |bop| decl.instr = .{.greater = .{.lhs = bop.lhs, .rhs = bop.rhs}},
                .greater => |bop| decl.instr = .{.less_equal = .{.lhs = bop.lhs, .rhs = bop.rhs}},
                .greater_equal => |bop| decl.instr = .{.less = .{.lhs = bop.lhs, .rhs = bop.rhs}},
                .logical_not => |uop| decl.instr = .{.copy = uop},
                .load_bool_constant => |b| decl.instr = .{.load_bool_constant = !b, },
                else => return false,
            }
            return true;
        },
        .equals, .not_equal => |bop| {
            if(bop.lhs == bop.rhs) {
                decl.instr = .{.load_bool_constant = decl.instr == .equals};
                return true;
            }
        },

        inline
        .add_constant, .sub_constant,
        .shift_left_constant, .shift_right_constant,
        => |*bop, tag| {
            if(bop.rhs == 0) {
                decl.instr = .{.copy = bop.lhs};
                return true;
            }
            const lhs_decl = decls.get(bop.lhs);
            if(std.meta.activeTag(lhs_decl.instr) == std.meta.activeTag(decl.instr)) {
                const lhs_instr = @field(lhs_decl.instr, @tagName(tag));
                bop.lhs = lhs_instr.lhs;
                bop.rhs +%= lhs_instr.rhs;
                return true;
            }
        },
        .bit_or_constant, .bit_xor_constant => |bop| {
            if(bop.rhs == 0) {
                decl.instr = .{.copy = bop.lhs};
                return true;
            }
        },
        .multiply_constant => |bop| {
            if(bop.rhs == 0) {
                decl.instr = .{.load_int_constant = .{
                    .type = decl.instr.getOperationType(),
                    .value = 0,
                }};
            } else if(bop.rhs == 1) {
                decl.instr = .{.copy = bop.lhs};
                return true;
            } else {
                const l2 = std.math.log2_int(u64, bop.rhs);
                if((@as(u64, 1) << l2) == bop.rhs) {
                    decl.instr = .{.shift_left_constant = .{.lhs = bop.lhs, .rhs = l2}};
                    return true;
                }
                const lhs_decl = decls.get(bop.lhs);
                switch(lhs_decl.instr) {
                    .multiply_constant => |op_bop| {
                        decl.instr.multiply_constant.lhs = op_bop.lhs;
                        decl.instr.multiply_constant.rhs *= op_bop.rhs;
                        return true;
                    },
                    else => {},
                }
            }
        },
        .divide_constant => |bop| {
            if(bop.rhs == 0) {
                decl.instr = .{.undefined = {}};
                return true;
            } else {
                const l2 = std.math.log2_int(u64, bop.rhs);
                if((@as(u64, 1) << l2) == bop.rhs) {
                    decl.instr = .{.shift_right_constant = .{.lhs = bop.lhs, .rhs = l2}};
                    return true;
                }
            }
        },
        .modulus_constant => |bop| {
            // TODO: check value against type size to optimize more
            if(bop.rhs == 0) {
                decl.instr = .{.undefined = {}};
                return true;
            } else {
                const l2 = std.math.log2_int(u64, bop.rhs);
                if((@as(u64, 1) << l2) == bop.rhs) {
                    decl.instr = .{.bit_and_constant = .{.lhs = bop.lhs, .rhs = bop.rhs - 1}};
                    return true;
                }
            }
        },
        .bit_and_constant => |bop| {
            // TODO: check value against type size to optimize more
            if(bop.rhs == 0) {
                decl.instr = .{.load_int_constant = .{
                    .type = decl.instr.getOperationType(),
                    .value = 0,
                }};
                return true;
            }
        },

        .reference_wrap => |*mr| {
            const pointer_value = decls.get(mr.pointer_value);
            switch(pointer_value.instr) {
                .add_constant => |bop| {
                    mr.pointer_value = bop.lhs;
                    mr.pointer_value_offset += @intCast(i32, bop.rhs);
                    return true;
                },
                .sub_constant => |bop| {
                    mr.pointer_value = bop.lhs;
                    mr.pointer_value_offset -= @intCast(i32, bop.rhs);
                    return true;
                },
                else => {},
            }
        },

        else => {},
    }

    return false;
}

fn eliminateConstantExpressions(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    switch(decl.instr) {
        .store => |store| {
            const value = decls.get(store.value);
            if(value.instr == .undefined) {
                decl.instr = .{.undefined = {}};
            }
        },
        inline
        .add_constant, .sub_constant, .multiply_constant, .divide_constant, .modulus_constant,
        .shift_left_constant, .shift_right_constant, .bit_and_constant, .bit_or_constant, .bit_xor_constant,
        => |bop, tag| {
            const lhs = decls.get(bop.lhs);
            if(lhs.instr == .load_int_constant) {
                decl.instr = .{.load_int_constant = .{
                    .type = decl.instr.getOperationType(),
                    .value = switch(tag) {
                        .add_constant => lhs.instr.load_int_constant.value +% bop.rhs,
                        .sub_constant => lhs.instr.load_int_constant.value -% bop.rhs,
                        .multiply_constant => lhs.instr.load_int_constant.value *% bop.rhs,
                        .divide_constant => lhs.instr.load_int_constant.value / bop.rhs,
                        .modulus_constant => lhs.instr.load_int_constant.value % bop.rhs,
                        .shift_left_constant => lhs.instr.load_int_constant.value << @intCast(u6, bop.rhs),
                        .shift_right_constant => lhs.instr.load_int_constant.value >> @intCast(u6, bop.rhs),
                        .bit_and_constant => lhs.instr.load_int_constant.value & bop.rhs,
                        .bit_or_constant => lhs.instr.load_int_constant.value | bop.rhs,
                        .bit_xor_constant => lhs.instr.load_int_constant.value ^ bop.rhs,
                        else => unreachable,
                    },
                }};
                return true;
            }
        },
        inline
        .less_constant, .less_equal_constant, .greater_constant, .greater_equal_constant,
        .equals_constant, .not_equal_constant,
        => |bop, tag| {
            const lhs = decls.get(bop.lhs);
            if(lhs.instr == .load_int_constant) {
                decl.instr = .{.load_bool_constant = switch(tag) {
                    .less_constant => lhs.instr.load_int_constant.value < bop.rhs,
                    .less_equal_constant => lhs.instr.load_int_constant.value <= bop.rhs,
                    .greater_constant => lhs.instr.load_int_constant.value > bop.rhs,
                    .greater_equal_constant => lhs.instr.load_int_constant.value >= bop.rhs,
                    .equals_constant => lhs.instr.load_int_constant.value == bop.rhs,
                    .not_equal_constant => lhs.instr.load_int_constant.value != bop.rhs,
                    else => unreachable,
                }};
                return true;
            }
        },
        else => {},
    }
    return false;
}

fn eliminateOffsetPointers(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);

    var offset: i32 = undefined;
    var operand: DeclIndex.Index = undefined;

    switch(decl.instr) {
        .add_constant => |op| {
            operand = op.lhs;
            offset = @intCast(i32, @bitCast(i64, op.rhs));
        },
        .sub_constant => |op| {
            operand = op.lhs;
            offset = @intCast(i32, -@bitCast(i64, op.rhs));
        },
        else => return false,
    }

    decl.instr = switch(decls.get(operand).instr) {
        .addr_of => |ao| switch(decls.get(ao).instr) {
            .stack_ref => |o| .{.addr_of = try insertBefore(decl_idx, .{.stack_ref = .{
                .orig_offset = o.orig_offset,
                .offset = o.offset -% @bitCast(u32, offset),
                .type = o.type,
            }})},
            .global_ref => |o| .{.addr_of = try insertBefore(decl_idx, .{.global_ref = .{
                .orig_offset = o.orig_offset,
                .offset = o.offset +% @bitCast(u32, offset),
                .type = o.type,
            }})},
            .reference_wrap => |o| .{.addr_of = try insertBefore(decl_idx, .{.reference_wrap = .{
                .pointer_value = o.pointer_value,
                .pointer_value_offset = o.pointer_value_offset +% offset,
                .sema_pointer_type = o.sema_pointer_type,
            }})},
            else => return false,
        },
        else => return false,
    };
    return true;
}

pub fn eliminateDerefOfAddrOf(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    if(decl.instr != .reference_wrap) return false;
    const ref_wrap = decl.instr.reference_wrap;
    const operand = decls.get(ref_wrap.pointer_value);
    if(operand.instr != .addr_of) return false;
    const new_instr: DeclInstr = switch(decls.get(operand.instr.addr_of).instr) {
        .stack_ref => |sr| .{.stack_ref = .{
            .offset = @intCast(u32, @intCast(i32, sr.offset) - ref_wrap.pointer_value_offset),
            .orig_offset = sr.orig_offset,
            .type = ref_wrap.sema_pointer_type,
        }},
        .global_ref => |gr| .{.global_ref = .{
            .offset = @intCast(u32, @intCast(i32, gr.offset) + ref_wrap.pointer_value_offset),
            .orig_offset = gr.orig_offset,
            .type = ref_wrap.sema_pointer_type,
        }},
        .reference_wrap => |rw| .{.reference_wrap = .{
            .pointer_value = rw.pointer_value,
            .pointer_value_offset = rw.pointer_value_offset + ref_wrap.pointer_value_offset,
            .sema_pointer_type = ref_wrap.sema_pointer_type,
        }},
        .copy => return false,
        else => unreachable,
    };
    decl.instr = new_instr;
    return true;
}

fn arePointersDeeplyEqual(lhs_mr: MemoryReference, rhs_mr: MemoryReference) bool {
    const lhs = decls.get(lhs_mr.pointer_value);
    const rhs = decls.get(rhs_mr.pointer_value);

    if(std.meta.activeTag(lhs.instr) != std.meta.activeTag(rhs.instr)) return false;
    if(lhs_mr.pointer_value == rhs_mr.pointer_value and lhs_mr.pointer_value_offset == rhs_mr.pointer_value_offset) return true;

    switch(lhs.instr) {
        .stack_ref => |sr| {
            const lhs_offset = @intCast(u32, @intCast(i32, sr.offset) - lhs_mr.pointer_value_offset);
            const rhs_offset = @intCast(u32, @intCast(i32, rhs.instr.stack_ref.offset) - rhs_mr.pointer_value_offset);
            return lhs_offset == rhs_offset;
        },
        .global_ref => |gr| {
            const lhs_offset = @intCast(u32, @intCast(i32, gr.offset) + lhs_mr.pointer_value_offset);
            const rhs_offset = @intCast(u32, @intCast(i32, rhs.instr.global_ref.offset) + rhs_mr.pointer_value_offset);
            return lhs_offset == rhs_offset;
        },
        else => return false,
    }
}

fn canPointersOverlap(lhs_mr: MemoryReference, rhs_mr: MemoryReference) !bool {
    const lhs = decls.get(lhs_mr.pointer_value);
    const rhs = decls.get(rhs_mr.pointer_value);

    if(std.meta.activeTag(lhs.instr) != std.meta.activeTag(rhs.instr)) return false;
    if(lhs_mr.pointer_value == rhs_mr.pointer_value and lhs_mr.pointer_value_offset == rhs_mr.pointer_value_offset) return true;

    switch(lhs.instr) {
        .stack_ref => |sr| {
            const rhs_sr = rhs.instr.stack_ref;
            const lhs_offset = @intCast(u32, @intCast(i32, sr.offset) - lhs_mr.pointer_value_offset);
            const rhs_offset = @intCast(u32, @intCast(i32, rhs_sr.offset) - rhs_mr.pointer_value_offset);
            if(lhs_offset - try sema.types.get(sr.type.child).getSize() >= rhs_offset) return false;
            if(rhs_offset - try sema.types.get(rhs_sr.type.child).getSize() >= lhs_offset) return false;
            return true;
        },
        .global_ref => |gr| {
            const rhs_gr = rhs.instr.global_ref;
            const lhs_offset = @intCast(u32, @intCast(i32, gr.offset) + lhs_mr.pointer_value_offset);
            const rhs_offset = @intCast(u32, @intCast(i32, rhs_gr.offset) + rhs_mr.pointer_value_offset);
            if(lhs_offset + try sema.types.get(gr.type.child).getSize() <= rhs_offset) return false;
            if(rhs_offset + try sema.types.get(rhs_gr.type.child).getSize() <= lhs_offset) return false;
            return true;
        },
        else => return true,
    }
}

pub fn eliminateTrivialLoads(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    switch(decl.instr) {
        .copy, .store, .store_constant, .load, .addr_of, .reference_wrap => return false,
        else => {},
    }

    var op_it = decl.instr.operands();
    var did_something = false;
    while(op_it.next()) |op_idx| {
        const operand = decls.get(op_idx.*);
        const mr = switch(operand.instr) {
            .load => |l| MemoryReference{
                .pointer_value = l.source,
                .pointer_value_offset = 0,
                .sema_pointer_type = .{
                    .is_const = true,
                    .is_volatile = false,
                    .child = switch(l.type) {
                        .u8 => .u8,
                        .u16 => .u16,
                        .u32 => .u32,
                        .u64 => .u64,
                    },
                },
            },
            else => |*i| i.memoryReference() orelse return false,
        };
        var current = decl.prev;
        while(decls.getOpt(current)) |it_decl| : (current = it_decl.prev) {
            const store_dest_mr = switch(it_decl.instr) {
                inline
                .store, .store_constant
                => |store| decls.get(store.dest).instr.memoryReference().?,
                else => if(it_decl.instr.isVolatile()) break else continue,
            };

            if(!arePointersDeeplyEqual(store_dest_mr, mr)) {
                if(try canPointersOverlap(store_dest_mr, mr)) break;
                continue;
            }

            if(it_decl.instr.getOperationType() != mr.instrType()) {
                if(@intFromEnum(mr.instrType()) < @intFromEnum(it_decl.instr.getOperationType())) {
                    op_idx.* = try insertBefore(op_idx.*, switch(it_decl.instr) {
                        .store => |store| .{.truncate = .{
                            .value = store.value,
                            .type = mr.instrType(),
                        }},
                        .store_constant => |store| .{.load_int_constant = .{
                            .value = switch(mr.instrType()) {
                                .u8 => @truncate(u8, store.value),
                                .u16 => @truncate(u16, store.value),
                                .u32 => @truncate(u32, store.value),
                                else => unreachable,
                            },
                            .type = mr.instrType(),
                        }},
                        else => unreachable,
                    });
                }
            } else {
                op_idx.* = try insertBefore(op_idx.*, switch(it_decl.instr) {
                    .store => |store| .{.copy = store.value},
                    .store_constant => |store| .{.load_int_constant = .{
                        .value = store.value,
                        .type = store.type,
                    }},
                    else => unreachable,
                });
            }

            did_something = true;
            break;
        }
    }

    return did_something;
}

fn stopUsingCopies(decl_idx: DeclIndex.Index) !bool {
    const decl = decls.get(decl_idx);
    if(decl.instr == .copy) return false;

    var did_something = false;
    var ops = decl.instr.operands();
    while(ops.next()) |op| {
        switch(decls.get(op.*).instr) {
            .copy => |c| op.* = c,
            else => {},
        }
    }
    return did_something;
}

pub fn insertBefore(before: DeclIndex.Index, instr: DeclInstr) !DeclIndex.Index {
    const retval = blk: {
        const bdecl = decls.get(before);

        break :blk try decls.insert(.{
            .next = DeclIndex.toOpt(before),
            .prev = bdecl.prev,
            .block = bdecl.block,
            .instr = instr,
            .sema_decl = .none,
        });
    };

    const bdecl = decls.get(before);
    const blk_idx = bdecl.block;
    const blk = blocks.get(blk_idx);

    bdecl.prev = DeclIndex.toOpt(retval);

    if(blk.first_decl == DeclIndex.toOpt(before)) {
        blk.first_decl = DeclIndex.toOpt(retval);
    } else {
        decls.getOpt(decls.get(retval).prev).?.next = DeclIndex.toOpt(retval);
    }

    return retval;
}

fn appendToBlock(
    block_idx: BlockIndex.Index,
    instr: DeclInstr,
) !DeclIndex.Index {
    const block = blocks.get(block_idx);

    if(block.is_filled) { // There is a branch from this block already
        return insertBefore(DeclIndex.unwrap(block.last_decl).?, instr);
    }

    const retval = try decls.insert(.{
        .block = block_idx,
        .instr = instr,
        .sema_decl = .none,
    });
    const oretval = DeclIndex.toOpt(retval);

    if(decls.getOpt(block.last_decl)) |last| {
        last.next = oretval;
        decls.get(retval).prev = block.last_decl;
    }
    block.last_decl = oretval;

    if(block.first_decl == .none) {
        block.first_decl = oretval;
    }

    return retval;
}

fn addEdge(
    source_idx: BlockIndex.Index,
    target_idx: BlockIndex.Index,
) !BlockEdgeIndex.Index {
    const target_block = blocks.get(target_idx);

    std.debug.assert(!target_block.is_sealed);

    const retval = try edges.insert(.{
        .source_block = source_idx,
        .target_block = target_idx,
        .next = target_block.first_predecessor,
    });

    target_block.first_predecessor = BlockEdgeIndex.toOpt(retval);

    return retval;
}

var function_stack_gpa = std.heap.GeneralPurposeAllocator(.{}){.backing_allocator = std.heap.page_allocator};

const IRWriter = struct {
    function_stack: std.ArrayListUnmanaged(sema.InstantiatedFunction) = .{},
    max_stack_usage: u32 = 0,
    current_stack_offset: u32 = 0,
    return_phi_node: DeclIndex.Index,
    basic_block: BlockIndex.Index,

    fn deinit(self: *@This()) void {
        std.debug.assert(self.function_stack.items.len == 0);
        self.function_stack.deinit(function_stack_gpa.allocator());
    }

    fn emit(self: *@This(), instr: DeclInstr) !DeclIndex.Index {
        return appendToBlock(self.basic_block, instr);
    }

    fn allocStackSpace(self: *@This(), space: u32, alignment: u32) u32 {
        self.current_stack_offset += alignment - 1;
        self.current_stack_offset &= ~@as(u32, alignment - 1);
        self.current_stack_offset += space;
        self.max_stack_usage = @max(self.max_stack_usage, self.current_stack_offset);
        return self.current_stack_offset;
    }

    fn attemptInlineFunctionPre(self: *@This(), function: sema.InstantiatedFunction) bool {
        const callee = sema.values.get(function.function_value);
        for(self.function_stack.items) |inst| {
            // Already on the writing stack, just call it instead to avoid infinite recursion
            if(std.meta.eql(function, inst)) return false;
        }
        // TODO: Check if function is small enough to be inlined unconditionally
        // TODO: Check whether or not function is called in multiple places
        if(!ast.functions.get(callee.function.ast_function).is_inline) return false;
        return true;
    }

    fn attemptInlineFunctionCommit(self: *@This(), function: sema.InstantiatedFunction) !DeclIndex.Index {
        const callee = sema.values.get(function.function_value);

        const return_block = try blocks.insert(.{});
        const return_phi = try appendToBlock(return_block, .{.phi = .none});

        const old_return_phi = self.return_phi_node;
        defer self.return_phi_node = old_return_phi;
        self.return_phi_node = return_phi;

        try self.function_stack.append(function_stack_gpa.allocator(), function);
        defer _ = self.function_stack.pop();

        const inst = callee.function.instantiations.items[function.instantiation];
        _ = try self.writeBlockStatement(inst.body.first_stmt);
        std.debug.assert(inst.return_type == .void or callee.function.captures_return or !inst.body.reaches_end);
        if(inst.body.reaches_end) {
            _ = try self.emit(.{.goto = try addEdge(self.basic_block, return_block)});
        }
        try blocks.get(return_block).seal();
        self.basic_block = return_block;
        return return_phi;
    }

    fn writeExpression(self: *@This(), expr_idx: sema.ExpressionIndex.Index) !DeclIndex.Index {
        switch(sema.expressions.get(expr_idx).*) {
            .value => |val_idx| return self.writeValue(val_idx),
            .assign => |ass| {
                // Evaluate rhs first because it makes more lifetime sense for assignment ops
                const rhs = try self.writeValue(ass.rhs);
                const rhs_decl = decls.get(rhs);

                switch(rhs_decl.instr) {
                    .function_call => |fc| {
                        if(sema.values.get(fc.callee.function_value).function.captures_return) {
                            return rhs;
                        }
                    },
                    else => {},
                }

                const rhs_value = if(rhs_decl.instr.memoryReference()) |mr|
                    try self.emit(mr.load()) else rhs;

                if(ass.lhs != .discard_underscore) {
                    const lhs_sema = sema.values.get(ass.lhs);
                    if(lhs_sema.* == .decl_ref) {
                        if(sema.decls.get(lhs_sema.decl_ref).offset == null) {
                            const new_rhs = try self.emit(.{.copy = rhs_value});
                            decls.get(new_rhs).sema_decl = sema.DeclIndex.toOpt(lhs_sema.decl_ref);
                            return undefined;
                        }
                    }
                    const lhs = try self.writeValue(ass.lhs);
                    const lhs_mr = decls.get(lhs).instr.memoryReference().?;
                    _ = try self.emit(lhs_mr.store(rhs_value));
                }
                return undefined;
            },
            inline
            .add, .sub, .multiply, .divide, .modulus,
            .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
            .less, .less_equal, .greater, .greater_equal, .equals, .not_equal,
            => |bop, tag| {
                return self.emit(@unionInit(DeclInstr, @tagName(tag), .{
                    .lhs = try self.writeValue(bop.lhs),
                    .rhs = try self.writeValue(bop.rhs),
                }));
            },
            .logical_not => |op| return self.emit(.{.logical_not = try self.writeValue(op)}),
            inline
            .add_eq, .sub_eq, .multiply_eq, .divide_eq, .modulus_eq,
            .shift_left_eq, .shift_right_eq, .bit_and_eq, .bit_or_eq, .bit_xor_eq,
            => |bop, tag| {
                const lhs = try self.writeValue(bop.lhs);
                const rhs = try self.writeValue(bop.rhs);
                const op_name = @tagName(tag)[0..@tagName(tag).len - 3];
                if((tag != .divide_eq and tag != .modulus_eq and decls.get(lhs).instr.memoryReference() == null) or !backends.current_backend.optimizations.has_inplace_ops) {
                    const retval = try self.emit(@unionInit(DeclInstr, op_name, .{.lhs = lhs, .rhs = rhs}));
                    if(sema.values.get(bop.lhs).* == .decl_ref) {
                        decls.get(retval).sema_decl = sema.DeclIndex.toOpt(sema.values.get(bop.lhs).decl_ref);
                    }
                    return retval;
                } else {
                    return self.emit(@unionInit(DeclInstr, "inplace_" ++ op_name, .{.lhs = lhs, .rhs = rhs}));
                }
            },
            .addr_of => |operand| {
                return self.emit(.{.addr_of = try self.writeValue(operand)});
            },
            .negate => |operand| {
                return self.emit(.{.negate = try self.writeValue(operand)});
            },
            .zero_extend => |cast| return self.emit(.{.zero_extend = .{
                .value = try self.writeValue(cast.value),
                .type = typeFor(cast.type),
            }}),
            .sign_extend => |cast| return self.emit(.{.sign_extend = .{
                .value = try self.writeValue(cast.value),
                .type = typeFor(cast.type),
            }}),
            .truncate => |cast| return self.emit(.{.truncate = .{
                .value = try self.writeValue(cast.value),
                .type = typeFor(cast.type),
            }}),
            .function_call => |fcall| {
                var builder = function_arguments.builder();
                var curr_arg = fcall.first_arg;
                const will_inline = fcall.callee != .runtime and
                    fcall.callee.instantiation.function_value != .syscall_func and
                    self.attemptInlineFunctionPre(fcall.callee.instantiation);
                while(sema.expressions.getOpt(curr_arg)) |arg| : (curr_arg = arg.function_arg.next) {
                    const farg = arg.function_arg;
                    var value = try self.writeValue(farg.value);
                    if(decls.get(value).instr.memoryReference()) |mr| {
                        value = try self.emit(mr.load());
                    }
                    const copy = try self.emit(.{.copy = value});
                    if(will_inline) {
                        decls.get(copy).sema_decl = sema.DeclIndex.toOpt(arg.function_arg.param_decl);
                    }
                    _ = try builder.insert(.{.value = copy });
                }
                if(fcall.callee == .instantiation and fcall.callee.instantiation.function_value == .syscall_func) {
                    return self.emit(.{.syscall = builder.first});
                } else if(will_inline) {
                    return self.attemptInlineFunctionCommit(fcall.callee.instantiation);
                }
                switch(fcall.callee) {
                    .instantiation => |inst| return self.emit(.{.function_call = .{.callee = inst, .first_argument = builder.first}}),
                    .runtime => |value| return self.emit(.{.function_ptr_call = .{
                        .callee = try self.writeValue(value),
                        .first_argument = builder.first,
                        .sema_return_type = sema.values.get(sema.types.get(sema.types.get(try sema.values.get(value).getType()).pointer.child).function.return_type).type_idx,
                    }}),
                }
            },
            .global => |offref| return self.emit(.{.global_ref = .{
                .orig_offset = offref.offset,
                .offset = offref.offset,
                .type = offref.type,
            }}),
            .deref => |sidx| {
                return self.emit(.{.reference_wrap = .{
                    .pointer_value = try self.writeValue(sidx),
                    .pointer_value_offset = 0,
                    .sema_pointer_type = sema.types.get(try sema.values.get(sidx).getType()).pointer,
                }});
            },
            .block => |blk| {
                // This will be a phi node with the break value in the future
                const undef = self.emit(.{.@"undefined" = {}});
                try self.writeBlockStatement(blk.first_stmt);
                return undef;
            },
            else => |expr| std.debug.panic("Unhandled ssaing of expr {s}", .{@tagName(expr)}),
        }
    }

    fn writeValue(self: *@This(), value_idx: sema.ValueIndex.Index) !DeclIndex.Index {
        switch(sema.values.get(value_idx).*) {
            .runtime => |rt| return self.writeExpression(sema.ExpressionIndex.unwrap(rt.expr).?),
            .decl_ref => |decl_idx| {
                const rdecl = sema.decls.get(decl_idx);
                const ref_t = sema.PointerType{
                    .is_const = !rdecl.mutable,
                    .is_volatile = false,
                    .child = try sema.values.get(rdecl.init_value).getType(),
                };
                if(rdecl.static) {
                    return self.emit(.{.global_ref = .{
                        .orig_offset = rdecl.offset.?,
                        .offset = rdecl.offset.?,
                        .type = ref_t,
                    }});
                } else if(rdecl.offset) |offset| {
                    return self.emit(.{.stack_ref = .{
                        .orig_offset = offset,
                        .offset = offset,
                        .type = ref_t,
                    }});
                } else {
                    return readVariable(self.basic_block, decl_idx);
                }
            },
            .comptime_int => |c| {
                return self.emit(.{.load_int_constant = .{
                    .value = @truncate(u64, @bitCast(u65, c)),
                    .type = .u64, // TODO
                }});
            },
            .bool => |b| return self.emit(.{.load_bool_constant = b}),
            .unsigned_int, .signed_int => |int| {
                // TODO: Pass value bit width along too
                return self.emit(.{.load_int_constant = .{
                    .value = @truncate(u64, @bitCast(u65, int.value)),
                    .type = typeForBits(int.bits),
                }});
            },
            .undefined => return self.emit(.{.undefined = {}}),
            .function => return self.emit(.{.function_ref = .{.function_value = value_idx, .instantiation = 0}}),
            else => |val| std.debug.panic("Unhandled ssaing of value {s}", .{@tagName(val)}),
        }
    }

    fn writeBlockStatementIntoBlock(
        self: *@This(),
        first_stmt: sema.StatementIndex.OptIndex,
        target_block: BlockIndex.Index
    ) !BlockIndex.Index {
        self.basic_block = target_block;
        try self.writeBlockStatement(first_stmt);
        return self.basic_block;
    }

    fn writeBlockStatement(self: *@This(), first_stmt: sema.StatementIndex.OptIndex) !void {
        var current_statement = first_stmt;
        while(sema.statements.getOpt(current_statement)) |stmt| : (current_statement = stmt.next) {
            switch(stmt.value) {
                .block => |b| {
                    // A freestanding block statement is part of the same basic block but with a different scope
                    // TODO: a new break target location
                    _ = try self.writeBlockStatement(b.first_stmt);
                },
                .declaration => |decl_idx| {
                    const decl = sema.decls.get(decl_idx);
                    std.debug.assert(!decl.static);
                    const init_value = sema.values.get(decl.init_value);

                    if(decl.offset) |*offset| {
                        const decl_type = sema.types.get(try init_value.getType());
                        offset.* = self.allocStackSpace(try decl_type.getSize(), try decl_type.getAlignment());
                    }

                    var value = try self.writeValue(decl.init_value);
                    if(decls.get(value).instr.memoryReference()) |mr| {
                        value = try self.emit(mr.load());
                    }
                    decls.get(value).sema_decl = sema.DeclIndex.toOpt(decl_idx);

                    switch(decls.get(value).instr) {
                        .function_call => |fc| {
                            if(sema.values.get(fc.callee.function_value).function.captures_return) {
                               continue;
                            }
                        },
                        else => {},
                    }

                    if(decl.offset) |offset| {
                        const stack_ref = try self.emit(.{.stack_ref = .{
                            .orig_offset = offset,
                            .offset = offset,
                            .type = .{
                                .is_const = !decl.mutable,
                                .is_volatile = false,
                                .child = try init_value.getType(),
                            },
                        }});
                        _ = try self.emit(.{.store = .{.dest = stack_ref, .value = value}});
                    }
                },
                .expression => |expr_idx| {
                    _ = try self.writeExpression(expr_idx);
                },
                .if_statement => |if_stmt| {
                    const condition_value = try self.writeValue(if_stmt.condition);

                    const if_branch = try self.emit(.{.@"if" = .{
                        .condition = condition_value,
                        .taken = undefined,
                        .not_taken = undefined,
                    }});
                    try blocks.get(self.basic_block).filled();

                    const taken_entry = try blocks.insert(.{});
                    const not_taken_entry = try blocks.insert(.{});
                    decls.get(if_branch).instr.@"if".taken = try addEdge(self.basic_block, taken_entry);
                    try blocks.get(taken_entry).seal();
                    decls.get(if_branch).instr.@"if".not_taken = try addEdge(self.basic_block, not_taken_entry);
                    try blocks.get(not_taken_entry).seal();

                    const if_exit = try blocks.insert(.{});
                    const taken_exit = try self.writeBlockStatementIntoBlock(if_stmt.taken.first_stmt, taken_entry);
                    if(if_stmt.taken.reaches_end) {
                        const taken_exit_branch = try self.emit(.{.goto = undefined});
                        decls.get(taken_exit_branch).instr.goto = try addEdge(taken_exit, if_exit);
                    }
                    try blocks.get(taken_exit).filled();

                    const not_taken_exit = try self.writeBlockStatementIntoBlock(if_stmt.not_taken.first_stmt, not_taken_entry);
                    if (if_stmt.not_taken.reaches_end) {
                        const not_taken_exit_branch = try self.emit(.{.goto = undefined});
                        decls.get(not_taken_exit_branch).instr.goto = try addEdge(not_taken_exit, if_exit);
                    }
                    try blocks.get(not_taken_exit).filled();
                    try blocks.get(if_exit).seal();

                    self.basic_block = if_exit;
                },
                .loop_statement => |loop| {
                    const loop_enter_branch = try self.emit(.{.goto = undefined});
                    const loop_body_entry = try blocks.insert(.{});
                    decls.get(loop_enter_branch).instr.goto = try addEdge(self.basic_block, loop_body_entry);
                    try blocks.get(self.basic_block).filled();

                    const exit_block = try blocks.insert(.{});
                    stmt.ir_block = BlockIndex.toOpt(exit_block);
                    const loop_body_end = try self.writeBlockStatementIntoBlock(loop.body.first_stmt, loop_body_entry);
                    try blocks.get(exit_block).seal();
                    if(loop.body.reaches_end) {
                        const loop_instr = try self.emit(.{.goto = undefined});
                        decls.get(loop_instr).instr.goto = try addEdge(loop_body_end, loop_body_entry);
                    }
                    try blocks.get(loop_body_end).filled();
                    try blocks.get(loop_body_entry).seal();

                    self.basic_block = exit_block;
                },
                .break_statement => |break_block| {
                    const goto_block = BlockIndex.unwrap(sema.statements.get(break_block).ir_block).?;
                    _ = try self.emit(.{.goto = try addEdge(self.basic_block, goto_block)});
                },
                .return_statement => |return_stmt| {
                    var value = if(sema.ValueIndex.unwrap(return_stmt)) |sema_value| blk: {
                        break :blk try self.writeValue(sema_value);
                    } else blk: {
                        break :blk try self.emit(.{.undefined = {}});
                    };

                    const phi_decl = decls.get(self.return_phi_node);
                    const exit_edge = try addEdge(self.basic_block, phi_decl.block);
                    phi_decl.instr.phi = PhiOperandIndex.toOpt(try phi_operands.insert(.{
                        .edge = exit_edge,
                        .decl = value,
                        .next = phi_decl.instr.phi,
                    }));

                    _ = try self.emit(.{.@"goto" = exit_edge});
                },
                .unreachable_statement => _ = try self.emit(.{.@"unreachable" = {}}),
            }
        }
    }
};

pub fn writeFunction(sema_func: sema.InstantiatedFunction) !BlockIndex.Index {
    const callee = &sema.values.get(sema_func.function_value).function;
    const func = &callee.instantiations.items[sema_func.instantiation];
    const first_basic_block = try blocks.insert(.{});
    const enter_decl = try appendToBlock(first_basic_block, .{.enter_function = undefined});
    try blocks.get(first_basic_block).seal();

    // Loop over function params and add references to them
    var curr_param = sema.scopes.get(func.param_scope).first_decl;
    while(sema.decls.getOpt(curr_param)) |decl| : (curr_param = decl.next) {
        if(decl.comptime_param) continue;
        const param = try appendToBlock(first_basic_block, .{
            .param_ref = .{
                .param_idx = decl.function_param_idx.?,
                .type = typeFor(try sema.values.get(decl.init_value).getType()),
            },
        });
        decls.get(param).sema_decl = curr_param;
    }

    const exit_block = try blocks.insert(.{});
    const phi = try appendToBlock(exit_block, .{.phi = .none});
    const exit_return = try appendToBlock(exit_block, .{.leave_function = .{.restore_stack = false, .value = phi}});

    var writer = IRWriter{
        .return_phi_node = phi,
        .basic_block = first_basic_block,
    };
    defer writer.deinit();
    try writer.function_stack.append(function_stack_gpa.allocator(), sema_func);
    defer _ = writer.function_stack.pop();
    try writer.writeBlockStatement(func.body.first_stmt);
    std.debug.assert(func.return_type == .void or callee.captures_return or !func.body.reaches_end);
    if(func.body.reaches_end) {
        _ = try writer.emit(.{.goto = try addEdge(writer.basic_block, exit_block)});
    }
    decls.get(enter_decl).instr.enter_function = (writer.max_stack_usage + 0xF) & ~@as(u32, 0xF);
    decls.get(exit_return).instr.leave_function.restore_stack = writer.max_stack_usage > 0;
    return first_basic_block;
}

pub fn dumpBlock(
    bb: BlockIndex.Index,
    uf: ?rega.UnionFind,
) !void {
    std.debug.print("Block#{d}:\n", .{@intFromEnum(bb)});
    var current_decl = blocks.get(bb).first_decl;
    while(decls.getOpt(current_decl)) |decl| : (current_decl = decl.next) {
        if(decls.getOpt(decl.next)) |next| {
            std.debug.assert(next.prev == current_decl);
        } else {
            std.debug.assert(blocks.get(bb).last_decl == current_decl);
        }
        if(decl.instr == .clobber) continue;
        std.debug.print("  ", .{});
        std.debug.print("${d}", .{@intFromEnum(current_decl)});
        const adecl = blk: { break :blk (uf orelse break :blk decl).findDeclByPtr(decl); };
        if(adecl != decl) {
            std.debug.print(" (-> ${d})", .{@intFromEnum(decls.getIndex(adecl))});
        }
        if(adecl.sema_decl != .none) {
            std.debug.print(" (sema decl ${d})", .{@intFromEnum(adecl.sema_decl)});
        }
        if(adecl.reg_alloc_value[0]) |reg| {
            std.debug.print(" ({s})", .{backends.current_backend.register_name(reg)});
        }
        std.debug.print(" = ", .{});
        if(decl.instr.numValues() == 1) {
            std.debug.print("{s} ", .{@tagName(decl.instr.getOperationType())});
        }
        switch(decl.instr) {
            .param_ref => |p| std.debug.print("param({d})\n", .{p.param_idx}),
            .stack_ref => |p| std.debug.print("stack({d})\n", .{p.offset}),
            .global_ref => |p| std.debug.print("global({d})\n", .{p.offset}),
            .function_ref => |p| std.debug.print("function(${d}#{d})\n", .{@intFromEnum(p.function_value), p.instantiation}),
            .addr_of => |p| std.debug.print("addr_of(${d})\n", .{@intFromEnum(p)}),
            .enter_function => |stack_size| std.debug.print("enter_function({d})\n", .{stack_size}),
            .leave_function => |leave| std.debug.print("leave_function(${d})\n", .{@intFromEnum(leave.value)}),
            .load_int_constant => |value| std.debug.print("{d}\n", .{value.value}),
            .reference_wrap => |ref| std.debug.print("deref(${d}, #{d})\n", .{@intFromEnum(ref.pointer_value), ref.pointer_value_offset}),
            .zero_extend, .sign_extend, .truncate => |cast| std.debug.print("{s}(${d})\n", .{@tagName(decl.instr), @intFromEnum(cast.value)}),
            .load_bool_constant => |b| std.debug.print("{}\n", .{b}),
            .undefined => std.debug.print("undefined\n", .{}),
            .@"unreachable" => std.debug.print("unreachable\n", .{}),
            .load => |p| std.debug.print("load(${d})\n", .{@intFromEnum(p.source)}),
            .clobber => |op| std.debug.print("clobber(${d})\n", .{@intFromEnum(op)}),
            .negate => |op| std.debug.print("-(${d})\n", .{@intFromEnum(op)}),
            .logical_not => |op| std.debug.print("not(${d})\n", .{@intFromEnum(op)}),
            inline
            .add, .sub, .multiply, .divide, .modulus,
            .shift_left, .shift_right, .bit_and, .bit_or, .bit_xor,
            .inplace_add, .inplace_sub, .inplace_multiply, .inplace_divide, .inplace_modulus,
            .inplace_shift_left, .inplace_shift_right, .inplace_bit_and, .inplace_bit_or, .inplace_bit_xor,
            .less, .less_equal, .greater, .greater_equal, .equals, .not_equal,
            => |bop, tag| std.debug.print("{s}(${d}, ${d})\n", .{@tagName(tag), @intFromEnum(bop.lhs), @intFromEnum(bop.rhs)}),
            inline
            .add_constant, .sub_constant, .multiply_constant, .divide_constant, .modulus_constant,
            .shift_left_constant, .shift_right_constant, .bit_and_constant, .bit_or_constant, .bit_xor_constant,
            .inplace_add_constant, .inplace_sub_constant, .inplace_multiply_constant, .inplace_divide_constant, .inplace_modulus_constant,
            .inplace_shift_left_constant, .inplace_shift_right_constant, .inplace_bit_and_constant, .inplace_bit_or_constant, .inplace_bit_xor_constant,
            .less_constant, .less_equal_constant, .greater_constant, .greater_equal_constant, .equals_constant, .not_equal_constant,
            => |bop, tag| std.debug.print("{s}(${d}, #{d})\n", .{@tagName(tag)[0..@tagName(tag).len-9], @intFromEnum(bop.lhs), bop.rhs}),
            .function_call => |fc| {
                var name: ?ast.SourceRef = null;
                for(sema.decls.elements.items) |decl_it| {
                    if(decl_it.init_value == fc.callee.function_value) {
                        name = decl_it.name;
                        break;
                    }
                }
                std.debug.print("call({s}", .{try name.?.toSlice()});
                var ops = decl.instr.operands();
                while(ops.next()) |op| {
                    std.debug.print(", ${d}", .{@intFromEnum(op.*)});
                }
                std.debug.print(")\n", .{});
            },
            .function_ptr_call => {
                std.debug.print("call(<ptr>", .{});
                var ops = decl.instr.operands();
                while(ops.next()) |op| {
                    std.debug.print(", ${d}", .{@intFromEnum(op.*)});
                }
                std.debug.print(")\n", .{});
            },
            .tail_call => |fc| {
                var name: ?ast.SourceRef = null;
                for(sema.decls.elements.items) |decl_it| {
                    if(decl_it.init_value == fc.callee.function_value) {
                        name = decl_it.name;
                        break;
                    }
                }
                std.debug.print("tail_call({s}", .{try name.?.toSlice()});
                var ops = decl.instr.operands();
                while(ops.next()) |op| {
                    std.debug.print(", ${d}", .{@intFromEnum(op.*)});
                }
                std.debug.print(")\n", .{});
            },
            .syscall => {
                std.debug.print("syscall(", .{});
                var first = true;
                var ops = decl.instr.operands();
                while(ops.next()) |op| {
                    if (!first) {
                        std.debug.print(", ", .{});
                    }
                    std.debug.print("${d}", .{@intFromEnum(op.*)});
                    first = false;
                }
                std.debug.print(")\n", .{});
            },
            .store => |store| std.debug.print("store(${d}, ${d})\n", .{@intFromEnum(store.dest), @intFromEnum(store.value)}),
            .store_constant => |store| std.debug.print("store(${d}, #{d})\n", .{@intFromEnum(store.dest), store.value}),
            .incomplete_phi => std.debug.print("<incomplete phi node>\n", .{}),
            .copy => |c| std.debug.print("copy(${d})\n", .{@intFromEnum(c)}),
            .pick => |p| std.debug.print("pick(${d}#{d})\n", .{@intFromEnum(p.src), p.idx}),
            .@"if" => |if_instr| {
                std.debug.print("if(${d}, Block#{d}, Block#{d})\n", .{
                    @intFromEnum(if_instr.condition),
                    @intFromEnum(edges.get(if_instr.taken).target_block),
                    @intFromEnum(edges.get(if_instr.not_taken).target_block),
                });
            },
            .goto => |goto_edge| {
                std.debug.print("goto(Block#{d})\n", .{@intFromEnum(edges.get(goto_edge).target_block)});
            },
            .phi => |phi_index| {
                var current_phi = phi_index;
                std.debug.print("phi(", .{});
                while(phi_operands.getOpt(current_phi)) |phi| {
                    const edge = edges.get(phi.edge);
                    std.debug.print("[${d}, Block#{d}]", .{@intFromEnum(phi.decl), @intFromEnum(edge.source_block)});
                    if(phi.next != .none) {
                        std.debug.print(", ", .{});
                    }
                    current_phi = phi.next;
                }
                std.debug.print(")\n", .{});
            },
        }
    }
    std.debug.print("\n", .{});
}

pub var decls: DeclIndex.List(Decl) = undefined;
pub var blocks: BlockIndex.List(BasicBlock) = undefined;
pub var edges: BlockEdgeIndex.List(InstructionToBlockEdge) = undefined;
pub var phi_operands: PhiOperandIndex.List(PhiOperand) = undefined;
pub var function_arguments: FunctionArgumentIndex.List(FunctionArgument) = undefined;

pub fn init() !void {
    decls = try DeclIndex.List(Decl).init(std.heap.page_allocator);
    blocks = try BlockIndex.List(BasicBlock).init(std.heap.page_allocator);
    edges = try BlockEdgeIndex.List(InstructionToBlockEdge).init(std.heap.page_allocator);
    phi_operands = try PhiOperandIndex.List(PhiOperand).init(std.heap.page_allocator);
    function_arguments = try FunctionArgumentIndex.List(FunctionArgument).init(std.heap.page_allocator);
}
