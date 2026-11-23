//
// JPM — Process Supervisor Core (Spawn, Backoff, Watchdogs, Telemetry)
//

#import "Basic";
#import "String";
#import "File";
#import "File_Utilities";
#import "Process";
#import "types";
#import "platform";
#import "logger";
#import "state";

Supervisor_Entry :: struct {
    config:             Process_Config;
    handle:             Platform_Process_Handle;
    status:             Process_Status = .STOPPED;
    start_time:         Apollo_Time;
    retry_count:        u32;
    crash_count:        u32;
    restart_count:      u32;
    next_allowed_start: Apollo_Time;
    awaiting_restart:   bool;
    intentional_stop:   bool;
    latest_telemetry:   Telemetry_Sample;
    telemetry_history:  [..] Telemetry_Sample;
    last_event:         string;
}

supervisor_entries: [..] Supervisor_Entry;

normalize_log_paths :: (cfg: *Process_Config) {
    default_log_dir := platform_get_default_log_dir();
    make_directory_if_it_does_not_exist(default_log_dir, recursive = true);
    
    if cfg.log_out.count == 0 {
        cfg.log_out = copy_string(tprint("%\\%.out.txt", default_log_dir, cfg.name));
    }
    if cfg.log_err.count == 0 {
        cfg.log_err = copy_string(tprint("%\\%.err.txt", default_log_dir, cfg.name));
    }
    if cfg.log_events.count == 0 {
        cfg.log_events = copy_string(tprint("%\\%.events.txt", default_log_dir, cfg.name));
    }
}

supervisor_init :: () {
    // Restore state from disk if exists
    persisted, ok := load_daemon_state();
    if ok {
        for * p: persisted {
            entry: Supervisor_Entry;
            entry.config = p.config;
            entry.crash_count = p.crash_count;
            entry.restart_count = p.restart_count;
            entry.status = .STOPPED;
            normalize_log_paths(*entry.config);
            array_add(*supervisor_entries, entry);
            
            // Auto-start apps if restart policy is ALWAYS or ON_FAILURE
            if entry.config.restart_policy != .NEVER {
                supervisor_start(*supervisor_entries[supervisor_entries.count - 1]);
            }
        }
    }
}

supervisor_save :: () {
    items: [..] Persisted_Entry;
    array_reserve(*items, supervisor_entries.count);
    for * e: supervisor_entries {
        p: Persisted_Entry;
        p.config = e.config;
        p.crash_count = e.crash_count;
        p.restart_count = e.restart_count;
        array_add(*items, p);
    }
    defer array_free(items);
    save_daemon_state(items);
}

supervisor_find :: (target: string) -> *Supervisor_Entry {
    for * e: supervisor_entries {
        if equal(e.config.name, target) return e;
        
        // Also check if target is a file or path contained in command
        if find_index_from_left(e.config.command, target) >= 0 return e;
    }
    return null;
}

supervisor_start :: (entry: *Supervisor_Entry) -> bool {
    normalize_log_paths(*entry.config);
    
    // Ensure parent directories of logs exist
    dir_out, _ := path_decomp(entry.config.log_out);
    if dir_out.count > 0 make_directory_if_it_does_not_exist(dir_out, recursive = true);
    dir_err, _ := path_decomp(entry.config.log_err);
    if dir_err.count > 0 make_directory_if_it_does_not_exist(dir_err, recursive = true);
    
    ok, handle, pid := platform_spawn_process(
        entry.config.command,
        entry.config.cwd,
        entry.config.env_vars,
        entry.config.log_out,
        entry.config.log_err,
        entry.config.hard_memory_max
    );
    
    if !ok {
        entry.status = .CRASHED;
        entry.last_event = copy_string("Failed to spawn process");
        log_lifecycle_event(entry.config.log_events, "CRASHED", tprint("reason=\"failed_to_spawn\" cmd=\"%\"", entry.config.command));
        return false;
    }
    
    entry.handle = handle;
    entry.status = .RUNNING;
    entry.start_time = current_time_monotonic();
    entry.intentional_stop = false;
    entry.awaiting_restart = false;
    entry.last_event = copy_string(tprint("STARTED pid=%", pid));
    
    log_lifecycle_event(entry.config.log_events, "STARTED", tprint("pid=% cmd=\"%\"", pid, entry.config.command));
    supervisor_save();
    return true;
}

