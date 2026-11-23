//
// JPM — Linux Platform Implementation (Unix Domain Sockets, fork/exec, /proc Telemetry)
//

#import "Basic";
#import "String";
#import "POSIX";
#import "File";
#import "types";

SOCKET_PATH :: "/tmp/jpmd.sock";

#scope_export

platform_get_default_log_dir :: () -> string {
    home := getenv("HOME");
    if home.count == 0 home = "/tmp";
    dir := tprint("%/.jpm/logs", home);
    return copy_string(dir);
}

platform_get_default_state_path :: () -> string {
    home := getenv("HOME");
    if home.count == 0 home = "/tmp";
    path := tprint("%/.jpm/state.jpm", home);
    return copy_string(path);
}

platform_ipc_server_create :: () -> Platform_IPC_Server {
    server: Platform_IPC_Server;
    
    unlink(SOCKET_PATH.data);
    
    fd := socket(AF_UNIX, .SOCK_STREAM, 0);
    if fd < 0 {
        server.is_valid = false;
        return server;
    }
    
    addr: sockaddr_un;
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path.data, SOCKET_PATH.data, SOCKET_PATH.count);
    addr.sun_path[SOCKET_PATH.count] = 0;
    
    if bind(fd, cast(*sockaddr)*addr, size_of(sockaddr_un)) < 0 {
        close(fd);
        server.is_valid = false;
        return server;
    }
    
    if listen(fd, 128) < 0 {
        close(fd);
        server.is_valid = false;
        return server;
    }
    
    server.server_fd = fd;
    server.is_valid = true;
    return server;
}

platform_ipc_server_accept :: (server: *Platform_IPC_Server) -> (success: bool, client: Platform_IPC_Client) {
    client: Platform_IPC_Client;
    if !server.is_valid return false, client;
    
    cli_fd := accept(server.server_fd, null, null);
    if cli_fd < 0 return false, client;
    
    client.client_fd = cli_fd;
    client.is_connected = true;
    return true, client;
}

platform_ipc_client_connect :: () -> (success: bool, client: Platform_IPC_Client) {
    client: Platform_IPC_Client;
    
    fd := socket(AF_UNIX, .SOCK_STREAM, 0);
    if fd < 0 return false, client;
    
    addr: sockaddr_un;
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path.data, SOCKET_PATH.data, SOCKET_PATH.count);
    addr.sun_path[SOCKET_PATH.count] = 0;
    
    if connect(fd, cast(*sockaddr)*addr, size_of(sockaddr_un)) < 0 {
        close(fd);
        return false, client;
    }
    
    client.client_fd = fd;
    client.is_connected = true;
    return true, client;
}

platform_ipc_read :: (client: Platform_IPC_Client, buffer: *u8, bytes_to_read: u32) -> (bytes_read: u32, success: bool) {
    if !client.is_connected return 0, false;
    
    total_read: u32 = 0;
    while total_read < bytes_to_read {
        r := read(client.client_fd, buffer + total_read, bytes_to_read - total_read);
        if r <= 0 return total_read, false;
        total_read += cast(u32)r;
    }
    return total_read, true;
}

platform_ipc_write :: (client: Platform_IPC_Client, buffer: *u8, bytes_to_write: u32) -> (bytes_written: u32, success: bool) {
    if !client.is_connected return 0, false;
    
    total_written: u32 = 0;
    while total_written < bytes_to_write {
        w := write(client.client_fd, buffer + total_written, bytes_to_write - total_written);
        if w <= 0 return total_written, false;
        total_written += cast(u32)w;
    }
    return total_written, true;
}

platform_ipc_close :: (client: *Platform_IPC_Client) {
    if client.is_connected && client.client_fd >= 0 {
        close(client.client_fd);
        client.client_fd = -1;
        client.is_connected = false;
    }
}

platform_spawn_process :: (cmd: string, cwd: string, env: [] string, out_file: string, err_file: string, hard_memory_max: u64) -> (success: bool, handle: Platform_Process_Handle, pid: u32) {
    h: Platform_Process_Handle;
    
    pid := fork();
    if pid < 0 {
        return false, h, 0;
    }
    
    if pid == 0 {
        // Child process
        setpgid(0, 0); // New process group
        
        // Redirect stdout
        fd_out := open(temp_c_string(out_file), O_WRONLY | O_CREAT | O_APPEND, 0644);
        if fd_out >= 0 {
            dup2(fd_out, STDOUT_FILENO);
            close(fd_out);
        }
        
        // Redirect stderr
        fd_err := open(temp_c_string(err_file), O_WRONLY | O_CREAT | O_APPEND, 0644);
        if fd_err >= 0 {
            dup2(fd_err, STDERR_FILENO);
            close(fd_err);
        }
        
        if cwd.count > 0 {
            chdir(temp_c_string(cwd));
        }
        
        // Apply cgroup memory limits if present
        // (Optional Linux cgroup v2 integration)
        
        // Execute shell command
        c_cmd := temp_c_string(cmd);
        args: [*] *u8 = .["/bin/sh".data, "-c".data, c_cmd, null].data;
        execvp("/bin/sh".data, args);
        exit(127);
    }
    
    h.pid = cast(u32)pid;
    h.pid_s32 = pid;
    h.prev_wall_time = current_time_monotonic();
    return true, h, cast(u32)pid;
}

