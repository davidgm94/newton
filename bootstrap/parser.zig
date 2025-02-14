const std = @import("std");

const ast = @import("ast.zig");
const sources = @import("sources.zig");
const tokenizer = @import("tokenizer.zig");

fn errorType(comptime f: anytype) type {
    const f_type = if(@TypeOf(f) == type) f else @TypeOf(f);
    const ret_type = @typeInfo(f_type).Fn.return_type.?;
    return @typeInfo(ret_type).ErrorUnion.error_set;
}

source_file_index: sources.SourceIndex.Index,
peeked_token: ?tokenizer.Token = null,
current_content: [*:0]const u8,

fn expect(
    self: *@This(),
    comptime token_tag: std.meta.Tag(tokenizer.Token),
) !std.meta.TagPayload(tokenizer.Token, token_tag) {
    const tok = try self.peekToken();
    errdefer tok.deinit();
    if(tok == token_tag) {
        //std.debug.assert(tok == try self.tokenize());
        self.peeked_token = null;
        return @field(tok, @tagName(token_tag));
    } else {
        std.debug.print("Expected {s}, found {s}\n", .{@tagName(token_tag), @tagName(tok)});
        return error.UnexpectedToken;
    }
}

fn tryConsume(
    self: *@This(),
    comptime token_tag: std.meta.Tag(tokenizer.Token),
) !?std.meta.TagPayload(tokenizer.Token, token_tag) {
    const tok = try self.peekToken();
    if(tok == token_tag) {
        //std.debug.assert(tok == try self.tokenize());
        self.peeked_token = null;
        return @field(tok, @tagName(token_tag));
    } else {
        tok.deinit();
        return null;
    }
}

fn tokenize(self: *@This()) !tokenizer.Token {
    const retval = self.peekToken();
    self.peeked_token = null;
    return retval;
}

fn peekToken(self: *@This()) !tokenizer.Token {
    if(self.peeked_token == null) {
        self.peeked_token = try tokenizer.tokenize(&self.current_content);
    }
    return self.peeked_token.?;
}

fn identToAstNode(self: *@This(), tok: anytype) !ast.ExprIndex.Index {
    if(std.mem.eql(u8, tok.body, "u8")) return .u8;
    if(std.mem.eql(u8, tok.body, "u16")) return .u16;
    if(std.mem.eql(u8, tok.body, "u32")) return .u32;
    if(std.mem.eql(u8, tok.body, "u64")) return .u64;
    if(std.mem.eql(u8, tok.body, "i8")) return .i8;
    if(std.mem.eql(u8, tok.body, "i16")) return .i16;
    if(std.mem.eql(u8, tok.body, "i32")) return .i32;
    if(std.mem.eql(u8, tok.body, "i64")) return .i64;
    if(std.mem.eql(u8, tok.body, "bool")) return .bool;
    if(std.mem.eql(u8, tok.body, "type")) return .type;
    if(std.mem.eql(u8, tok.body, "void")) return .void;
    if(std.mem.eql(u8, tok.body, "noreturn")) return .noreturn;
    if(std.mem.eql(u8, tok.body, "anyopaque")) return .anyopaque;

    inline for(@typeInfo(ast.BuiltinFunction).Enum.fields) |ef| {
        if(std.mem.eql(u8, tok.body, "@" ++ ef.name)) {
            return ast.expressions.addDedupLinear(.{.builtin_function = @enumFromInt(ast.BuiltinFunction, ef.value)});
        }
    }

    return ast.expressions.insert(.{ .identifier = self.toAstIdent(tok) });
}

fn checkDecl(ident_expr_idx: ast.ExprIndex.Index) !void {
    if(@intFromEnum(ident_expr_idx) < @intFromEnum(ast.ExprIndex.OptIndex.none))
        return error.ReservedIdentifier;
}

