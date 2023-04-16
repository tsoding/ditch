Twitch_Stream :: struct {
    title: string;
    user_name: string;
    viewer_count: int;
}

Twitch_User :: struct {
    id: string;
    login: string;
    display_name: string;
}

Twitch_Payload :: struct(T: Type) {
    data: []T;
}

Chat_Message :: struct {
    nick: string;
    message: string;
}

Config :: struct {
    username: string;
    oauth_token: string;
    auto_join: string;
    client_id: string;
}

window: Window_Type;
window_width, window_height: int;
my_font:     *Font;

chat_log: [..]Chat_Message;
twitch: Twitch_Chat([..]Chat_Message);

current_user: Twitch_User;
current_stream: Twitch_Stream;
current_stream_mutex: Mutex;
current_config: Config;
current_theme: s32 = xx Default_Themes.Grayscale;

current_time: float64;
last_time: float64;

string_a: string;

hexcode :: (code: string) -> Vector4 {
    value := string_to_int(code, base = 16, T = u64);
    a := ((value>>(8*0))&0xFF)/255.0;
    b := ((value>>(8*1))&0xFF)/255.0;
    g := ((value>>(8*2))&0xFF)/255.0;
    r := ((value>>(8*3))&0xFF)/255.0;
    return .{r, g, b, a};
}

BACKGROUND_COLOR :: #run hexcode("121f05ff");
INFO_COLOR       :: #run hexcode("c8f67aff");
NICK_COLOR       :: #run hexcode("c4d533ff");
MESSAGE_COLOR    :: #run hexcode("ffffffff");
SHADOW_COLOR     :: #run hexcode("181818FF");

main :: () {
    directory_of_running_executable := path_strip_filename(get_path_of_running_executable());
    set_working_directory(directory_of_running_executable);

    current_config = parse_config();
    current_user = query_current_user(current_config);

    window_width = 800;
    window_height = 600;
    window_title :: "Ditch";
    window = create_window(window_width, window_height, window_title);
    Simp.set_render_target(window);

    reload_fonts();
    ui_init();

    init(*current_stream_mutex);
    viewer_count_thread: Thread;
    ok := thread_init(*viewer_count_thread, (thread: *Thread) -> int {
        while true {
            stream, ok := query_current_stream(current_config);
            if ok {
                lock(*current_stream_mutex);
                current_stream = stream;
                unlock(*current_stream_mutex);
            }

            sleep_milliseconds(5000);
        }

        return 0;
    });
    if ok {
        thread_start(*viewer_count_thread);
    } else {
        log_error("ERROR: Could not initialize the Viewer Count Polling Thread");
    }

    event_callback :: (event: Twitch_Event, chat_log: *[..]Chat_Message) {
        if event.type == {
            case .AUTHENTICATED; {
                cmd_join(*twitch, current_config.auto_join);
            }
            case .PRIVMSG; {
                array_add(chat_log, .{
                    nick = copy_string(get_tag_value(event.tags, "display-name")),
                    message = copy_string(event.message) // TODO: some sort of special allocator for the messages?
                });
            }
        }
    }

    ok = init(*twitch, event_callback, *chat_log, verbose = true);
    if !ok {
        log_error("ERROR: Could not initialize Twitch connection");
        // Realistically as of right now this can only happen on Windows when WSAStartup() fails.
        // I'm not sure what to do in that case, so let's just exit;
        exit(1);
    }
    defer deinit(*twitch);

    // TODO: Move SSL initialization to twitch_irc
    ret := OpenSSL_add_all_algorithms();
    assert(ret == 1);
    ret = SSL_load_error_strings();
    assert(ret == 1);
    ctx := SSL_CTX_new(TLS_client_method());
    if ctx == null {
        print("ERROR: could not initialize SSL context\n");
        exit(1);
    }

    ok = connect(*twitch, current_config.username, tprint("oauth:%", current_config.oauth_token), port = "6697", ssl_ctx = ctx);
    if !ok {
        log_error("ERROR: Could not connect to Twitch");
        exit(1);
    }

    quit := false;
    while !quit {
        current_time = get_time();
        dt := cast(float)(current_time - last_time);
        Clamp(*dt, 0, 0.1);
        last_time = current_time;

        ok = update(*twitch, 0);
        // if !ok then break; // TODO: reconnect on Twitch connection failure

        Input.update_window_events();

        for Input.get_window_resizes() {
            Simp.update_window(it.window);

            if it.window == window {
                if (it.width != window_width) || (it.height != window_height) {
                    window_width  = it.width;
                    window_height = it.height;
                    reload_fonts();  // Resize the font for the new window size.
                }
            }
        }

        for event: Input.events_this_frame {
            if event.type == .QUIT then quit = true;

            getrect_handle_event(event);

            if event.type == {
            case .KEYBOARD;
                if event.key_pressed {
                    if event.key_code == {
                        case #char "T"; if event.ctrl_pressed {
                            set_current_title_to(current_config, os_clipboard_get_text());
                        }
                    }
                }
            }
        }

        lock(*current_stream_mutex);
        local_copy_of_current_stream_for_thread_safety := current_stream;
        unlock(*current_stream_mutex);

        draw_one_frame(local_copy_of_current_stream_for_thread_safety);

        reset_temporary_storage();
        sleep_milliseconds(10);
    }
}

