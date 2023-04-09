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

twitch: Twitch_Chat([..]string);
chat_log: [..]string;
mutex_chat: Mutex;

main :: () {
    window_title :: "Ditch";
    my_window := create_window(window_width, window_height, window_title);
    Simp.set_render_target(my_window);

    my_init_fonts();
    ui_init();

    init(*mutex_chat);

    twitch_thread: Thread;
    thread_init(*twitch_thread, (thread: *Thread) -> s64 {
        print("Twitch thread is running...\n");
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

        event_callback :: (event: Twitch_Event, chat_log: *[..]string) {
            if event.type == {
                case .AUTHENTICATED; {
                    cmd_join(*twitch, "#tsoding");
                }
                case .PRIVMSG; {
                    lock(*mutex_chat);
                    array_add(chat_log, copy_string(event.message));
                    unlock(*mutex_chat);
                }
            }
        }

        success = init(*twitch, event_callback, *chat_log, verbose = true);
        if !success then exit(1);
        success = connect(*twitch, nick, pass);
        if !success then exit(1);
        defer deinit(*twitch);


        while true {
            success = update(*twitch);
            if !success then break; // Or reconnect or whatever
        }

        return 0;
    });

    thread_start(*twitch_thread);

    current_time: float64;
    last_time: float64;

    quit := false;
    while !quit {
        current_time = get_time();
        dt := cast(float)(current_time - last_time);
        Clamp(*dt, 0, 0.1);
        last_time = current_time;

        // success = update(*twitch);
        // if !success then break; // Or reconnect or whatever

        Input.update_window_events();

        for event: Input.events_this_frame {
            if event.type == .QUIT then quit = true;

            getrect_handle_event(event);

            if event.type == {
              case .KEYBOARD;
                if event.key_pressed && event.key_code == .ESCAPE {
                    active_widget_deactivate_all();
                }
            }
        }

        // 0: foo 
        // 1: bar 
        // 2: baz

        // 0: baz
        // 1: bar 
        // 2: foo

        Simp.clear_render_target(.2, .05, .05, 1);
        lock(*mutex_chat);
        for < chat_log {
            Simp.prepare_text(my_font, it);
            Simp.draw_prepared_text(my_font, 0, window_height/24*(chat_log.count - it_index - 1), make_vector4(1, 1, 1, 1));
        }
        unlock(*mutex_chat);
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
#import "GetRect";
#import "Math";
#import "String";
#import "System";
#import "Thread";
Input :: #import "Input";
#load "./epoll.jai";
#load "twitch_irc/module.jai";