fn toAstIdent(self: *@This(), tok: anytype) ast.SourceRef {
    const source_file = sources.source_files.get(self.source_file_index);

    const base_ptr = @intFromPtr(source_file.contents.ptr);
    const offset_ptr = @intFromPtr(tok.body.ptr);
    const file_offset = offset_ptr - base_ptr;

    return .{
        .file_offset = @intCast(u32, file_offset),
        .source_file = self.source_file_index,
    };
}

// Starts parsing at the parameter list
//   fn abc(123) T {}
//         ^ Here
// or
//   fn(123) T {}
//     ^ Here
fn parseFunctionExpr(self: *@This()) anyerror!ast.FunctionIndex.Index {
    _ = try self.expect(.@"(_ch");

    var param_builder = ast.function_params.builder();
    while((try self.peekToken()) != .@")_ch") {
        const is_comptime = (try self.tryConsume(.comptime_keyword)) != null;
        var ident: ?ast.SourceRef = null;
        if((try self.peekToken()) == .identifier) {
            const old_self = self.*;
            const maybe_ident = try self.expect(.identifier);
            defer maybe_ident.deinit();
            if ((try self.tryConsume(.@":_ch")) != null) {
                ident = self.toAstIdent(maybe_ident);
            } else {
                self.* = old_self;
            }
        }
        _ = try param_builder.insert(.{
            .identifier = ident,
            .type = try self.parseExpression(null),
            .is_comptime = is_comptime,
        });

        if((try self.tryConsume(.@",_ch")) == null) break;
    }

    _ = try self.expect(.@")_ch");

    const is_inline = (try self.tryConsume(.inline_keyword)) != null;
    const return_location = blk: {
        if((try self.tryConsume(.@"|_ch")) == null) break :blk null;
        const ident = try self.expect(.identifier);
        _ = try self.expect(.@"|_ch");
        break :blk self.toAstIdent(ident);
    };
    const return_type = try self.parseExpression(0);

    return ast.functions.insert(.{
        .first_param = param_builder.first,
        .return_type = return_type,
        .body = if((try self.peekToken()) == .@"{_ch") try self.parseBlockStatement() else ast.StmtIndex.OptIndex.none,
        .return_location = return_location,
        .is_inline = is_inline,
    });
}

fn parseBlockExpression(self: *@This(), block_label: ast.ExprIndex.OptIndex) anyerror!ast.ExprIndex.Index {
    const block = try self.parseBlockStatementBody();
    _ = try self.expect(.@"}_ch");
    return ast.expressions.insert(.{.block_expression = .{
        .block = block,
        .label = block_label,
    }});
}

// {
//   ^ Call this after open curly
//   var a = 5;
//   ^ Returns first statement in block
//   Next chain contains rest of the statements
// }
fn parseBlockStatementBody(self: *@This()) anyerror!ast.StmtIndex.OptIndex {
    var stmt_builder = ast.statements.builder();
    while((try self.peekToken()) != .@"}_ch") {
        stmt_builder.insertIndex(try self.parseStatement());
    }
    return stmt_builder.first;
}

fn parseBlockStatement(self: *@This()) anyerror!ast.StmtIndex.OptIndex {
    _ = try self.expect(.@"{_ch");
    const body = try self.parseBlockStatementBody();
    _ = try self.expect(.@"}_ch");
    return body;
}