draw_one_frame :: (stream: Twitch_Stream) {
    proc := default_theme_procs[current_theme];
    my_theme := proc();
    set_default_theme(my_theme);  // Just in case we don't explicitly pass themes sometimes...!

    bg_col := my_theme.background_color;
    Simp.clear_render_target(bg_col.x, bg_col.y, bg_col.z, 1);

    x, y, width, height := get_dimensions(window, true);
    ui_per_frame_update(window, width, height, current_time);

    MESSAGE_PADDING :: 10;

    modify_string :: (ps: *string, new_value: string) {
        free(<<ps);
            <<ps = copy_string(new_value);
    }

    text_theme := my_theme.text_input_theme;
    text_theme.font = my_font;

    INPUT_FIELD_HEIGHT :: 50;

    r := get_rect(0, 0, xx width, INPUT_FIELD_HEIGHT);
    action_a, new_text_a, state_a := text_input(r, string_a, *text_theme);
    if action_a & .ENTERED {
        cmd_privmsg(*twitch, current_config.auto_join, new_text_a);
        array_add(*chat_log, .{
            nick = current_config.username,
            message = copy_string(new_text_a),
        });
        free(string_a);
        string_a.data = null;
        string_a.count = 0;
        activate(state_a);
    } else if action_a & .ESCAPED {
        modify_string(*string_a, new_text_a);
    }

    for < chat_log {
        row := it_index - 2;
        y := (window_height/24 + MESSAGE_PADDING)*(chat_log.count - row - 1);

        nick_text := tprint("<%> ", it.nick);
        nick_width := Simp.prepare_text(my_font, nick_text);
        Simp.draw_prepared_text(my_font, MESSAGE_PADDING, y + MESSAGE_PADDING, NICK_COLOR);

        message_text := it.message;
        Simp.prepare_text(my_font, message_text);
        Simp.draw_prepared_text(my_font, MESSAGE_PADDING + nick_width, y + MESSAGE_PADDING, MESSAGE_COLOR);
    }

    {
        label_theme := my_theme.label_theme;
        label_theme.font = my_font;
        label_theme.alignment = .Right;
        label_height := my_font.character_height*1.5;

        SHADOW_OFFSET :: 2;

        viewer_count_text := tprint("Viewers: %", stream.viewer_count);

        label_theme.text_color = SHADOW_COLOR;
        r = get_rect(0 - SHADOW_OFFSET, window_height - label_height - SHADOW_OFFSET, xx window_width, label_height);
        label(r, viewer_count_text, *label_theme);

        label_theme.text_color = INFO_COLOR;
        r = get_rect(0, window_height - label_height, xx window_width, label_height);
        label(r, viewer_count_text, *label_theme);

        title_text := tprint("Title: %", stream.title);

        label_theme.text_color = SHADOW_COLOR;
        r = get_rect(0 - SHADOW_OFFSET, window_height - label_height*2 - SHADOW_OFFSET, xx window_width, label_height);
        label(r, title_text, *label_theme);

        label_theme.text_color = INFO_COLOR;
        r = get_rect(0, window_height - label_height*2, xx window_width, label_height);
        label(r, title_text, *label_theme);

    }

    Simp.swap_buffers(window);
}

#if OS == .WINDOWS {
    PATH_SEPARATOR_STRING :: "\\";
} else #if OS == .LINUX {
    PATH_SEPARATOR_STRING :: "/";
} else #if OS == .MACOS {
    PATH_SEPARATOR_STRING :: "/";
}

