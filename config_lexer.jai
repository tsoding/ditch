Loc :: struct {
    file_path: string;
    row: int;
    col: int;
}

Token_Kind :: enum {
    INVALID;
    SYMBOL;
    STRING;
    OCURLY;
    CCURLY;
}

Token :: struct {
    kind: Token_Kind;
    text: string;
    loc: Loc;
}

Lexer :: struct {
    content: string;
    file_path: string;
    row, bol, cur: int;
    sb: String_Builder;

    peeked: bool;
    peeked_token: Token;
    peeked_result: Lexer_Result;
}

lexer_new :: (content: string, file_path := "") -> Lexer {
    lexer: Lexer;
    lexer.content = content;
    lexer.file_path = file_path;
    return lexer;
}

Lexer_Result :: enum {
    OK;
    EOF;
    INVALID;
}

Diag_Level :: enum {
    NOTE;
    WARNING;
    ERROR;
}

log_diag_at :: (using loc: Loc, level: Diag_Level, format: string, args: .. Any) {
    builder: String_Builder;
    builder.allocator = temp;
    print_to_builder(*builder, "%:%:%: ", file_path, row + 1, col + 1);
    if #complete level == {
    case .NOTE;    print_to_builder(*builder, "NOTE: ");
    case .WARNING; print_to_builder(*builder, "WARNING: ");
    case .ERROR;   print_to_builder(*builder, "ERROR: ");
    }
    print_to_builder(*builder, format, .. args);
    log_error(builder_to_string(*builder));
}

lexer_peek :: (using l: *Lexer) -> Token, Lexer_Result {
    if !peeked {
        peeked_token, peeked_result = lexer_chop_token(l);
        peeked = true;
    }

    return peeked_token, peeked_result;
}

lexer_next :: (using l: *Lexer) -> Token, Lexer_Result {
    if peeked {
        peeked = false;
        return peeked_token, peeked_result;
    }

    token, result := lexer_chop_token(l);
    return token, result;
}

lexer_expect_token :: (using l: *Lexer, expected: .. Token_Kind) -> Token, bool {
    token, result := lexer_next(l);
    if #complete result == {
        case .OK; {
            for expected {
                if it == token.kind {
                    return token, true;
                }
            }
            for expected {
                if it_index > 0 then print_to_builder(*sb, " or ");
                print_to_builder(*sb, "%", it);
            }
            log_diag_at(token.loc, .ERROR, "expected % but got %", builder_to_string(*sb), token.kind);
            return token, false;
        }
        case .INVALID; return token, false;
        case .EOF; {
            for expected {
                if it_index > 0 then print_to_builder(*sb, " or ");
                print_to_builder(*sb, "%", it);
            }
            log_diag_at(token.loc, .ERROR, "expected % but got end of file", builder_to_string(*sb));
            return token, false;
        }
    }
}

#scope_file

lexer_chop_token :: (using l: *Lexer) -> Token, Lexer_Result {
    lexer_trim_left(l);
    while !lexer_is_empty(l) && lexer_starts_with(l, "//") {
        lexer_drop_line(l);
        lexer_trim_left(l);
    }

    t: Token;
    t.loc = lexer_loc(l);

    if lexer_is_empty(l) return t, .EOF;

    if is_symbol_start(content[cur]) {
        t.kind = .SYMBOL;
        while !lexer_is_empty(l) && is_symbol(content[cur]) {
            append(*sb, content[cur]);
            lexer_chop_chars(l);
        }
        t.text = builder_to_string(*sb);
        return t, .OK;
    }

    if content[cur] == #char "\"" {
        t.kind = .STRING;

        lexer_chop_chars(l);
        while !lexer_is_empty(l) {
            if content[cur] == {
                case #char "\""; break;
                case #char "\\"; {
                    lexer_chop_chars(l);
                    if lexer_is_empty(l) {
                        log_diag_at(lexer_loc(l), .ERROR, "unfinished escape sequence");
                        return t, .INVALID;
                    }

                    if content[cur] == {
                        case #char "\""; {
                            append(*sb, #char "\"");
                            lexer_chop_chars(l);
                        }
                        case; {
                            log_diag_at(lexer_loc(l), .ERROR, "unknown escape sequence starts with %", slice(content, cur, 1));
                            return t, .INVALID;
                        }
                    }
                }
                case; {
                    append(*sb, content[cur]);
                    lexer_chop_chars(l);
                }
            }
        }

        t.text = builder_to_string(*sb);

        if lexer_is_empty(l) {
            log_diag_at(lexer_loc(l), .ERROR, "unfinished string literal");
            log_diag_at(t.loc, .NOTE, "the literal starts here");
            return t, .INVALID;
        }

        lexer_chop_chars(l);

        return t, .OK;

    }

    delims : []struct { prefix: string; kind: Token_Kind; } = .[
        .{ prefix = "{", kind = .OCURLY },
        .{ prefix = "}", kind = .CCURLY },
    ];

    for delims {
        if lexer_starts_with(l, it.prefix) {
            lexer_chop_chars(l, it.prefix.count);
            t.kind = it.kind;
            t.text = it.prefix;
            return t, .OK;
        }
    }

    log_diag_at(t.loc, .ERROR, "invalid token starts with %", slice(content, cur, 1));
    lexer_chop_chars(l);
    return t, .INVALID;
}

lexer_is_empty :: (using l: *Lexer) -> bool {
    return cur >= content.count;
}

lexer_trim_left :: (using l: *Lexer) {
    while !lexer_is_empty(l) && is_space(content[cur]) {
        lexer_chop_chars(l);
    }
}

lexer_starts_with :: (using l: *Lexer, prefix: string) -> bool {
    assert(cur <= content.count);
    return starts_with(slice(content, cur, content.count - cur), prefix);
}

lexer_drop_line :: (using l: *Lexer) {
    while !lexer_is_empty(l) && content[cur] != #char "\n" {
        lexer_chop_chars(l);
    }

    if !lexer_is_empty(l) {
        lexer_chop_chars(l);
    }
}

lexer_loc :: (using l: *Lexer) -> Loc {
    return .{
        file_path = file_path,
        row = row,
        col = cur - bol,
    };
}

is_symbol_start :: (x: u8) -> bool {
    if #char "a" <= x && x <= #char "z" return true;
    if #char "A" <= x && x <= #char "Z" return true;
    return x == #char "_";
}

is_symbol :: (x: u8) -> bool {
    if is_symbol_start(x) return true;
    return #char "0" <= x && x <= #char "9";
}

lexer_chop_chars :: (using l: *Lexer, n := 1) {
    while !lexer_is_empty(l) && n > 0 {
        x := content[cur];
        cur += 1;
        if x == #char "\n" {
            row += 1;
            bol = cur;
        }
        n -= 1;
    }
}
