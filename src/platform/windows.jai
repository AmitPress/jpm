//
// JPM — Windows Platform Implementation (Named Pipes, Job Objects, CreateProcessW, Win32 Telemetry)
//

#import "Basic";
#import "String";
#import "Windows";
#import "types";

#foreign_system_library "Kernel32";
#foreign_system_library "Psapi";
#foreign_system_library "Advapi32";

#scope_file

PIPE_NAME_W: [14] u16 = .[ 92, 92, 46, 92, 112, 105, 112, 101, 92, 106, 112, 109, 100, 0 ]; // "\\.\pipe\jpmd"

PIPE_ACCESS_DUPLEX       :: 0x00000003;
PIPE_TYPE_BYTE           :: 0x00000000;
PIPE_READMODE_BYTE       :: 0x00000000;
PIPE_WAIT                :: 0x00000000;
PIPE_UNLIMITED_INSTANCES :: 255;

FILE_FLAG_OVERLAPPED     :: 0x40000000;
FILE_APPEND_DATA         :: 0x00000004;

CREATE_SUSPENDED         :: 0x00000004;
CREATE_NO_WINDOW         :: 0x08000000;
CREATE_NEW_PROCESS_GROUP :: 0x00000200;
DETACHED_PROCESS         :: 0x00000008;
STARTF_USESTDHANDLES     :: 0x00000100;

JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000;
JOB_OBJECT_LIMIT_PROCESS_MEMORY    :: 0x00000100;
JobObjectExtendedLimitInformation  :: 9;

JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
    PerProcessUserTimeLimit: s64;
    PerJobUserTimeLimit:     s64;
    LimitFlags:              u32;
    MinimumWorkingSetSize:   u64;
    MaximumWorkingSetSize:   u64;
    ActiveProcessLimit:      u32;
    Affinity:                u64;
    PriorityClass:           u32;
    SchedulingClass:         u32;
}

JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION;
    IoInfo:                IO_COUNTERS;
    ProcessMemoryLimit:    u64;
    JobMemoryLimit:        u64;
    PeakProcessMemoryLimit:u64;
    PeakJobMemoryLimit:    u64;
}

IO_COUNTERS :: struct {
    ReadOperationCount:  u64;
    WriteOperationCount: u64;
    OtherOperationCount: u64;
    ReadTransferCount:   u64;
    WriteTransferCount:  u64;
    OtherTransferCount:  u64;
}

PROCESS_MEMORY_COUNTERS :: struct {
    cb:                         u32;
    PageFaultCount:             u32;
    PeakWorkingSetSize:         u64;
    WorkingSetSize:             u64;
    QuotaPeakPagedPoolUsage:    u64;
    QuotaPagedPoolUsage:        u64;
    QuotaPeakNonPagedPoolUsage: u64;
    QuotaNonPagedPoolUsage:     u64;
    PagefileUsage:              u64;
    PeakPagefileUsage:          u64;
}

CreateJobObjectW :: (lpJobAttributes: *void, lpName: *u16) -> *void #foreign kernel32;
SetInformationJobObject :: (hJob: *void, JobObjectInformationClass: s32, lpJobObjectInformation: *void, cbJobObjectInformationLength: u32) -> s32 #foreign kernel32;
AssignProcessToJobObject :: (hJob: *void, hProcess: *void) -> s32 #foreign kernel32;
TerminateJobObject :: (hJob: *void, uExitCode: u32) -> s32 #foreign kernel32;

CreateNamedPipeW :: (lpName: *u16, dwOpenMode: u32, dwPipeMode: u32, nMaxInstances: u32, nOutBufferSize: u32, nInBufferSize: u32, nDefaultTimeOut: u32, lpSecurityAttributes: *void) -> *void #foreign kernel32;
ConnectNamedPipe :: (hNamedPipe: *void, lpOverlapped: *void) -> s32 #foreign kernel32;
DisconnectNamedPipe :: (hNamedPipe: *void) -> s32 #foreign kernel32;
WaitNamedPipeW :: (lpNamedPipeName: *u16, nTimeOut: u32) -> s32 #foreign kernel32;

