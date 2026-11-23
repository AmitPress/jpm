//
// JPM — Daemon State Persistence (~/.jpm/state.jpm)
//

#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "types";
#import "protocol";
#import "platform";

STATE_MAGIC :: 0x4A504D53; // "JPMS"
STATE_VERSION :: 1;

Persisted_Entry :: struct {
    config:        Process_Config;
    crash_count:   u32;
    restart_count: u32;
}

save_daemon_state :: (entries: [] Persisted_Entry) -> bool {
    state_path := platform_get_default_state_path();
    dir, _ := path_decomp(state_path);
    if dir.count > 0 make_directory_if_it_does_not_exist(dir, recursive = true);
    
    tmp_path := tprint("%.tmp", state_path);
    
    buf := init_byte_buffer(4096);
    defer free_byte_buffer(*buf);
    
    write_u32(*buf, STATE_MAGIC);
    write_u16(*buf, STATE_VERSION);
    write_u32(*buf, cast(u32)entries.count);
    
    for * entry: entries {
        cfg := *entry.config;
        write_string(*buf, cfg.name);
        write_string(*buf, cfg.command);
        write_string(*buf, cfg.cwd);
        
        write_u32(*buf, cast(u32)cfg.env_vars.count);
        for e: cfg.env_vars write_string(*buf, e);
        
        write_u8(*buf, cast(u8)cfg.restart_policy);
        write_u32(*buf, cfg.max_retries);
        write_u32(*buf, cfg.backoff_ms);
        write_u64(*buf, cfg.hard_memory_max);
        
        write_u32(*buf, cast(u32)cfg.memory_rules.count);
        for * r: cfg.memory_rules {
            write_u64(*buf, r.threshold_bytes);
            write_u32(*buf, r.duration_sec);
            write_u8(*buf, cast(u8)r.action);
            write_string(*buf, r.run_cmd);
            write_u32(*buf, r.cooldown_sec);
        }
        
        write_string(*buf, cfg.log_out);
        write_string(*buf, cfg.log_err);
        write_string(*buf, cfg.log_events);
        write_u64(*buf, cfg.max_log_size);
        write_u32(*buf, cfg.max_backups);
        
        write_u32(*buf, entry.crash_count);
        write_u32(*buf, entry.restart_count);
    }
    
    // Write buffer to tmp file
    f, ok := file_open(tmp_path, for_writing = true);
    if !ok return false;
    file_write(*f, buf.data.data, buf.data.count);
    file_close(*f);
    
    // Atomic rename
    if file_exists(state_path) {
        file_delete(state_path);
    }
    return file_move(tmp_path, state_path);
}

load_daemon_state :: () -> (entries: [..] Persisted_Entry, ok: bool) {
    res: [..] Persisted_Entry;
    state_path := platform_get_default_state_path();
    if !file_exists(state_path) return res, true; // Clean initial state
    
    content, ok_read := read_entire_file(state_path);
    if !ok_read return res, false;
    defer free(content);
    
    buf: Byte_Buffer;
    buf.data.data = content.data;
    buf.data.count = content.count;
    buf.data.allocated = content.count;
    
    magic, ok_m := read_u32(*buf);
    if !ok_m || magic != STATE_MAGIC return res, false;
    
    ver, ok_v := read_u16(*buf);
    if !ok_v || ver != STATE_VERSION return res, false;
    
    count, ok_c := read_u32(*buf);
    if !ok_c return res, false;
    
    array_reserve(*res, count);
    for i: 0..count-1 {
        entry: Persisted_Entry;
        cfg := *entry.config;
        
        cfg.name, _ = read_string(*buf);
        cfg.command, _ = read_string(*buf);
        cfg.cwd, _ = read_string(*buf);
        
        env_count, _ := read_u32(*buf);
        for j: 0..env_count-1 {
            ev, _ := read_string(*buf);
            array_add(*cfg.env_vars, ev);
        }
        
        rp, _ := read_u8(*buf);
        cfg.restart_policy = cast(Restart_Policy)rp;
        cfg.max_retries, _ = read_u32(*buf);
        cfg.backoff_ms, _ = read_u32(*buf);
        cfg.hard_memory_max, _ = read_u64(*buf);
        
        rule_count, _ := read_u32(*buf);
        for j: 0..rule_count-1 {
            rule: Memory_Rule;
            rule.threshold_bytes, _ = read_u64(*buf);
            rule.duration_sec, _ = read_u32(*buf);
            act, _ := read_u8(*buf);
            rule.action = cast(Watchdog_Action)act;
            rule.run_cmd, _ = read_string(*buf);
            rule.cooldown_sec, _ = read_u32(*buf);
            array_add(*cfg.memory_rules, rule);
        }
        
        cfg.log_out, _ = read_string(*buf);
        cfg.log_err, _ = read_string(*buf);
        cfg.log_events, _ = read_string(*buf);
        cfg.max_log_size, _ = read_u64(*buf);
        cfg.max_backups, _ = read_u32(*buf);
        
        entry.crash_count, _ = read_u32(*buf);
        entry.restart_count, _ = read_u32(*buf);
        
        array_add(*res, entry);
    }
    
    return res, true;
}
