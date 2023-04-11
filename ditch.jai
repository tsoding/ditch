window_width, window_height: int;

working_directory_set := false;

Font :: Simp.Dynamic_Font;
my_font:     *Font;

Twitch_Error :: struct {
    error: string;
    message: string;
}

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

get_environment_variable :: (name: string) -> (string, bool) {
    c_name: *u8 = talloc(name.count + 1);
    memcpy(c_name, name.data, name.count);
    c_name[name.count] = 0;
    result := getenv(c_name);
    if result == null return "", false;
    return to_string(result), true;
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

chat_log: [..]Chat_Message;
twitch: Twitch_Chat([..]Chat_Message);
current_user: Twitch_User;
current_stream: Twitch_Stream;
current_stream_mutex: Mutex;
current_config: Config;

main :: () {
    current_config = parse_config();
    query_current_user();

    window_width = 800;
    window_height = 600;
    window_title :: "Ditch";
    my_window := create_window(window_width, window_height, window_title);
    Simp.set_render_target(my_window);

    my_init_fonts();

    init(*current_stream_mutex);

    viewer_count_thread: Thread;
    thread_init(*viewer_count_thread, (thread: *Thread) -> int {
        while true {
            url :: "https://api.twitch.tv/helix/streams";
            ok, content, code := request(.GET, url, current_config.client_id, current_config.oauth_token, data = "user_login=tsoding");
            assert(ok);

            if code >= 400 {
                print("ERROR: from %: %\n", url, content);
            } else {
                payload : Twitch_Payload(Twitch_Stream);
                ok, payload = json_parse_string(content, type_of(payload));
                if ok {
                    if payload.data.count > 0 {
                        lock(*current_stream_mutex);
                        current_stream = payload.data[0];
                        unlock(*current_stream_mutex);
                    } else {
                        memset(*current_stream, 0, size_of(type_of(current_stream)));
                    }
                } else {
                    print("ERROR: could not parse response from %\n", url);
                }
            }

            sleep_milliseconds(5000);
        }

        return 0;
    });

    thread_start(*viewer_count_thread);

    event_callback :: (event: Twitch_Event, chat_log: *[..]Chat_Message) {
        if event.type == {
            case .AUTHENTICATED; {
                cmd_join(*twitch, "#tsoding");
            }
            case .PRIVMSG; {
                array_add(chat_log, .{
                    nick = copy_string(get_tag_value(event.tags, "display-name")),
                    message = copy_string(event.message)
                });
            }
        }
    }

    ok := init(*twitch, event_callback, *chat_log, verbose = true);
    if !ok then exit(1);
    ok = connect(*twitch, current_config.username, tprint("oauth:%", current_config.oauth_token));
    if !ok then exit(1);
    defer deinit(*twitch);

    current_time: float64;
    last_time: float64;

    quit := false;
    while !quit {
        current_time = get_time();
        dt := cast(float)(current_time - last_time);
        Clamp(*dt, 0, 0.1);
        last_time = current_time;

        ok = update(*twitch, 0);
        if !ok then break; // Or reconnect or whatever

        Input.update_window_events();

        for Input.get_window_resizes() {
            Simp.update_window(it.window);

            if it.window == my_window {
                should_reinit := (it.width != window_width) || (it.height != window_height);

                window_width  = it.width;
                window_height = it.height;

                if should_reinit my_init_fonts();  // Resize the font for the new window size.
            }
        }

        for event: Input.events_this_frame {
            if event.type == .QUIT then quit = true;

            if event.type == {
            case .KEYBOARD;
                if event.key_pressed {
                    if event.key_code == {
                        case .ENTER; {
                            message := os_clipboard_get_text();
                            cmd_privmsg(*twitch, "#tsoding", message);
                            array_add(*chat_log, .{
                                nick = current_config.username,
                                message = message,
                            });
                        }

                        case #char "T"; if event.ctrl_pressed {
                            Title_Patch :: struct {
                                title: string;
                            }
                            content: string;
                            status: int;
                            ok, content, status = request(
                                    .PATCH, tprint("https://api.twitch.tv/helix/channels?broadcaster_id=%", current_user.id),
                                    current_config.client_id, current_config.oauth_token,
                                    data = json_write_string(Title_Patch.{
                                        title = os_clipboard_get_text()
                                    }));
                            assert(ok);
                            print("------------------------------\n");
                            print("Content: %\n", content);
                            print("Status: %\n", status);
                            print("------------------------------\n");
                        }
                    }
                }
            }
        }

        hexcode :: (code: string) -> Vector4 {
            value := string_to_int(code, base = 16, T = u64);
            a := ((value>>(8*0))&0xFF)/255.0;
            b := ((value>>(8*1))&0xFF)/255.0;
            g := ((value>>(8*2))&0xFF)/255.0;
            r := ((value>>(8*3))&0xFF)/255.0;
            return make_vector4(r, g, b, a);
        }

        {
            using background_color :: #run hexcode("121f05ff");
            Simp.clear_render_target(x, y, z, w);
        }

        lock(*current_stream_mutex);
        local_copy_of_current_stream_for_thread_safety := current_stream;
        unlock(*current_stream_mutex);

        info_color :: #run hexcode("c8f67aff");

        viewer_count_text := tprint("Viewers: %", local_copy_of_current_stream_for_thread_safety.viewer_count);
        Simp.prepare_text(my_font, viewer_count_text);
        Simp.draw_prepared_text(my_font, 0, 0, info_color);

        title_text := tprint("Title: %", local_copy_of_current_stream_for_thread_safety.title);
        Simp.prepare_text(my_font, title_text);
        Simp.draw_prepared_text(my_font, 0, window_height/24, info_color);

        MESSAGE_PADDING :: 10;

        for < chat_log {
            row := it_index - 2;
            y := (window_height/24 + MESSAGE_PADDING)*(chat_log.count - row - 1);

            nick_color :: #run hexcode("c4d533ff");
            nick_text := tprint("<%> ", it.nick);
            nick_width := Simp.prepare_text(my_font, nick_text);
            Simp.draw_prepared_text(my_font, 0, y, nick_color);

            message_color :: #run hexcode("ffffffff");
            message_text := it.message;
            Simp.prepare_text(my_font, message_text);
            Simp.draw_prepared_text(my_font, nick_width, y, message_color);
        }
        Simp.swap_buffers(my_window);

        reset_temporary_storage();
        sleep_milliseconds(10);
    }
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
        print("ERROR: could not get home folder for some reason\n");
        return config, false;
    }

    ditch_dir := join(home_dir, ".ditch", separator = PATH_SEPARATOR_STRING);
    ok = make_directory_if_it_does_not_exist(ditch_dir);
    if !ok {
        print("ERROR: could not create folder %\n", ditch_dir);
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
            print("ERROR: could not generate default %\n", ditch_conf_path);
            return config, false;
        }
        print("INFO: Generated default %\n", ditch_conf_path);
        return config, true;
    }

    ditch_content: string;
    ditch_content, ok = read_entire_file(ditch_conf_path);
    if !ok {
        print("ERROR: could not read file %\n", ditch_conf_path);
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

query_current_user :: () {
    url :: "https://api.twitch.tv/helix/users";
    ok, content, code := request(.GET, "https://api.twitch.tv/helix/users", current_config.client_id, current_config.oauth_token, data = tprint("login=%", current_config.username));
    if !ok {
        print("ERROR: could not query %\n", url);
        exit(1);
    }

    if code >= 400 {
        print("ERROR: could not query %: %\n", url, content);
        exit(1);
    }

    payload: Twitch_Payload(Twitch_User);
    ok, payload = json_parse_string(content, type_of(payload));
    if !ok {
        print("ERROR: could not parse payload from %: %", url, content);
        exit(1);
    }

    if payload.data.count <= 0 {
        print("ERROR: payload did not contain any user\n");
        exit(1);
    }

    current_user = payload.data[0];
}

my_init_fonts :: () {
    if !working_directory_set {
        // So that we can load our font, set to path of running executable.
        path := path_strip_filename(get_path_of_running_executable());
        set_working_directory(path);

        working_directory_set = true;
    }

    pixel_height := window_height / 24;
    my_font = Simp.get_font_at_size("fonts", "iosevka-regular.ttf", pixel_height);
    assert(my_font != null);
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
    // Init Curl and setup a deferred cleanup
    curl := curl_easy_init();
    if !curl {
+       print("An error occured while initting up the curl connection, but Curl doesn't tell us why.\n");
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
        print("Curl Error: %\n", error_message);
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
Simp :: #import "Simp";
#import "Math";
#import "String";
#import "System";
#import "Thread";
#import "Curl";
#import "Atomics";
#import "Clipboard";
Input :: #import "Input";
#load "twitch_irc/module.jai";
#load "jason/module.jai";
#load "lexer.jai";