fn parseStatement(self: *@This()) anyerror!ast.StmtIndex.Index {
    const token = try self.peekToken();
    switch(token) {
        .@"{_ch" => {
            return ast.statements.insert(.{.value = .{
                .block_statement = .{.first_child = try self.parseBlockStatement()},
            }});
        },
        .break_keyword => {
            _ = try self.tokenize();
            if(try self.tryConsume(.@":_ch")) |_| {
                @panic("TODO: Break labels");
            }
            const break_value = if((try self.peekToken()) != .@";_ch")
                ast.ExprIndex.toOpt(try self.parseExpression(0)) else .none;
            _ = try self.expect(.@";_ch");
            return ast.statements.insert(.{.value = .{ .break_statement = .{
                .value = break_value,
            }}});
        },
        .case_keyword => @panic("TODO: case statement"),
        .const_keyword, .var_keyword => return self.parseDeclaration(token),
        .continue_keyword => @panic("TODO: continue statement"),
        .endcase_keyword => @panic("TODO: endcase statement"),
        .unreachable_keyword => {
            _ = try self.tokenize();
            _ = try self.expect(.@";_ch");
            return ast.statements.insert(.{.value = .unreachable_statement});
        },
        .if_keyword => {
            _ = try self.tokenize();
            _ = try self.expect(.@"(_ch");
            const condition = try self.parseExpression(null);
            _ = try self.expect(.@")_ch");
            const first_taken = try self.parseBlockStatement();
            const first_not_taken = if((try self.peekToken()) == .else_keyword) blk: {
                _ = try self.tokenize();
                break :blk switch(try self.peekToken()) {
                    .@"{_ch" => try self.parseBlockStatement(),
                    .if_keyword => ast.StmtIndex.toOpt(try self.parseStatement()),
                    else => |inner_tok| {
                        std.debug.print("Expected `{{` or `if` after `else`, got {s}\n", .{@tagName(inner_tok)});
                        return error.UnexpectedToken;
                    },
                };
            } else .none;
            return ast.statements.insert(.{.value = .{
                .if_statement = .{
                    .condition = condition,
                    .first_taken = first_taken,
                    .first_not_taken = first_not_taken,
                },
            }});
        },
        .loop_keyword => {
            _ = try self.tokenize();
            const condition = if ((try self.peekToken()) == .@"(_ch") blk: {
                _ = try self.tokenize();
                const res = try self.parseExpression(null);
                _ = try self.expect(.@")_ch");
                break :blk ast.ExprIndex.toOpt(res);
            } else .none;
            const body = try self.parseBlockStatement();
            return ast.statements.insert(.{.value = .{
                .loop_statement = .{
                    .condition = condition,
                    .first_child = body,
                },
            }});
        },
        .return_keyword => {
            var expr = ast.ExprIndex.OptIndex.none;
            _ = try self.tokenize();
            if((try self.peekToken()) != .@";_ch") {
                expr = ast.ExprIndex.toOpt(try self.parseExpression(null));
            }
            _ = try self.expect(.@";_ch");
            return ast.statements.insert(.{.value = .{.return_statement = .{.expr = expr}}});
        },
        .switch_keyword => @panic("TODO: switch statement"),
        .identifier, .__keyword, .@"(_ch",
        => { // Expression statement
            const expr_idx = try self.parseExpression(null);
            _ = try self.expect(.@";_ch");
            return ast.statements.insert(.{.value = .{.expression_statement = .{.expr = expr_idx}}});
        },
        .comptime_keyword => @panic("TODO: Comptime statement"),

        inline
        .int_literal, .char_literal, .string_literal, .@".{_ch",
        .@".._ch", .@"._ch", .@",_ch", .@":_ch",
        .@"++_ch", .@"++=_ch", .@"=_ch", .@";_ch",
        .@"+_ch", .@"+=_ch", .@"-_ch", .@"-=_ch", .@"*_ch", .@"*=_ch",
        .@"/_ch", .@"/=_ch", .@"%_ch", .@"%=_ch",
        .@"}_ch", .@")_ch", .@"[_ch", .@"]_ch",
        .@"==_ch", .@"!=_ch",
        .@"<_ch", .@"<<_ch", .@"<=_ch", .@"<<=_ch",
        .@">_ch", .@">>_ch", .@">=_ch", .@">>=_ch",
        .@"|_ch", .@"|=_ch", .@"&_ch", .@"&=_ch",
        .@"^_ch", .@"^=_ch", .@"~_ch", .@"!_ch",
        .@"||_ch", .@"&&_ch",
        .end_of_file, .else_keyword, .enum_keyword, .fn_keyword,
        .struct_keyword, .bool_keyword, .type_keyword, .void_keyword,
        .anyopaque_keyword, .volatile_keyword, .true_keyword, .false_keyword, .undefined_keyword,
        .inline_keyword, .noreturn_keyword,
        => |_, tag| {
            std.debug.print("Unexpected statement token: {s}\n", .{@tagName(tag)});
            return error.UnexpectedToken;
        },
    }
}

