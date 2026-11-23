//
// JPM — Multi-Workspace Compiler Build Script
// Builds jpm, jpmd, and jpm-ui into bin/
//

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";

#run {
    set_build_options_dc(.{do_output = false});
    
    make_directory_if_it_does_not_exist("bin", recursive = true);

    build_target("jpmd",   "src/daemon/daemon.jai",  is_gui = false);
    build_target("jpm",    "src/cli/main.jai",       is_gui = false);
    build_target("jpm-ui", "src/gui/gui_main.jai",   is_gui = true);
}

build_target :: (exe_name: string, entry_file: string, is_gui: bool) {
    w := compiler_create_workspace(exe_name);
    options := get_build_options(w);
    options.output_executable_name = exe_name;
    options.output_path = "bin/";

    // Configure module import search paths
    array_add(*options.import_path, "src/shared");
    array_add(*options.import_path, "src/platform");
    array_add(*options.import_path, "src/daemon");
    array_add(*options.import_path, "src/gui");

    #if OS == .WINDOWS {
        if is_gui {
            // Suppress console window on Windows for the GUI dashboard executable
            options.additional_linker_arguments = .["/SUBSYSTEM:WINDOWS", "/ENTRY:mainCRTStartup"];
        }
    }

    set_build_options(options, w);
    add_build_file(entry_file, w);
}
