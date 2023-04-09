window_width :: 800;
window_height :: 600;

working_directory_set := false;

Font :: Simp.Dynamic_Font;
my_font:     *Font;

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

chat_log: [..]Chat_Message;
twitch: Twitch_Chat([..]Chat_Message);

main :: () {
    window_title :: "Ditch";
    my_window := create_window(window_width, window_height, window_title);
    Simp.set_render_target(my_window);

    my_init_fonts();

    success := false;
    nick, pass : string;

    nick, success = get_environment_variable("DITCH_NICK");
    if !success {
        print("DITCH_NICK environment variable is not provided\n");
        exit(1);
    }
    pass, success = get_environment_variable("DITCH_PASS");
    if !success {
        print("DITCH_PASS environment variable is not provided\n");
        exit(1);
    }

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

    success = init(*twitch, event_callback, *chat_log, verbose = true);
    if !success then exit(1);
    success = connect(*twitch, nick, pass);
    if !success then exit(1);
    pass = "---";
    defer deinit(*twitch);

    current_time: float64;
    last_time: float64;

    quit := false;
    while !quit {
        current_time = get_time();
        dt := cast(float)(current_time - last_time);
        Clamp(*dt, 0, 0.1);
        last_time = current_time;

        success = update(*twitch, 0);
        if !success then break; // Or reconnect or whatever

        Input.update_window_events();

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
                                nick = nick,
                                message = message,
                            });
                        }
                    }
                }
            }
        }

        Simp.clear_render_target(.2, .05, .05, 1);
        for < chat_log {
            nick_color := make_vector4(.8, .5, 1, 1);
            nick_text := tprint("<%> ", it.nick);
            nick_width := Simp.prepare_text(my_font, nick_text);
            Simp.draw_prepared_text(my_font, 0, window_height/24*(chat_log.count - it_index - 1), nick_color);

            message_color := make_vector4(1, 1, 1, 1);
            message_text := it.message;
            Simp.prepare_text(my_font, message_text);
            Simp.draw_prepared_text(my_font, nick_width, window_height/24*(chat_log.count - it_index - 1), message_color);
        }
        Simp.swap_buffers(my_window);

        reset_temporary_storage();
        sleep_milliseconds(10);
    }
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

#import "Basic";
#import "Window_Creation";
Simp :: #import "Simp";
#import "Math";
#import "String";
#import "System";
#import "Thread";
#import "Clipboard";
Input :: #import "Input";
#load "twitch_irc/module.jai";