parse_config :: () -> Config, bool {
    config: Config;

    home_dir, ok := get_home_directory();
    if !ok {
        log_error("ERROR: Could not get home folder for some reason");
        return config, false;
    }

    ditch_dir := join(home_dir, ".ditch", separator = PATH_SEPARATOR_STRING);
    ok = make_directory_if_it_does_not_exist(ditch_dir);
    if !ok {
        log_error("ERROR: Could not create folder %", ditch_dir);
        return config, false;
    }

    ditch_conf_path := join(ditch_dir, "ditch.conf", separator = PATH_SEPARATOR_STRING);
    if !file_exists(ditch_conf_path) {
        config.username = "example";
        config.auto_join = "#example";
        ok = write_entire_file(ditch_conf_path, tprint(#string CONF
// -*- mode: c -*-
// Your Twitch username and and the channel to auto join. Keep in mind that the channel must start with #
username "%"
auto_join "%"

// You can get oauth_token and client_id at https://tsoding.github.io/kgbotka-login/
oauth_token ""
client_id ""
// vim: set filetype=c :
CONF, config.username, config.auto_join));
        if !ok {
            log_error("ERROR: Could not generate default %", ditch_conf_path);
            return config, false;
        }
        log("INFO: Generated default %", ditch_conf_path);
        return config, true;
    }

    ditch_content: string;
    ditch_content, ok = read_entire_file(ditch_conf_path);
    if !ok {
        log_error("ERROR: Could not read file %", ditch_conf_path);
        return config, false;
    }
    lexer := lexer_new(ditch_content, ditch_conf_path);

    token, result := lexer_next(*lexer);
    while result == .OK {
        if token.kind == .SYMBOL {
            if token.text == {
                case "username"; {
                    token, ok = lexer_expect_token(*lexer, .STRING);
                    if !ok return config, false;
                    config.username = token.text;
                }
                case "oauth_token"; {
                    token, ok = lexer_expect_token(*lexer, .STRING);
                    if !ok return config, false;
                    config.oauth_token = token.text;
                }
                case "auto_join"; {
                    token, ok = lexer_expect_token(*lexer, .STRING);
                    if !ok return config, false;
                    config.auto_join = token.text;
                }
                case "client_id"; {
                    token, ok = lexer_expect_token(*lexer, .STRING);
                    if !ok return config, false;
                    config.client_id = token.text;
                }
                case; {
                    log_diag_at(token.loc, .ERROR, "Unknown command %", token.text);
                    return config, false;
                }
            }
            token, result = lexer_next(*lexer);
        } else {
            log_diag_at(token.loc, .ERROR, "expected % but got %", Token_Kind.SYMBOL, token.kind);
            return config, false;
        }
    }

    if result != .EOF {
        return config, false;
    }

    return config, true;
}

set_current_title_to :: (config: Config, title: string) -> bool {
    Title_Patch :: struct {
        title: string;
    }

    url := tprint("https://api.twitch.tv/helix/channels?broadcaster_id=%", current_user.id);
    data := json_write_string(Title_Patch.{
        title = title
    });

    ok, content, code := request(.PATCH, url, config.client_id, config.oauth_token, data = data);
    if !ok {
        log_error("ERROR: Could not patch current title at %", url);
        return false;
    }

    if code >= 400 {
        log_error("ERROR: Query to % return code %: %", url, code, content);
        return false;
    }

    log("INFO: Successfully set the title to \"%\"", title);
    return true;
}

get_first_twitch_payload :: ($Payload: Type, config: Config, url: string, data: string) -> Payload, bool {
    ok, content, code := request(.GET, url, config.client_id, config.oauth_token, data = data);
    if !ok {
        log_error("ERROR: Could not query % via %", Type, url);
        return .{}, false;
    }

    if code >= 400 {
        log_error("ERROR: Query to % return code %: %", url, code, content);
        return .{}, false;
    }

    payload : Twitch_Payload(Payload);
    ok, payload = json_parse_string(content, type_of(payload));
    if !ok {
        log_error("ERROR: Could not parse Twitch payload from %: %", url, content);
        return .{}, false;
    }

    if payload.data.count <= 0 {
        log_error("ERROR: Twitch payload from % does not contain any %", url, Payload);
        return .{}, false;
    }

    return payload.data[0], true;
}

query_current_stream :: (config: Config) -> Twitch_Stream, bool {
    url :: "https://api.twitch.tv/helix/streams";
    data := tprint("user_login=%", config.username);
    stream, ok := get_first_twitch_payload(Twitch_Stream, config, url, data);
    return stream, ok;
}

query_current_user :: (config: Config) -> Twitch_User, bool {
    url :: "https://api.twitch.tv/helix/users";
    data := tprint("login=%", config.username);
    user, ok := get_first_twitch_payload(Twitch_User, config, url, data);
    return user, ok;
}

reload_fonts :: () -> bool {
    font_file_name :: "iosevka-regular.ttf";
    // font_file_name :: "VictorMono-Regular.ttf";
    // font_file_name :: "Miama.otf";
    // font_file_name :: "OpenSans-BoldItalic.ttf";
    pixel_height := window_height / 24;
    my_font = Simp.get_font_at_size("fonts", font_file_name, pixel_height);
    if my_font == null {
        log_error("ERROR: Could not load font % with size %", font_file_name, pixel_height);
        return false;
    }
    return true;
}

