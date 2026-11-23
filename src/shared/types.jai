//
// JPM — Process Manager Shared Types
//

#import "Basic";

Restart_Policy :: enum u8 {
    ALWAYS      :: 0;
    ON_FAILURE  :: 1;
    NEVER       :: 2;
}

Watchdog_Action :: enum u8 {
    NOTIFY  :: 0;
    RESTART :: 1;
    STOP    :: 2;
    EXEC    :: 3;
}

Process_Status :: enum u8 {
    STOPPED :: 0;
    RUNNING :: 1;
    CRASHED :: 2;
}

Memory_Rule :: struct {
    threshold_bytes:            u64;
    duration_sec:               u32;
    action:                     Watchdog_Action;
    run_cmd:                    string;
    cooldown_sec:               u32;
    
    // Runtime tracking state (daemon use)
    last_triggered_time:        Apollo_Time;
    continuous_violation_start: Apollo_Time;
}

Process_Config :: struct {
    name:             string;
    command:          string;
    cwd:              string;
    env_vars:         [..] string; // "KEY=VALUE"
    restart_policy:   Restart_Policy = .ON_FAILURE;
    max_retries:      u32 = 5;
    backoff_ms:       u32 = 1000;
    hard_memory_max:  u64 = 0; // 0 = unlimited
    memory_rules:     [..] Memory_Rule;
    log_out:          string;
    log_err:          string;
    log_events:       string;
    max_log_size:     u64 = 50 * 1024 * 1024; // 50MB
    max_backups:      u32 = 3;
}

Telemetry_Sample :: struct {
    timestamp:        Apollo_Time;
    pid:              u32;
    cpu_percent:      float32;
    ram_rss_bytes:    u64;
    disk_read_bytes:  u64;
    disk_write_bytes: u64;
}

Process_Info :: struct {
    name:             string;
    command:          string;
    status:           Process_Status;
    pid:              u32;
    uptime_sec:       u64;
    current_cpu:      float32;
    current_rss:      u64;
    hard_memory_max:  u64;
    disk_read_bytes:  u64;
    disk_write_bytes: u64;
    crash_count:      u32;
    restart_count:    u32;
    last_event:       string;
    log_out:          string;
    log_err:          string;
    log_events:       string;
}

format_bytes :: (bytes: u64) -> string {
    if bytes >= 1024 * 1024 * 1024 {
        gb := cast(float64)bytes / (1024.0 * 1024.0 * 1024.0);
        return tprint("%.2f GB", gb);
    } else if bytes >= 1024 * 1024 {
        mb := cast(float64)bytes / (1024.0 * 1024.0);
        return tprint("%.1f MB", mb);
    } else if bytes >= 1024 {
        kb := cast(float64)bytes / 1024.0;
        return tprint("%.1f KB", kb);
    }
    return tprint("% B", bytes);
}

format_duration :: (seconds: u64) -> string {
    d := seconds / (24 * 3600);
    h := (seconds % (24 * 3600)) / 3600;
    m := (seconds % 3600) / 60;
    s := seconds % 60;

    if d > 0 {
        return tprint("%1d %2h %3m", d, h, m);
    } else if h > 0 {
        return tprint("%1h %2m %3s", h, m, s);
    } else if m > 0 {
        return tprint("%1m %2s", m, s);
    }
    return tprint("%1s", s);
}