fn parseTypeInitList(self: *@This(), specified_type: ast.ExprIndex.OptIndex) anyerror!ast.ExprIndex.Index {
    var builder = ast.type_init_values.builder();

    switch(try self.peekToken()) {
        .@"._ch" => { // Nonempty struct literal
            while((try self.peekToken()) != .@"}_ch") {
                _ = try self.expect(.@"._ch");
                var ident = try self.expect(.identifier);
                defer ident.deinit();
                _ = try self.expect(.@"=_ch");
                _ = try builder.insert(.{
                    .identifier = self.toAstIdent(ident),
                    .value = try self.parseExpression(null),
                });
                if((try self.tryConsume(.@",_ch")) == null) break;
            }
            try self.expect(.@"}_ch");
        },
        // .@"}_ch" => {}, // Empty tuple
        else => { // Nonempty tuple
            while((try self.peekToken()) != .@"}_ch") {
                _ = try builder.insert(.{
                    .identifier = null,
                    .value = try self.parseExpression(null),
                });
                if((try self.tryConsume(.@",_ch")) == null) break;
            }
            try self.expect(.@"}_ch");
        },
    }

    return ast.expressions.insert(.{.type_init_list = .{
        .specified_type = specified_type,
        .first_value = builder.first,
    }});
}

fn parseExpression(self: *@This(), precedence_in: ?usize) anyerror!ast.ExprIndex.Index {
    const precedence = precedence_in orelse 99999;

    var lhs: ast.ExprIndex.Index = switch(try self.tokenize()) {
        // Literals
        .int_literal => |lit| try ast.expressions.insert(.{.int_literal = self.toAstIdent(lit)}),
        .char_literal => |lit| try ast.expressions.insert(.{.char_literal = self.toAstIdent(lit)}),
        .string_literal => |lit| try ast.expressions.insert(.{.string_literal = self.toAstIdent(lit)}),
        .true_keyword => try ast.expressions.insert(.{.bool_literal = true}),
        .false_keyword => try ast.expressions.insert(.{.bool_literal = false}),

        // Atom keyword literal expressions
        .void_keyword => .void,
        .bool_keyword => .bool,
        .type_keyword => .type,
        .anyopaque_keyword => .anyopaque,
        .noreturn_keyword => .noreturn,
        .undefined_keyword => .undefined,

        // Control flow expressions
        .break_keyword => @panic("TODO: Break expressions"),
        .continue_keyword => @panic("TODO: Continue expressions"),
        .endcase_keyword => @panic("TODO: Endcase expressions"),
        .if_keyword => @panic("TODO: If expressions"),
        .loop_keyword => @panic("TODO: Loop expressions"),
        .switch_keyword => @panic("TODO: Switch expressions"),
        .unreachable_keyword => return .@"unreachable",

        .@"[_ch" => blk: {
            const size = try self.parseExpression(null);
            _ = try self.expect(.@"]_ch");
            const child_type = try self.parseExpression(0);

            break :blk try ast.expressions.insert(.{ .array_type = .{
                .lhs = size,
                .rhs = child_type,
            }});
        },

        .comptime_keyword => return ast.expressions.insert(.{.force_comptime_eval = .{
            .operand = try self.parseExpression(0),
        }}),

        // Type expressions
        .enum_keyword => @panic("TODO: Enum type expression"),
        .struct_keyword => blk: {
            _ = try self.expect(.@"{_ch");

            const user_type = try ast.expressions.insert(.{ .struct_expression = .{
                .first_decl = try self.parseTypeBody(),
            }});

            _ = try self.expect(.@"}_ch");

            break :blk user_type;
        },

        .fn_keyword => blk: {
            const fidx = try self.parseFunctionExpr();
            break :blk try ast.expressions.insert(.{ .function_expression = fidx });
        },

        .@"(_ch" => blk: {
            const expr = try self.parseExpression(null);
            _ = try self.expect(.@")_ch");
            break :blk try ast.expressions.insert(.{ .parenthesized = .{ .operand = expr }});
        },

        inline
        .@"+_ch", .@"-_ch", .@"~_ch", .@"!_ch",
        => |_, uop| blk: {
            const expr = try self.parseExpression(0);
            const kind: std.meta.Tag(ast.ExpressionNode) = switch(uop) {
                .@"+_ch" => .unary_plus,
                .@"-_ch" => .unary_minus,
                .@"~_ch" => .unary_bitnot,
                .@"!_ch" => .unary_lognot,
                .@"*_ch" => .pointer_type,
                else => unreachable,
            };

            break :blk try ast.expressions.insert(@unionInit(ast.ExpressionNode, @tagName(kind), .{
                .operand = expr,
            }));
        },

        .@"*_ch" => blk: {
            var pointer_type: ast.PointerType = .{
                .is_const = false,
                .is_volatile = false,
                .child = undefined,
            };
            while(true) {
                switch(try self.peekToken()) {
                    .const_keyword => pointer_type.is_const = true,
                    .volatile_keyword => pointer_type.is_volatile = true,
                    else => break,
                }
                _ = try self.tokenize();
            }
            pointer_type.child = try self.parseExpression(0);
            break :blk try ast.expressions.insert(.{ .pointer_type = pointer_type });
        },

        .__keyword => .discard_underscore,
        .identifier => |ident| blk: {
            defer ident.deinit();
            break :blk try self.identToAstNode(ident);
        },

        .@".{_ch" => try self.parseTypeInitList(.none),
        .@"{_ch" => try self.parseBlockExpression(.none),

        inline
        .@".._ch", .@",_ch", .@"._ch", .@":_ch", .@";_ch",
        .@"=_ch", .@"==_ch", .@"!=_ch",
        .@"++_ch", .@"++=_ch",
        .@"+=_ch", .@"-=_ch", .@"*=_ch",
        .@"/_ch", .@"/=_ch", .@"%_ch", .@"%=_ch",
        .@"}_ch", .@")_ch", .@"]_ch",
        .@"<_ch", .@"<<_ch", .@"<=_ch", .@"<<=_ch",
        .@">_ch", .@">>_ch", .@">=_ch", .@">>=_ch",
        .@"|_ch", .@"|=_ch", .@"&_ch", .@"&=_ch",
        .@"^_ch", .@"^=_ch", .@"||_ch", .@"&&_ch",
        .case_keyword, .const_keyword, .var_keyword, .volatile_keyword, .else_keyword,
        .end_of_file, .return_keyword, .inline_keyword,
        => |_, tag| {
            std.debug.print("Unexpected primary-expression token: {s}\n", .{@tagName(tag)});
            return error.UnexpectedToken;
        },
    };

    while(true) {
        switch(try self.peekToken()) {
            .@"._ch" => {
                _ = try self.tokenize();
                switch(try self.tokenize()) {
                    .identifier => |token| {
                        lhs = try ast.expressions.insert(.{ .member_access = .{
                            .lhs = lhs,
                            .rhs = try self.identToAstNode(token),
                        }});
                        token.deinit();
                    },
                    .@"&_ch" => {
                        lhs = try ast.expressions.insert(.{ .addr_of = .{ .operand = lhs } });
                    },
                    .@"*_ch" => {
                        lhs = try ast.expressions.insert(.{ .deref = .{ .operand = lhs } });
                    },
                    else => |token|  {
                        std.debug.print("Unexpected postfix token: {s}\n", .{@tagName(token)});
                        return error.UnexpectedToken;
                    },
                }
            },
            .@"(_ch" => {
                _ = try self.tokenize();
                var arg_builder = ast.expressions.builderWithPath("function_argument.next");
                while((try self.peekToken()) != .@")_ch") {
                    _ = try arg_builder.insert(.{ .function_argument = .{.value = try self.parseExpression(null)}});
                    if ((try self.tryConsume(.@",_ch")) == null) {
                        break;
                    }
                }
                _ = try self.expect(.@")_ch");

                const lhs_expr = ast.expressions.get(lhs);
                if(lhs_expr.* == .builtin_function and lhs_expr.builtin_function == .import) {
                    std.debug.assert(arg_builder.first == arg_builder.last);
                    const arg = ast.expressions.getOpt(arg_builder.first).?;
                    const arg_expr = arg.function_argument.value;
                    const strlit = ast.expressions.get(arg_expr).string_literal;
                    const path_string = try strlit.retokenize();
                    defer path_string.deinit();
                    const dir = sources.source_files.get(self.source_file_index).dir;
                    const parsed_file = try parseFileIn(path_string.string_literal.value, dir);
                    arg.* = .{ .imported_file = parsed_file };
                    lhs = ast.expressions.getIndex(arg);
                } else {
                    lhs = try ast.expressions.insert(.{ .function_call = .{
                        .callee = lhs,
                        .first_arg = arg_builder.first,
                    }});
                }
            },
            .@"[_ch" => {
                _ = try self.tokenize();
                const index = try self.parseExpression(null);
                _ = try self.expect(.@"]_ch");
                lhs = try ast.expressions.insert(.{.array_subscript = .{
                    .lhs = lhs,
                    .rhs = index,
                }});
            },
            else => break,
        }
    }

    while(true) {
        switch(try self.peekToken()) {
            .@"{_ch" => {
                if(precedence < 1) return lhs;
                _ = try self.tokenize();
                lhs = try self.parseTypeInitList(ast.ExprIndex.toOpt(lhs));
            },

            // Binary operators
            inline
            .@".._ch", .@"=_ch", .@"==_ch", .@"!=_ch",
            .@"++_ch", .@"++=_ch",
            .@"+_ch", .@"+=_ch", .@"-_ch", .@"-=_ch", .@"*_ch", .@"*=_ch",
            .@"/_ch", .@"/=_ch", .@"%_ch", .@"%=_ch",
            .@"<_ch", .@"<<_ch", .@"<=_ch", .@"<<=_ch",
            .@">_ch", .@">>_ch", .@">=_ch", .@">>=_ch",
            .@"|_ch", .@"|=_ch", .@"&_ch", .@"&=_ch",
            .@"^_ch", .@"^=_ch",
            .@"||_ch", .@"&&_ch",
            => |_, op| {
                const op_prec: usize = switch(op) {
                    .@"*_ch", .@"/_ch", .@"%_ch", => 3,
                    .@"++_ch", .@"+_ch", .@"-_ch" => 4,
                    .@"<<_ch", .@">>_ch" => 5,
                    .@"&_ch", .@"^_ch", .@"|_ch" => 6,
                    .@"==_ch", .@"!=_ch", .@"<_ch", .@"<=_ch", .@">_ch", .@">=_ch" => 7,
                    .@"&&_ch", .@"||_ch" => 8,
                    .@".._ch" => 9,

                    .@"=_ch", .@"++=_ch",
                    .@"+=_ch", .@"-=_ch", .@"*=_ch",
                    .@"/=_ch", .@"%=_ch",
                    .@"|=_ch", .@"&=_ch", .@"^=_ch",
                    .@"<<=_ch", .@">>=_ch",
                    => 10,

                    else => unreachable,
                };

                if(op_prec > precedence) {
                    return lhs;
                }

                if(op_prec == precedence and op_prec != 10) {
                    return lhs;
                }

                const kind: std.meta.Tag(ast.ExpressionNode) = switch(op) {
                    .@"+_ch" => .plus,
                    .@"+=_ch" => .plus_eq,
                    .@"-_ch" => .minus,
                    .@"-=_ch" => .minus_eq,
                    .@"*_ch" => .multiply,
                    .@"*=_ch" => .multiply_eq,
                    .@"/_ch" => .divide,
                    .@"/=_ch" => .divide_eq,
                    .@"%_ch" => .modulus,
                    .@"%=_ch" => .modulus_eq,
                    .@"<<_ch" => .shift_left,
                    .@"<<=_ch" => .shift_left_eq,
                    .@">>_ch" => .shift_right,
                    .@">>=_ch" => .shift_right_eq,
                    .@"&_ch" => .bitand,
                    .@"&=_ch" => .bitand_eq,
                    .@"|_ch" => .bitor,
                    .@"|=_ch" => .bitor_eq,
                    .@"^_ch" => .bitxor,
                    .@"^=_ch" => .bitxor_eq,
                    .@"<_ch" => .less,
                    .@"<=_ch" => .less_equal,
                    .@">_ch" => .greater,
                    .@">=_ch" => .greater_equal,
                    .@"==_ch" => .equals,
                    .@"!=_ch" => .not_equal,
                    .@"&&_ch" => .logical_and,
                    .@"||_ch" => .logical_or,
                    .@"++_ch" => .array_concat,
                    .@"=_ch" => .assign,
                    .@".._ch" => .range,
                    else => unreachable,
                };

                _ = try self.tokenize();
                const rhs = try self.parseExpression(op_prec);
                lhs = try ast.expressions.insert(@unionInit(ast.ExpressionNode, @tagName(kind), .{
                    .lhs = lhs,
                    .rhs = rhs,
                }));
            },

            // Terminate the expression, regardless of precedence
            .@")_ch", .@"]_ch", .@"}_ch", .@";_ch", .@",_ch",
            => return lhs,

            // Following tokens are unreachable because they are handled in the
            // postfix operators above
            .@"._ch", .@"(_ch", .@"[_ch", .@".{_ch",
            => unreachable,

            inline
            .identifier, .int_literal, .char_literal, .string_literal,
            .@":_ch", .@"~_ch", .@"!_ch",
            .break_keyword, .case_keyword, .const_keyword, .continue_keyword,
            .else_keyword, .endcase_keyword, .enum_keyword, .fn_keyword,
            .if_keyword, .loop_keyword, .return_keyword, .struct_keyword,
            .switch_keyword, .var_keyword, .volatile_keyword, .__keyword, .bool_keyword,
            .type_keyword, .void_keyword, .anyopaque_keyword,
            .end_of_file, .true_keyword, .false_keyword, .undefined_keyword, .comptime_keyword,
            .inline_keyword, .unreachable_keyword, .noreturn_keyword,
            => |_, tag| {
                std.debug.panic("Unexpected post-primary expression token: {s}\n", .{@tagName(tag)});
            },
        }
    }
}