GetProcessMemoryInfo :: (Process: *void, ppsmemCounters: *PROCESS_MEMORY_COUNTERS, cb: u32) -> s32 #foreign psapi;
GetProcessIoCounters :: (hProcess: *void, lpIoCounters: *IO_COUNTERS) -> s32 #foreign kernel32;
GetProcessTimes :: (hProcess: *void, lpCreationTime: *FILETIME, lpExitTime: *FILETIME, lpKernelTime: *FILETIME, lpUserTime: *FILETIME) -> s32 #foreign kernel32;
GetSystemInfo :: (lpSystemInfo: *SYSTEM_INFO) -> void #foreign kernel32;

SYSTEM_INFO :: struct {
    wProcessorArchitecture:      u16;
    wReserved:                   u16;
    dwPageSize:                  u32;
    lpMinimumApplicationAddress: *void;
    lpMaximumApplicationAddress: *void;
    dwActiveProcessorMask:       u64;
    dwNumberOfProcessors:        u32;
    dwProcessorType:             u32;
    dwAllocationGranularity:     u32;
    wProcessorLevel:             u16;
    wProcessorRevision:          u16;
}

to_wide :: (s: string) -> *u16 {
    if s.count == 0 return null;
    wstr := cast(*u16)alloc((s.count + 1) * 2);
    for i: 0..s.count-1 {
        wstr[i] = cast(u16)s[i];
    }
    wstr[s.count] = 0;
    return wstr;
}

#scope_export

platform_get_default_log_dir :: () -> string {
    home_c := getenv("USERPROFILE".data);
    home := ifx home_c != null then to_string(home_c) else "C:";
    dir := tprint("%\\.jpm\\logs", home);
    return copy_string(dir);
}

platform_get_default_state_path :: () -> string {
    home_c := getenv("USERPROFILE".data);
    home := ifx home_c != null then to_string(home_c) else "C:";
    path := tprint("%\\.jpm\\state.jpm", home);
    return copy_string(path);
}

platform_ipc_server_create :: () -> Platform_IPC_Server {
    server: Platform_IPC_Server;
    
    pipe := CreateNamedPipeW(
        PIPE_NAME_W.data,
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        65536,
        65536,
        5000,
        null
    );
    
    if pipe == INVALID_HANDLE_VALUE {
        server.is_valid = false;
        return server;
    }
    
    server.pipe_handle = pipe;
    server.is_valid = true;
    return server;
}

platform_ipc_server_accept :: (server: *Platform_IPC_Server) -> (success: bool, client: Platform_IPC_Client) {
    client: Platform_IPC_Client;
    if !server.is_valid return false, client;
    
    res := ConnectNamedPipe(server.pipe_handle, null);
    last_err := GetLastError();
    if res == 0 && last_err != ERROR_PIPE_CONNECTED {
        return false, client;
    }
    
    client.pipe_handle = server.pipe_handle;
    client.is_connected = true;
    
    // Create new pipe instance for next incoming client
    server.pipe_handle = CreateNamedPipeW(
        PIPE_NAME_W.data,
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        65536,
        65536,
        5000,
        null
    );
    if server.pipe_handle == INVALID_HANDLE_VALUE {
        server.is_valid = false;
    }
    
    return true, client;
}

platform_ipc_client_connect :: () -> (success: bool, client: Platform_IPC_Client) {
    client: Platform_IPC_Client;
    
    // Check if pipe exists or wait briefly
    WaitNamedPipeW(PIPE_NAME_W.data, 200);
    
    hPipe := CreateFileW(
        PIPE_NAME_W.data,
        GENERIC_READ | GENERIC_WRITE,
        0,
        null,
        OPEN_EXISTING,
        0,
        null
    );
    
    if hPipe == INVALID_HANDLE_VALUE {
        return false, client;
    }
    
    client.pipe_handle = hPipe;
    client.is_connected = true;
    return true, client;
}

platform_ipc_read :: (client: Platform_IPC_Client, buffer: *u8, bytes_to_read: u32) -> (bytes_read: u32, success: bool) {
    if !client.is_connected return 0, false;
    
    total_read: u32 = 0;
    while total_read < bytes_to_read {
        read_chunk: u32 = 0;
        ok := ReadFile(client.pipe_handle, buffer + total_read, bytes_to_read - total_read, *read_chunk, null);
        if ok == 0 || read_chunk == 0 {
            return total_read, false;
        }
        total_read += read_chunk;
    }
    return total_read, true;
}