// Curl expects a C function, that's why we have to use #c_call, and since #c_call doesn't provide a context and JAI function need it, we push_context
write_callback :: (contents: *u8, count: u64, size: u64, builder: *String_Builder) -> u64 #c_call {
    total_size := count * size;
    new_context: Context;
    push_context new_context {
        // Append to the builder
        append(builder, contents, cast(s64) total_size);
    }
    return total_size;
}

// Enumerations for different REST methods
Rest_Method :: enum {
    GET;
    POST;
    PUT;
    DELETE;
    PATCH;
}

// Here we use a baked Rest_Method, this means variable method must be known on compile time,
// but that is fine since most likely you wouldn't change the method on runtime.
// This allows us to combine multiple functions into one, and cut on typing the same code multiple times,
// the way we distpatch between different methods is using #if keyword
request :: ($method: Rest_Method, url: string, client_id: string, oauth_token: string, data := "") -> bool, string, int {
    #import "Curl";

    // Init Curl and setup a deferred cleanup
    curl := curl_easy_init();
    if !curl {
        log_error("ERROR: An error occured while initting up the curl connection, but Curl doesn't tell us why.");
        return false, "", 0;
    }
    defer curl_easy_cleanup(curl);

    // Init string builder, so we can output a generic string
    builder: String_Builder;
    builder.allocator = temp; // We are not planning to keep the string long term, so we will use temp allocator, in a real application that decision has to be made for yourself

    curl_easy_setopt(curl, .WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, .WRITEDATA, *builder);

    headerlist := curl_slist_append(null, tprint("Client-Id: %\0", client_id).data);
    headerlist = curl_slist_append(headerlist, tprint("Authorization: Bearer %\0", oauth_token).data);
    headerlist = curl_slist_append(headerlist, "Content-Type: application/json\0".data);
    curl_easy_setopt(curl, .HTTPHEADER, headerlist);
    defer curl_slist_free_all(headerlist);

    // Set target URL
    #if method == .GET {
        // Add request data to the url, since GET requests expect it there
        // Maybe this shouldn't be included in the example, for the sake of reducing complexity (mandate that data is passed in the url for the get request)
        url_builder: String_Builder;

        append(*url_builder, url);
        if !ends_with(url, "/") && !ends_with(url, "\\") {
            append(*url_builder, "/");
        }
        append(*url_builder, "?");
        append(*url_builder, data);

        // Ideally we would only do one temp allocation here, something like builder_to_cstring
        curl_easy_setopt(curl, .URL, temp_c_string(builder_to_string(*url_builder, temp)));
    } else {
        curl_easy_setopt(curl, .URL, temp_c_string(url));
    }

    // Pass request data
    #if method == .GET {
        // Already set up in the URL!
    } else if method == .POST {
        curl_easy_setopt(curl, .POST, 1);
        if data  curl_easy_setopt(curl, .POSTFIELDS, temp_c_string(data));
    } else if method == .PUT {
        curl_easy_setopt(curl, .CUSTOMREQUEST, "PUT");
        if data  curl_easy_setopt(curl, .POSTFIELDS, temp_c_string(data));
    } else if method == .DELETE {
        curl_easy_setopt(curl, .CUSTOMREQUEST, "DELETE");
        if data  curl_easy_setopt(curl, .POSTFIELDS, temp_c_string(data));
    } else if method == .PATCH {
        curl_easy_setopt(curl, .CUSTOMREQUEST, "PATCH");
        if data  curl_easy_setopt(curl, .POSTFIELDS, temp_c_string(data));
    }

    // Perform the "easy" action
    error_code := curl_easy_perform(curl);
    if error_code != .OK {
        error_message := to_string(curl_easy_strerror(error_code));
        defer free(error_message);
        log_error("Curl Error: %", error_message);
        return false, "", 0;
    }

    http_code: int;
    error_code = curl_easy_getinfo(curl, .RESPONSE_CODE, *http_code);
    assert(error_code == .OK, "I assume for now that error_code != .OK only if curl_easy_perform has failed. (Which might be a wrong assumption. That's why we have this assert in here)");

    // In a real application you would most likely use default allocator,
    // here we only intend to use the string short term
    return true, builder_to_string(*builder, temp), http_code;
}

#import "Basic";
#import "File_Utilities";
#import "Window_Creation";
#import "GetRect";
Simp :: #import "Simp";
Font :: Simp.Dynamic_Font;
#import "Math";
#import "String";
#import "System";
#import "Thread";
#import "Atomics";
#import "Clipboard";
Input :: #import "Input";
#load "twitch_irc/module.jai";
#load "jason/module.jai";
#load "config_lexer.jai";

// TODO: consider utilizing GLOBALUSERSTATE instead of query_current_user() to get the user-id
// TODO: set the title via the chat text input