fn parseDeclaration(self: *@This(), token: tokenizer.Token) !ast.StmtIndex.Index {
    _ = try self.tokenize();
    const ident = try self.expect(.identifier);
    defer ident.deinit();

    var type_expr = ast.ExprIndex.OptIndex.none;
    var init_expr: ast.ExprIndex.Index = undefined;
    if(token == .fn_keyword) {
        const fidx = try self.parseFunctionExpr();
        init_expr = try ast.expressions.insert(.{ .function_expression = fidx });
    } else {
        if(try self.tryConsume(.@":_ch")) |_| {
            type_expr = ast.ExprIndex.toOpt(try self.parseExpression(0));
        }
        _ = try self.expect(.@"=_ch");

        init_expr = try self.parseExpression(null);

        _ = try self.expect(.@";_ch");
    }

    return ast.statements.insert(.{.value = .{ .declaration = .{
        .identifier = self.toAstIdent(ident),
        .type = type_expr,
        .init_value = init_expr,
        .mutable = token == .var_keyword,
    }}});
}

fn parseTypeBody(self: *@This()) !ast.StmtIndex.OptIndex {
    var decl_builder = ast.statements.builder();

    while(true) {
        const token = try self.peekToken();
        switch(token) {
            .identifier => |ident| {
                _ = try self.tokenize();
                defer ident.deinit();

                var type_expr = ast.ExprIndex.OptIndex.none;
                if((try self.peekToken()) == .@":_ch") {
                    _ = try self.tokenize();
                    type_expr = ast.ExprIndex.toOpt(try self.parseExpression(0));
                }

                var init_expr = ast.ExprIndex.OptIndex.none;
                if((try self.peekToken()) == .@"=_ch") {
                    _ = try self.tokenize();
                    init_expr = ast.ExprIndex.toOpt(try self.parseExpression(null));
                }

                _ = try self.expect(.@",_ch");
                _ = try decl_builder.insert(.{.value = .{ .field_decl = .{
                    .identifier = self.toAstIdent(ident),
                    .type = type_expr,
                    .init_value = init_expr,
                }}});
            },
            .const_keyword, .var_keyword, .fn_keyword => decl_builder.insertIndex(try self.parseDeclaration(token)),
            .end_of_file, .@"}_ch" => return decl_builder.first,
            else => std.debug.panic("Unhandled top-level token {any}", .{token}),
        }
    }
}