supervisor_stop :: (entry: *Supervisor_Entry, reason: string = "manual_stop") {
    if entry.status == .RUNNING {
        entry.intentional_stop = true;
        entry.awaiting_restart = false;
        pid := entry.handle.pid;
        
        platform_kill_process_tree(entry.handle);
        entry.status = .STOPPED;
        entry.handle.pid = 0;
        entry.last_event = copy_string(tprint("STOPPED reason=\"%\"", reason));
        
        log_lifecycle_event(entry.config.log_events, "STOPPED", tprint("pid=% reason=\"%\" exit_code=0", pid, reason));
        supervisor_save();
    }
}

supervisor_restart :: (entry: *Supervisor_Entry, reason: string = "restart") {
    if entry.status == .RUNNING {
        supervisor_stop(entry, reason);
    }
    entry.restart_count += 1;
    supervisor_start(entry);
}

supervisor_register :: (cfg: Process_Config) -> (entry: *Supervisor_Entry, err: string) {
    existing := supervisor_find(cfg.name);
    if existing != null {
        // Update existing config
        existing.config = cfg;
        normalize_log_paths(*existing.config);
        if existing.status == .RUNNING {
            supervisor_restart(existing, "config_update");
        } else {
            supervisor_start(existing);
        }
        return existing, "";
    }
    
    new_entry: Supervisor_Entry;
    new_entry.config = cfg;
    normalize_log_paths(*new_entry.config);
    array_add(*supervisor_entries, new_entry);
    
    ptr := *supervisor_entries[supervisor_entries.count - 1];
    ok := supervisor_start(ptr);
    if !ok return ptr, "Failed to start process";
    
    return ptr, "";
}

supervisor_unregister :: (target: string) -> bool {
    idx := -1;
    for i: 0..supervisor_entries.count-1 {
        e := *supervisor_entries[i];
        if equal(e.config.name, target) || find_index_from_left(e.config.command, target) >= 0 {
            idx = i;
            break;
        }
    }
    
    if idx < 0 return false;
    
    e := *supervisor_entries[idx];
    if e.status == .RUNNING {
        supervisor_stop(e, "unregistered");
    }
    
    log_lifecycle_event(e.config.log_events, "UNREGISTERED", tprint("name=%", e.config.name));
    array_ordered_remove_by_index(*supervisor_entries, idx);
    supervisor_save();
    return true;
}

supervisor_clean :: () {
    i := 0;
    while i < supervisor_entries.count {
        e := *supervisor_entries[i];
        if e.status != .RUNNING {
            // Rotate remaining log files
            rotate_log_file_if_needed(e.config.log_out, 0, e.config.max_backups);
            rotate_log_file_if_needed(e.config.log_err, 0, e.config.max_backups);
            array_ordered_remove_by_index(*supervisor_entries, i);
        } else {
            // Rotate log files if exceeded max_size
            rotate_log_file_if_needed(e.config.log_out, e.config.max_log_size, e.config.max_backups);
            rotate_log_file_if_needed(e.config.log_err, e.config.max_log_size, e.config.max_backups);
            rotate_log_file_if_needed(e.config.log_events, e.config.max_log_size, e.config.max_backups);
            i += 1;
        }
    }
    supervisor_save();
}

