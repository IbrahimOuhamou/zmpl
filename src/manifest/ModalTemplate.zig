const std = @import("std");

const Node = @import("Node.zig");
const util = @import("util.zig");

const ModalTemplate = @This();

allocator: std.mem.Allocator,
templates_path: []const u8,
name: []const u8,
path: []const u8,
input: []const u8,
state: enum { initial, tokenized, parsed, compiled } = .initial,
tokens: std.ArrayList(Token),
root_node: *Node = undefined,
index: usize = 0,
args: ?[]const u8 = null,
partial: bool,
template_map: std.StringHashMap([]const u8),

/// A mode pragma and its content in the input buffer. Stores args if present.
/// e.g.:
/// ```
/// @zig {
///     // some zig
/// }
/// ```
///
/// ```
/// @partial foo {
///     <div>some HTML</div>
/// }
/// ```
pub const Token = struct {
    mode: Mode,
    start: usize,
    end: usize,
    mode_line: []const u8,
    index: usize,
    depth: usize,
    args: ?[]const u8 = null,
};

/// Initialize a new template.
pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    templates_path: []const u8,
    path: []const u8,
    input: []const u8,
    template_map: std.StringHashMap([]const u8),
) ModalTemplate {
    return .{
        .allocator = allocator,
        .templates_path = templates_path,
        .name = name,
        .path = path,
        .input = util.normalizeInput(allocator, input),
        .tokens = std.ArrayList(Token).init(allocator),
        .partial = std.mem.startsWith(u8, std.fs.path.basename(path), "_"),
        .template_map = template_map,
    };
}

/// Free memory allocated by the template compilation.
pub fn deinit(self: *ModalTemplate) void {
    self.tokens.deinit();
}

/// Compile a template into a Zig code which can then be written out and compiled by Zig.
pub fn compile(self: *ModalTemplate, comptime options: type) ![]const u8 {
    if (self.state != .initial) unreachable;

    try self.tokenize();
    try self.parse();

    var buf = std.ArrayList(u8).init(self.allocator);
    const writer = buf.writer();

    try self.renderHeader(writer, options);
    try self.root_node.compile(self.input, writer);
    try self.renderFooter(writer);

    self.state = .compiled;

    return try buf.toOwnedSlice();
}

/// Here for compatibility with `Template` only - manifest generates random names for templates
/// and stores path in template definition + ComptimeStringMap instead.
pub fn identifier(self: *ModalTemplate) ![]const u8 {
    _ = self;
    return "";
}

const Mode = enum { html, zig, partial, args, markdown };
const default_mode: Mode = .html;
const Context = struct {
    mode: Mode,
    start: usize,
    depth: isize = 1,
};

// Tokenize template into (possibly nested) sections, where each section is a mode declaration
// and its content, specified by start and end markers.
fn tokenize(self: *ModalTemplate) !void {
    if (self.state != .initial) unreachable;

    var stack = std.ArrayList(Context).init(self.allocator);
    defer stack.deinit();
    try stack.append(.{ .mode = default_mode, .depth = 1, .start = 0 });

    var line_it = std.mem.splitScalar(u8, self.input, '\n');
    var cursor: usize = 0;
    var depth: usize = 0;
    var line_index: usize = 0;

    while (line_it.next()) |line| : (cursor += line.len + 1) {
        line_index += 1;

        if (getMode(line)) |mode| {
            const modeline_brace_depth = getBraceDepth(.zig, line);
            if (modeline_brace_depth == 0) {
                try self.appendToken(.{
                    .mode = mode,
                    .start = cursor,
                    .depth = 1,
                }, cursor + line.len, depth + 1);
            } else {
                try stack.append(.{
                    .mode = mode,
                    .start = cursor,
                    .depth = 1,
                });
                depth += @intCast(modeline_brace_depth);
            }
            continue;
        }

        resolveNesting(line, stack); // Modifies the `depth` field of the last value in the stack.

        if (stack.items.len > 0 and stack.items[stack.items.len - 1].depth == 0) {
            const context = stack.pop();
            try self.appendToken(context, cursor + line.len, depth);
            if (depth == 0) {
                self.debugError(line, line_index);
                return error.ZmplSyntaxError;
            } else {
                depth -= 1;
            }
        }
    }

    try self.appendRootToken();

    // for (self.tokens.items) |token| self.debugToken(token, false);

    self.state = .tokenized;
}

