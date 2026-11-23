//
// JPM — Structured Event Audit Logging & Log File Rotation
//

#import "Basic";
#import "String";
#import "File";
#import "File_Utilities";
#import "types";

get_iso_timestamp :: () -> string {
    ct := to_calendar(current_time_consensus(), .LOCAL);
    return tprint("%04-%02-%02 %02:%02:%02",
        ct.year, ct.month_starting_at_0 + 1, ct.day_of_month_starting_at_0 + 1,
        ct.hour, ct.minute, ct.second);
}

log_lifecycle_event :: (events_file_path: string, event_type: string, details: string) {
    if events_file_path.count == 0 return;
    
    // Ensure directory exists
    dir, _ := path_decomp(events_file_path);
    if dir.count > 0 make_directory_if_it_does_not_exist(dir, recursive = true);
    
    timestamp := get_iso_timestamp();
    line := tprint("[%] %-8 %\n", timestamp, event_type, details);
    
    f, ok := file_open(events_file_path, for_writing = true, keep_existing_content = true);
    if ok {
        file_seek(f, 0, .END);
        file_write(*f, line);
        file_close(*f);
    }
}

rotate_log_file_if_needed :: (file_path: string, max_size: u64, max_backups: u32) {
    if file_path.count == 0 || max_size == 0 || max_backups == 0 return;
    if !file_exists(file_path) return;
    
    sz, ok := file_length(file_path);
    if !ok || cast(u64)sz < max_size return;
    
    // Rotate backup files: .2.txt -> .3.txt, .1.txt -> .2.txt
    for < i: cast(s32)max_backups - 1 .. 1 {
        old_name := tprint("%.%.txt", file_path, i);
        new_name := tprint("%.%.txt", file_path, i + 1);
        if file_exists(old_name) {
            file_move(old_name, new_name);
        }
    }
    
    // Rotate current file to .1.txt
    first_backup := tprint("%.1.txt", file_path);
    file_move(file_path, first_backup);
}