supervisor_tick :: () {
    now := current_time_monotonic();
    
    for * e: supervisor_entries {
        if e.status == .RUNNING {
            // 1. Check if process has terminated
            is_running, exit_code := platform_poll_process_status(e.handle);
            if !is_running {
                pid := e.handle.pid;
                e.handle.pid = 0;
                
                if e.intentional_stop {
                    e.status = .STOPPED;
                    e.last_event = copy_string("Stopped gracefully");
                } else {
                    if exit_code == 0 {
                        e.status = .STOPPED;
                        e.last_event = copy_string("Exited with code 0");
                        log_lifecycle_event(e.config.log_events, "STOPPED", tprint("pid=% reason=\"clean_exit\" exit_code=0", pid));
                        
                        if e.config.restart_policy == .ALWAYS {
                            e.awaiting_restart = true;
                            e.next_allowed_start = now + milliseconds_to_apollo(cast(s64)e.config.backoff_ms);
                        }
                    } else {
                        // Crashed!
                        e.status = .CRASHED;
                        e.crash_count += 1;
                        e.last_event = copy_string(tprint("CRASHED exit_code=0x%X", exit_code));
                        log_lifecycle_event(e.config.log_events, "CRASHED", tprint("pid=% exit_code=0x%X reason=\"crash\"", pid, exit_code));
                        
                        if e.config.restart_policy != .NEVER && e.retry_count < e.config.max_retries {
                            // Exponential backoff
                            backoff := cast(s64)e.config.backoff_ms * (1 << e.retry_count);
                            if backoff > 60_000 backoff = 60_000; // Cap at 60s
                            
                            e.awaiting_restart = true;
                            e.next_allowed_start = now + milliseconds_to_apollo(backoff);
                        }
                    }
                }
                supervisor_save();
                continue;
            }
            
            // 2. Poll telemetry
            sample := platform_query_telemetry(*e.handle);
            e.latest_telemetry = sample;
            
            // Keep rolling history of last 60 samples (2 minutes of 2s ticks)
            array_add(*e.telemetry_history, sample);
            if e.telemetry_history.count > 60 {
                array_ordered_remove_by_index(*e.telemetry_history, 0);
            }
            
            // 3. Evaluate Memory Rules
            for * rule: e.config.memory_rules {
                if rule.threshold_bytes == 0 continue;
                
                if sample.ram_rss_bytes >= rule.threshold_bytes {
                    if rule.continuous_violation_start == Apollo_Time.{} {
                        rule.continuous_violation_start = now;
                    }
                    
                    viol_dur := to_seconds(now - rule.continuous_violation_start);
                    if viol_dur >= cast(float64)rule.duration_sec {
                        // Check cooldown
                        cooldown_dur := to_seconds(now - rule.last_triggered_time);
                        if rule.last_triggered_time == Apollo_Time.{} || cooldown_dur >= cast(float64)rule.cooldown_sec {
                            rule.last_triggered_time = now;
                            
                            action_str := "";
                            if rule.action == .NOTIFY action_str = "notify";
                            else if rule.action == .RESTART action_str = "restart";
                            else if rule.action == .STOP action_str = "stop";
                            else if rule.action == .EXEC action_str = "exec";
                            
                            log_lifecycle_event(e.config.log_events, "WATCHDOG",
                                tprint("rss=% threshold=% action=%", format_bytes(sample.ram_rss_bytes), format_bytes(rule.threshold_bytes), action_str));
                            
                            if rule.action == {
                                case .NOTIFY;
                                    e.last_event = copy_string(tprint("WATCHDOG: % >= %", format_bytes(sample.ram_rss_bytes), format_bytes(rule.threshold_bytes)));
                                case .RESTART;
                                    supervisor_restart(e, "memory_watchdog_restart");
                                    break;
                                case .STOP;
                                    supervisor_stop(e, "memory_watchdog_stop");
                                    break;
                                case .EXEC;
                                    if rule.run_cmd.count > 0 {
                                        // Replace {{PID}} with actual PID
                                        cmd_to_run := replace(rule.run_cmd, "{{PID}}", tprint("%", sample.pid));
                                        #if OS == .WINDOWS {
                                            run_command(tprint("cmd.exe /c %", cmd_to_run));
                                        } else {
                                            run_command(tprint("/bin/sh -c \"%\"", cmd_to_run));
                                        }
                                    }
                            }
                        }
                    }
                } else {
                    // Reset violation start if below threshold
                    rule.continuous_violation_start = Apollo_Time.{};
                }
            }
            
            // 4. Check log file rotation
            rotate_log_file_if_needed(e.config.log_out, e.config.max_log_size, e.config.max_backups);
            rotate_log_file_if_needed(e.config.log_err, e.config.max_log_size, e.config.max_backups);
            rotate_log_file_if_needed(e.config.log_events, e.config.max_log_size, e.config.max_backups);
            
        } else if e.awaiting_restart {
            if now >= e.next_allowed_start {
                e.retry_count += 1;
                e.restart_count += 1;
                e.awaiting_restart = false;
                supervisor_start(e);
            }
        }
    }
}

supervisor_get_all_info :: () -> [..] Process_Info {
    res: [..] Process_Info;
    array_reserve(*res, supervisor_entries.count);
    
    now := current_time_monotonic();
    
    for * e: supervisor_entries {
        info: Process_Info;
        info.name = e.config.name;
        info.command = e.config.command;
        info.status = e.status;
        info.pid = e.handle.pid;
        if e.status == .RUNNING {
            info.uptime_sec = cast(u64)to_seconds(now - e.start_time);
            info.current_cpu = e.latest_telemetry.cpu_percent;
            info.current_rss = e.latest_telemetry.ram_rss_bytes;
            info.disk_read_bytes = e.latest_telemetry.disk_read_bytes;
            info.disk_write_bytes = e.latest_telemetry.disk_write_bytes;
        }
        info.hard_memory_max = e.config.hard_memory_max;
        info.crash_count = e.crash_count;
        info.restart_count = e.restart_count;
        info.last_event = e.last_event;
        info.log_out = e.config.log_out;
        info.log_err = e.config.log_err;
        info.log_events = e.config.log_events;
        
        array_add(*res, info);
    }
    
    return res;
}