fn parseFile(fidx: sources.SourceIndex.Index) !ast.ExprIndex.Index {
    var parser = @This() {
        .source_file_index = fidx,
        .current_content = sources.source_files.get(fidx).contents.ptr,
    };

    return ast.expressions.insert(.{ .struct_expression = .{.first_decl = try parser.parseTypeBody()}});
}

fn createSourceFile(realpath: [:0]u8, current_dir: std.fs.Dir) !sources.SourceIndex.Index {
    const file_handle = try current_dir.openFileZ(realpath.ptr, .{});
    const dirname = std.fs.path.dirname(realpath).?;

    realpath[dirname.len] = 0;
    const dir_path = realpath[0..dirname.len:0];
    const dir_handle = try std.fs.openDirAbsoluteZ(dir_path, .{.access_sub_paths = true});
    realpath[dirname.len] = '/';

    const file_size = try file_handle.getEndPos();
    return sources.source_files.insert(.{
        .file = file_handle,
        .dir = dir_handle,
        .realpath = realpath,
        .contents = try file_handle.readToEndAllocOptions(
            std.heap.page_allocator,
            file_size,
            file_size,
            @alignOf(u8),
            0,
        ),
        .top_level_struct = undefined,
        .sema_struct = .none,
    });
}

var path_gpa = std.heap.GeneralPurposeAllocator(.{}){.backing_allocator = std.heap.page_allocator};