// Append a new token. Note that tokens are not ordered in any meaningful way - use
// `TokensIterator` to iterate through tokens in an appropriate order.
fn appendToken(self: *ModalTemplate, context: Context, end: usize, depth: usize) !void {
    const mode_end = std.mem.indexOfScalar(u8, self.input[context.start..end], '\n') orelse end - context.start + 1;
    const mode_line = self.input[context.start .. context.start + mode_end - 1];

    var args = std.mem.trim(u8, mode_line, &std.ascii.whitespace);
    args = std.mem.trimRight(u8, args, "{");
    const args_start = @tagName(context.mode).len + 1;
    args = if (args_start <= args.len)
        std.mem.trim(u8, args[args_start..], &std.ascii.whitespace)
    else
        "";

    try self.tokens.append(.{
        .mode = context.mode,
        .start = context.start + mode_end,
        .end = end,
        .mode_line = mode_line,
        .args = if (args.len > 0) args else null,
        .index = self.tokens.items.len,
        .depth = depth,
    });
}

// Append a root token with the default mode that covers the entire input.
fn appendRootToken(self: *ModalTemplate) !void {
    try self.tokens.append(.{
        .mode = default_mode,
        .start = 0,
        .end = self.input.len,
        .mode_line = "",
        .args = &.{},
        .index = self.tokens.items.len,
        .depth = 0,
    });
}

// Recursively parse tokens into an AST.
fn parse(self: *ModalTemplate) !void {
    if (self.state != .tokenized) unreachable;

    const root_token = getRootToken(self.tokens.items);
    self.root_node = try self.createNode(root_token);

    try self.parseChildren(self.root_node);

    // debugTree(self.root_node, 0);

    self.state = .parsed;
}

// Parse tokenized input by offloading to the relevant parser for each token's assigned mode.
fn parseChildren(self: *ModalTemplate, node: *Node) !void {
    var tokens_it = self.tokensIterator(node.token);
    while (tokens_it.next()) |token| {
        const child_node = try self.createNode(token);
        try self.parseChildren(child_node);
        try node.children.append(child_node);
    }
}

// Create an AST node.
fn createNode(self: ModalTemplate, token: Token) !*Node {
    const node = try self.allocator.create(Node);
    node.* = .{
        .allocator = self.allocator,
        .token = token,
        .children = std.ArrayList(*Node).init(self.allocator),
        .generated_template_name = self.name,
        .template_map = self.template_map,
        .templates_path = self.templates_path,
    };
    return node;
}

// Iterates through tokens in an appropriate order for parsing.
const TokensIterator = struct {
    index: usize,
    tokens: []Token,
    root_token: Token,

    /// Create a new token iterator for a given root token. Yields child and sibling tokens that
    /// exist within the bounds of the given root token.
    pub fn init(tokens: []Token, maybe_root_token: ?Token) TokensIterator {
        const root_token = maybe_root_token orelse getRootToken(tokens);
        return .{ .tokens = tokens, .root_token = root_token, .index = root_token.index };
    }

    /// Return the next token for the given root token.
    pub fn next(self: *TokensIterator) ?Token {
        if (self.tokens.len == 0) return null;

        self.index = self.getNextChildTokenIndex() orelse return null;

        return self.tokens[self.index];
    }

    // Identify the next token that exists at one depth level higher than the root token.
    fn getNextChildTokenIndex(self: TokensIterator) ?usize {
        var current_index: ?usize = null;

        for (self.tokens) |token| {
            if (token.depth != self.root_token.depth + 1) continue;
            if (token.index == self.index or token.index == self.root_token.index) continue;
            if (token.start < self.root_token.start or token.end >= self.root_token.end) continue;
            if (token.start < self.tokens[self.index].start) {
                continue;
            }

            if (current_index == null) {
                current_index = token.index;
                continue;
            }

            if (token.start < self.tokens[current_index.?].start) {
                current_index = token.index;
            }
        }

        if (current_index == null) return null;

        return current_index;
    }
};