platform_ipc_write :: (client: Platform_IPC_Client, buffer: *u8, bytes_to_write: u32) -> (bytes_written: u32, success: bool) {
    if !client.is_connected return 0, false;
    
    written: u32 = 0;
    ok := WriteFile(client.pipe_handle, buffer, bytes_to_write, *written, null);
    if ok == 0 || written != bytes_to_write {
        return written, false;
    }
    return written, true;
}

platform_ipc_close :: (client: *Platform_IPC_Client) {
    if client.is_connected && client.pipe_handle != INVALID_HANDLE_VALUE && client.pipe_handle != null {
        DisconnectNamedPipe(client.pipe_handle);
        CloseHandle(client.pipe_handle);
        client.pipe_handle = null;
        client.is_connected = false;
    }
}

platform_spawn_process :: (cmd: string, cwd: string, env: [] string, out_file: string, err_file: string, hard_memory_max: u64) -> (success: bool, handle: Platform_Process_Handle, pid: u32) {
    h: Platform_Process_Handle;
    
    // 1. Create Job Object
    hJob := CreateJobObjectW(null, null);
    if hJob == null || hJob == INVALID_HANDLE_VALUE {
        return false, h, 0;
    }
    
    info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if hard_memory_max > 0 {
        info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_PROCESS_MEMORY;
        info.ProcessMemoryLimit = hard_memory_max;
    }
    
    SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, *info, size_of(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    h.job_handle = hJob;
    
    // 2. Open stdout and stderr log files with inheritable handles
    sec_attr: SECURITY_ATTRIBUTES;
    sec_attr.nLength = size_of(SECURITY_ATTRIBUTES);
    sec_attr.bInheritHandle = 1;
    sec_attr.lpSecurityDescriptor = null;
    
    w_out := to_wide(out_file);
    defer free(w_out);
    h_out := CreateFileW(w_out, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, *sec_attr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    
    w_err := to_wide(err_file);
    defer free(w_err);
    h_err := CreateFileW(w_err, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, *sec_attr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    
    h.stdout_handle = h_out;
    h.stderr_handle = h_err;
    
    // 3. CreateProcessW
    si: STARTUPINFOW;
    si.cb = size_of(STARTUPINFOW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = ifx h_out != INVALID_HANDLE_VALUE then h_out else null;
    si.hStdError  = ifx h_err != INVALID_HANDLE_VALUE then h_err else null;
    si.hStdInput  = null;
    
    pi: PROCESS_INFORMATION;
    
    w_cmd := to_wide(tprint("cmd.exe /c %", cmd));
    defer free(w_cmd);
    
    w_cwd: *u16 = null;
    if cwd.count > 0 {
        w_cwd = to_wide(cwd);
    }
    defer if w_cwd free(w_cwd);
    
    flags := CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP;
    
    res := CreateProcessW(
        null,
        w_cmd,
        null,
        null,
        1, // Inherit handles (for stdout/stderr)
        flags,
        null,
        w_cwd,
        *si,
        *pi
    );
    
    if res == 0 {
        if hJob CloseHandle(hJob);
        if h_out != INVALID_HANDLE_VALUE CloseHandle(h_out);
        if h_err != INVALID_HANDLE_VALUE CloseHandle(h_err);
        return false, h, 0;
    }
    
    // Assign to Job Object
    AssignProcessToJobObject(hJob, pi.hProcess);
    
    // Resume process
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    
    h.pid = pi.dwProcessId;
    h.process_handle = pi.hProcess;
    h.prev_wall_time = current_time_monotonic();
    
    return true, h, pi.dwProcessId;
}

platform_poll_process_status :: (handle: Platform_Process_Handle) -> (is_running: bool, exit_code: u32) {
    if handle.process_handle == null || handle.process_handle == INVALID_HANDLE_VALUE {
        return false, 0;
    }
    
    res := WaitForSingleObject(handle.process_handle, 0);
    if res == WAIT_TIMEOUT {
        return true, 0;
    }
    
    exit_code: u32 = 0;
    GetExitCodeProcess(handle.process_handle, *exit_code);
    return false, exit_code;
}

platform_kill_process_tree :: (handle: Platform_Process_Handle) {
    if handle.job_handle != null && handle.job_handle != INVALID_HANDLE_VALUE {
        TerminateJobObject(handle.job_handle, 1);
        CloseHandle(handle.job_handle);
    }
    if handle.process_handle != null && handle.process_handle != INVALID_HANDLE_VALUE {
        TerminateProcess(handle.process_handle, 1);
        CloseHandle(handle.process_handle);
    }
    if handle.stdout_handle != null && handle.stdout_handle != INVALID_HANDLE_VALUE {
        CloseHandle(handle.stdout_handle);
    }
    if handle.stderr_handle != null && handle.stderr_handle != INVALID_HANDLE_VALUE {
        CloseHandle(handle.stderr_handle);
    }
}

platform_query_telemetry :: (handle: *Platform_Process_Handle) -> Telemetry_Sample {
    sample: Telemetry_Sample;
    sample.pid = handle.pid;
    sample.timestamp = current_time_monotonic();
    
    if handle.process_handle == null || handle.process_handle == INVALID_HANDLE_VALUE {
        return sample;
    }
    
    // 1. RAM RSS
    pmc: PROCESS_MEMORY_COUNTERS;
    pmc.cb = size_of(PROCESS_MEMORY_COUNTERS);
    if GetProcessMemoryInfo(handle.process_handle, *pmc, size_of(PROCESS_MEMORY_COUNTERS)) != 0 {
        sample.ram_rss_bytes = pmc.WorkingSetSize;
    }
    
    // 2. Disk I/O
    io: IO_COUNTERS;
    if GetProcessIoCounters(handle.process_handle, *io) != 0 {
        sample.disk_read_bytes = io.ReadTransferCount;
        sample.disk_write_bytes = io.WriteTransferCount;
    }
    
    // 3. CPU %
    creation_time, exit_time, kernel_time, user_time: FILETIME;
    if GetProcessTimes(handle.process_handle, *creation_time, *exit_time, *kernel_time, *user_time) != 0 {
        kt := (cast(u64)kernel_time.dwHighDateTime << 32) | cast(u64)kernel_time.dwLowDateTime;
        ut := (cast(u64)user_time.dwHighDateTime << 32) | cast(u64)user_time.dwLowDateTime;
        current_cpu_time := kt + ut;
        
        now := current_time_monotonic();
        wall_delta_ns := to_nanoseconds(now - handle.prev_wall_time);
        
        if handle.prev_cpu_time > 0 && wall_delta_ns > 0 {
            cpu_delta_100ns := current_cpu_time - handle.prev_cpu_time;
            cpu_delta_ns := cpu_delta_100ns * 100;
            
            sys_info: SYSTEM_INFO;
            GetSystemInfo(*sys_info);
            num_cpus := ifx sys_info.dwNumberOfProcessors > 0 then sys_info.dwNumberOfProcessors else 1;
            
            sample.cpu_percent = cast(float32)((cast(float64)cpu_delta_ns / cast(float64)wall_delta_ns) * 100.0 / cast(float64)num_cpus);
            if sample.cpu_percent > 100.0 sample.cpu_percent = 100.0;
        }
        
        handle.prev_cpu_time = current_cpu_time;
        handle.prev_wall_time = now;
    }
    
    return sample;
}

platform_spawn_daemon_detached :: () -> bool {
    si: STARTUPINFOW;
    si.cb = size_of(STARTUPINFOW);
    pi: PROCESS_INFORMATION;
    
    // Find path to jpmd.exe (same dir as jpm.exe or bin/jpmd.exe)
    cmd := "bin\\jpmd.exe";
    if !file_exists("bin\\jpmd.exe") && file_exists("jpmd.exe") {
        cmd = "jpmd.exe";
    }
    
    w_cmd := to_wide(cmd);
    defer free(w_cmd);
    
    res := CreateProcessW(null, w_cmd, null, null, 0, DETACHED_PROCESS, null, null, *si, *pi);
    if res != 0 {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return true;
    }
    return false;
}

platform_spawn_gui_detached :: () -> bool {
    si: STARTUPINFOW;
    si.cb = size_of(STARTUPINFOW);
    pi: PROCESS_INFORMATION;
    
    cmd := "bin\\jpm-ui.exe";
    if !file_exists("bin\\jpm-ui.exe") && file_exists("jpm-ui.exe") {
        cmd = "jpm-ui.exe";
    }
    
    w_cmd := to_wide(cmd);
    defer free(w_cmd);
    
    res := CreateProcessW(null, w_cmd, null, null, 0, DETACHED_PROCESS, null, null, *si, *pi);
    if res != 0 {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return true;
    }
    return false;
}