platform_poll_process_status :: (handle: Platform_Process_Handle) -> (is_running: bool, exit_code: u32) {
    status: s32 = 0;
    res := waitpid(handle.pid_s32, *status, WNOHANG);
    if res == 0 {
        return true, 0;
    }
    
    exit_code: u32 = 0;
    if WIFEXITED(status) {
        exit_code = cast(u32)WEXITSTATUS(status);
    } else if WIFSIGNALED(status) {
        exit_code = 128 + cast(u32)WTERMSIG(status);
    }
    return false, exit_code;
}

platform_kill_process_tree :: (handle: Platform_Process_Handle) {
    if handle.pid_s32 > 0 {
        // Kill whole process group
        kill(-handle.pid_s32, SIGTERM);
        sleep_milliseconds(50);
        kill(-handle.pid_s32, SIGKILL);
    }
}

platform_query_telemetry :: (handle: *Platform_Process_Handle) -> Telemetry_Sample {
    sample: Telemetry_Sample;
    sample.pid = handle.pid;
    sample.timestamp = current_time_monotonic();
    
    if handle.pid == 0 return sample;
    
    // Read /proc/<pid>/status for VmRSS
    status_path := tprint("/proc/%/status", handle.pid);
    status_content, ok_s := read_entire_file(status_path);
    if ok_s {
        defer free(status_content);
        idx := find_index_from_left(status_content, "VmRSS:");
        if idx >= 0 {
            line := slice(status_content, idx, status_content.count - idx);
            eol := find_index_from_left(line, "\n");
            if eol >= 0 line = slice(line, 0, eol);
            // e.g. VmRSS:   12345 kB
            parts := split(line, " ");
            for p: parts {
                if p == "VmRSS:" || p == "" || p == "kB" continue;
                kb, _ := string_to_int(p);
                sample.ram_rss_bytes = cast(u64)kb * 1024;
                break;
            }
        }
    }
    
    // Read /proc/<pid>/io for disk R/W
    io_path := tprint("/proc/%/io", handle.pid);
    io_content, ok_io := read_entire_file(io_path);
    if ok_io {
        defer free(io_content);
        lines := split(io_content, "\n");
        for l: lines {
            if begins_with(l, "read_bytes:") {
                val_str := trim(slice(l, 11, l.count - 11));
                v, _ := string_to_int(val_str);
                sample.disk_read_bytes = cast(u64)v;
            } else if begins_with(l, "write_bytes:") {
                val_str := trim(slice(l, 12, l.count - 12));
                v, _ := string_to_int(val_str);
                sample.disk_write_bytes = cast(u64)v;
            }
        }
    }
    
    // Read /proc/<pid>/stat for CPU
    stat_path := tprint("/proc/%/stat", handle.pid);
    stat_content, ok_stat := read_entire_file(stat_path);
    if ok_stat {
        defer free(stat_content);
        parts := split(stat_content, " ");
        if parts.count > 15 {
            utime, _ := string_to_int(parts[13]);
            stime, _ := string_to_int(parts[14]);
            current_cpu_ticks := cast(u64)(utime + stime);
            
            now := current_time_monotonic();
            wall_delta_ns := to_nanoseconds(now - handle.prev_wall_time);
            
            if handle.prev_cpu_time > 0 && wall_delta_ns > 0 {
                ticks_delta := current_cpu_ticks - handle.prev_cpu_time;
                // assume 100 Hz USER_HZ
                cpu_delta_ns := ticks_delta * 10_000_000;
                sample.cpu_percent = cast(float32)((cast(float64)cpu_delta_ns / cast(float64)wall_delta_ns) * 100.0);
            }
            
            handle.prev_cpu_time = current_cpu_ticks;
            handle.prev_wall_time = now;
        }
    }
    
    return sample;
}

platform_spawn_daemon_detached :: () -> bool {
    pid := fork();
    if pid == 0 {
        setsid();
        exe_path := "bin/jpmd";
        if !file_exists("bin/jpmd") && file_exists("jpmd") exe_path = "jpmd";
        args: [*] *u8 = .[temp_c_string(exe_path), null].data;
        execvp(temp_c_string(exe_path), args);
        exit(0);
    }
    return pid > 0;
}

platform_spawn_gui_detached :: () -> bool {
    pid := fork();
    if pid == 0 {
        setsid();
        exe_path := "bin/jpm-ui";
        if !file_exists("bin/jpm-ui") && file_exists("jpm-ui") exe_path = "jpm-ui";
        args: [*] *u8 = .[temp_c_string(exe_path), null].data;
        execvp(temp_c_string(exe_path), args);
        exit(0);
    }
    return pid > 0;
}