// Return an iterator that yields tokens in an order appropriate for parsing (i.e. root node,
// then modal sections within the root node, modal sections within each modal section, etc.).
fn tokensIterator(self: ModalTemplate, token: ?Token) TokensIterator {
    return TokensIterator.init(self.tokens.items, token);
}

// Given an input line, identify a mode sigil (`@`) and, if present, return the specified mode.
// Since `@` is also used in Zig code, we do not fail if an unrecognized mode is specified.
fn getMode(line: []const u8) ?Mode {
    const stripped = std.mem.trim(u8, line, &std.ascii.whitespace);

    if (!std.mem.startsWith(u8, stripped, "@") or stripped.len < 2) return null;
    const end_of_first_word = std.mem.indexOfAny(u8, stripped, &std.ascii.whitespace);
    if (end_of_first_word == null) return null;

    const first_word = stripped[1..end_of_first_word.?];

    inline for (std.meta.fields(Mode)) |field| {
        if (std.mem.eql(u8, field.name, first_word)) return @enumFromInt(field.value);
    }

    return null;
}

// When the current context's mode is `zig`, evaluate open and close braces to determine the
// current nesting depth. For other modes, ignore braces except for a closing brace as the
// leading character on the given line.
fn resolveNesting(line: []const u8, stack: std.ArrayList(Context)) void {
    if (stack.items.len == 0) return;

    const current_context = stack.items[stack.items.len - 1];
    const current_mode = current_context.mode;
    const current_depth = current_context.depth;

    const increment: isize = getBraceDepth(current_mode, line);
    stack.items[stack.items.len - 1].depth = current_depth + increment;
}

// Count unescaped and unquoted braces opens and closes (+1 for open, -1 for close).
fn getBraceDepth(mode: Mode, line: []const u8) isize {
    return switch (mode) {
        .zig => blk: {
            var quoted = false;
            var escaped = false;
            var depth: isize = 0;
            for (line) |char| {
                if (char == '\\' and !escaped) {
                    escaped = true;
                } else if (escaped) {
                    escaped = false;
                } else if (char == '"' and !quoted) {
                    quoted = true;
                } else if (char == '"' and quoted) {
                    quoted = false;
                } else if (char == '{') {
                    depth += 1;
                } else if (char == '}') {
                    depth -= 1;
                }
            }
            break :blk depth;
        },
        .html, .partial, .markdown, .args => blk: {
            if (util.firstMeaningfulChar(line)) |char| {
                if (char == '}') break :blk -1;
            }
            break :blk 0;
        },
    };
}

