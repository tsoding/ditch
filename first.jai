#import "Basic";
#import "Compiler";

#run {
    w := compiler_create_workspace("Ditch");
    if !w {
        print("ERROR: Workspace creation failed.\n");
        return;
    }

    bo := get_build_options(w);
    bo.output_executable_name = "ditch";
    import_path : [..]string;
    array_add(*import_path, .. bo.import_path);
    array_add(*import_path, ".");
    bo.import_path = import_path;
    set_build_options(bo, w);
    add_build_file("ditch.jai", w);

    set_build_options_dc(.{do_output=false});
}