pub fn parseFileIn(path: []const u8, current_dir: std.fs.Dir) !sources.SourceIndex.Index {
    // Try to look up the path as if it were a package name
    if(std.mem.indexOfScalar(u8, path, '/') == null) {
        if(sources.path_map.get(path)) |parsed_file| {
            return parsed_file;
        }
    }

    // Try to look up a fully qualified path
    var realpath_buf: [std.os.PATH_MAX]u8 = undefined;
    const realpath_stack = try current_dir.realpath(path, &realpath_buf);
    return sources.path_map.get(realpath_stack) orelse
        try parsePackageRootFile(realpath_stack, try path_gpa.allocator().dupe(u8, realpath_stack));
}

pub fn parsePackageRootFile(path: []const u8, name: []const u8) !sources.SourceIndex.Index {
    var realpath_buf: [std.os.PATH_MAX]u8 = undefined;
    const current_dir = std.fs.cwd();
    const realpath_stack = try current_dir.realpath(path, &realpath_buf);
    const realpath = try path_gpa.allocator().dupeZ(u8, realpath_stack);
    const fidx = try createSourceFile(realpath, current_dir);
    try sources.path_map.put(name, fidx);
    std.debug.print("Starting parse of file: {s}\n", .{realpath});
    sources.source_files.get(fidx).top_level_struct = try parseFile(fidx);
    return fidx;
}

pub fn parseRootFile(path: [:0]u8) !ast.ExprIndex.Index {
    const fidx = try parseFileIn(path, std.fs.cwd());
    return sources.source_files.get(fidx).top_level_struct;
}