// Render the function definiton and inject any provided constants.
fn renderHeader(self: *ModalTemplate, writer: anytype, options: type) !void {
    var decls_buf = std.ArrayList(u8).init(self.allocator);
    defer decls_buf.deinit();

    if (@hasDecl(options, "template_constants")) {
        inline for (std.meta.fields(options.template_constants)) |field| {
            const type_str = switch (field.type) {
                []const u8, i64, f64, bool => @typeName(field.type),
                else => @compileError("Unsupported template constant type: " ++ @typeName(field.type)),
            };

            const decl_string = "const " ++ field.name ++ ": " ++ type_str ++ " = try zmpl.getConst(" ++ type_str ++ ", \"" ++ field.name ++ "\");\n"; // :(

            try decls_buf.appendSlice("    " ++ decl_string);
            try decls_buf.appendSlice("    zmpl.noop(" ++ type_str ++ ", " ++ field.name ++ ");\n");
        }
    }

    for (self.tokens.items) |token| {
        if (token.mode != .args) continue;
        if (self.args != null) {
            std.debug.print("@args pragma can only be used once per template.\n", .{});
            return error.ZmplSyntaxError;
        }
        // Allow `@args(foo: []const u8, bar: usize)`
        //  and: `@args foo: []const u8, bar: usize`
        //  since it's barely any extra work.
        self.args = util.trimParentheses(util.strip(token.mode_line["@args".len..]));
    }

    const args = try std.mem.concat(
        self.allocator,
        u8,
        &[_][]const u8{ "slots: []const []const u8, ", self.args orelse "" },
    );
    const header = try std.fmt.allocPrint(
        self.allocator,
        \\pub fn {0s}_render{1s}(zmpl: *__zmpl.Data, {2s}) anyerror![]const u8 {{
        \\{3s}
        \\    const allocator = zmpl.getAllocator();
        \\    zmpl.noop(std.mem.Allocator, allocator);
        \\    const __is_partial = {4s};
        \\    {5s}
        \\
    ,
        .{
            self.name,
            if (self.partial) "Partial" else "",
            if (self.partial) args else "",
            decls_buf.items,
            if (self.partial) "true" else "false",
            if (self.partial) "zmpl.noop([]const []const u8, slots);" else "",
        },
    );
    defer self.allocator.free(header);

    try writer.writeAll(header);
}

// Render the final component of the template function.
fn renderFooter(self: ModalTemplate, writer: anytype) !void {
    try writer.writeAll(
        \\
        \\if (__is_partial) zmpl.chompOutputBuffer();
        \\return zmpl._allocator.dupe(u8, zmpl.output_buf.items);
        \\}
        \\
    );
    if (self.partial) {
        try writer.writeAll(try std.fmt.allocPrint(
            self.allocator,
            \\pub fn {0s}_renderWithLayout(
            \\    layout: __zmpl.manifest.Template,
            \\    zmpl: *__zmpl.Data,
            \\) anyerror![]const u8 {{
            \\    _ = layout;
            \\    _ = zmpl;
            \\    std.debug.print("Rendering a partial with a layout is not supported.\n", .{{}});
            \\    return error.ZmplError;
            \\}}
            \\
        ,
            .{self.name},
        ));
    } else {
        try writer.writeAll(try std.fmt.allocPrint(
            self.allocator,
            \\pub fn {0s}_renderWithLayout(
            \\    layout: __zmpl.manifest.Template,
            \\    zmpl: *__zmpl.Data,
            \\) anyerror![]const u8 {{
            \\    const inner_content = try {0s}_render(zmpl);
            \\    defer zmpl._allocator.free(inner_content);
            \\    zmpl.output_buf.clearAndFree();
            \\    zmpl.content = .{{ .data = __zmpl.chomp(inner_content) }};
            \\    const content = try layout.render(zmpl);
            \\    zmpl.output_buf.clearAndFree();
            \\    return content;
            \\}}
            \\
        ,
            .{self.name},
        ));
    }
}

// Identify the token with the widest span. This token should start at zero and end at
// self.input.len
fn getRootToken(tokens: []Token) Token {
    var root_token_index: usize = 0;

    for (tokens, 0..) |token, index| {
        const root_token = tokens[root_token_index];
        if (token.start < root_token.start and token.end > root_token.end) {
            root_token_index = index;
        }
    }

    return tokens[root_token_index];
}

fn debugError(self: ModalTemplate, line: []const u8, line_index: usize) void {
    std.debug.print(
        "[zmpl] Error resolving braces in `{s}:{}` \n    {s}\n",
        .{ self.path, line_index, line },
    );
}

// Output information about a given token and its content to stderr.
fn debugToken(self: ModalTemplate, token: Token, print_content: bool) void {
    std.debug.print("[{s}] |{}| {}->{} [{?s}]\n", .{
        @tagName(token.mode),
        token.depth,
        token.start,
        token.end,
        token.args,
    });
    if (print_content) std.debug.print("{s}\n", .{self.input[token.start..token.end]});
}

// Output a parsed tree with indentation to stderr.
fn debugTree(node: *Node, level: usize) void {
    if (level == 0) {
        std.debug.print("tree:\n", .{});
    }
    for (0..level + 1) |_| std.debug.print(" ", .{});
    std.debug.print("{s} {}->{}\n", .{ @tagName(node.token.mode), node.token.start, node.token.end });
    for (node.children.items) |child_node| {
        debugTree(child_node, level + 1);
    }
}