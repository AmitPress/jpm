//
// JPM — Cross-Platform Abstraction Interface
//

#import "Basic";
#import "String";
#import "types";

Platform_Process_Handle :: struct {
    pid:            u32;
    #if OS == .WINDOWS {
        process_handle: *void;
        job_handle:     *void;
        stdout_handle:  *void;
        stderr_handle:  *void;
    } else #if OS == .LINUX {
        pid_s32:        s32;
        stdout_fd:      s32 = -1;
        stderr_fd:      s32 = -1;
    }
    prev_cpu_time:  u64;
    prev_wall_time: Apollo_Time;
}

Platform_IPC_Server :: struct {
    #if OS == .WINDOWS {
        pipe_handle: *void;
    } else #if OS == .LINUX {
        server_fd:   s32 = -1;
    }
    is_valid: bool;
}

Platform_IPC_Client :: struct {
    #if OS == .WINDOWS {
        pipe_handle: *void;
    } else #if OS == .LINUX {
        client_fd:   s32 = -1;
    }
    is_connected: bool;
}

#if OS == .WINDOWS {
    #load "windows.jai";
} else #if OS == .LINUX {
    #load "linux.jai";
} else {
    #assert(false, "Unsupported Operating System for JPM");
}
