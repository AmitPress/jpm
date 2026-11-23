# JPM — Jai Process Manager & Desktop GUI Specification

> **AI Implementation Directive:** Implement **JPM** in the **Jai** programming language as a native, zero-dependency, cross-platform suite with **first-class Windows support** (`#if OS == .WINDOWS` and `#if OS == .LINUX`). Use Jai's standard library (`Basic`, `String`, `File`, `File_Utilities`, `Process`, `Thread`, `Window_Creation`, `Simp`, `GetRect`, `Input`) and direct OS bindings (`Windows`, `POSIX`). Prefer `context.temporary_storage` (`temp`) with `reset_temporary_storage()` inside polling/render loops to avoid heap fragmentation.

---

## 1. System Architecture (3 Executables, 1 Build Script)

The system consists of three native binaries compiled from a single `build.jai` metaprogram:

1. **`jpm` (`jpm.exe`) — CLI Client:** Parses CLI arguments, auto-spawns `jpmd` detached if offline, sends length-prefixed binary IPC requests, and prints formatted tables or exits.
2. **`jpmd` (`jpmd.exe`) — Background Supervisor Daemon:** Owns all managed child processes, captures lifecycle timestamps, streams stdout/stderr/events to local `.txt` files, polls telemetry (RAM/CPU/Disk), enforces memory watchdogs, and serves IPC queries from both `jpm` (CLI) and `jpm-ui` (GUI).
3. **`jpm-ui` (`jpm-ui.exe`) — Native Jai GUI Dashboard:** Hardware-accelerated desktop dashboard built with `Window_Creation` + `Simp` + `GetRect`. Connects to `jpmd` over the same IPC channel to render live process tables, RAM/CPU sparklines, inline `.txt` log viewers, and one-click actions (Register, Start/Stop/Restart, Clean).

---

## 2. Project Directory Layout

```text
jpm/
├── build.jai                     # Multi-workspace compiler script (builds jpm, jpmd, jpm-ui)
├── src/
│   ├── shared/
│   │   ├── protocol.jai          # Packed binary IPC request/response structs & serialization
│   │   ├── config.jai            # Indentation-aware YAML parser & template generator (jar, etc.)
│   │   └── types.jai             # ProcessInfo, TelemetrySample, MemoryRule, LifecycleEvent structs
│   ├── daemon/
│   │   ├── daemon.jai            # Main event loop, 2s telemetry ticker, watchdog evaluator
│   │   ├── supervisor.jai        # Process spawn, restart backoff, crash vs. clean exit tracking
│   │   ├── logger.jai            # Local .txt writer (<name>.out.txt, .err.txt, .events.txt) + rotation
│   │   └── state.jai             # Atomic binary/JSON state persistence (~/.jpm/state.jpm)
│   ├── cli/
│   │   └── main.jai              # CLI flags (--register, --unregister, --register-template, --show, --clean)
│   ├── gui/
│   │   ├── gui_main.jai          # Window_Creation + Simp render loop (60 FPS / event-driven)
│   │   ├── views.jai             # Process table, RAM/CPU graphs, live .txt log tailer, config modal
│   │   └── theme.jai             # Dark-mode colors, fonts, layout metrics for GetRect
│   └── platform/
│       ├── platform.jai          # Unified cross-platform procedure headers
│       ├── windows.jai           # Named Pipes, Win32 Job Objects, CreateProcessW, Win32 Telemetry
│       └── linux.jai             # Unix Domain Sockets, fork/exec/waitpid, /proc parser, cgroups v2
```

---

## 3. CLI Specification (`jpm`)

All CLI commands must work identically in PowerShell, CMD, Windows Terminal, and Bash/Zsh:

| Command | Behavior |
| :--- | :--- |
| `jpm --register <config.yml>` | Validates YAML, normalizes Windows/Unix paths, persists config to daemon state, initializes `.txt` logs, and spawns the process. |
| `jpm --unregister <target>` | Accepts `config.yml`, process `name`, or filename (e.g., `app.jar`). Gracefully terminates process tree, logs stop event, and removes from supervision. |
| `jpm --register-template <type> <file>` | Generates an in-memory config for built-in templates (`jar`, `node`, `python`, `binary`). Example: `jpm --register-template jar app.jar` resolves `java` and sets working directory to the JAR's parent directory. |
| `jpm --show [name]` | Prints tabular telemetry (PID, Status, Uptime, CPU %, RAM RSS, Disk R/W, Log Size, Crashes, Last Event). Passing `[name]` prints full event history from `<name>.events.txt`. |
| `jpm --clean` | Purges stopped/crashed entries from daemon state and rotates/truncates `.txt` log files. |
| `jpm --gui` | Convenience flag that launches `jpm-ui` detached. |

---

## 4. Native Jai GUI Specification (`jpm-ui`)

Build with Jai's built-in `Window_Creation`, `Simp`, `Input`, and `GetRect` modules:

* **Connection & Auto-Start:** On startup, connects to `\\.\pipe\jpmd` (Windows) or `/tmp/jpmd.sock` (Unix). If `jpmd` is offline, spawns `jpmd` detached automatically.
* **Top Action Bar:**
  * `+ Register Config` (opens native OS file picker `GetOpenFileNameW` on Windows / GTK/zenity or path input on Linux for `.yml` or `.jar` quick-register).
  * `Clean Logs & Dead` (triggers `--clean`).
  * Daemon status indicator (`jpmd ONLINE` + total managed RAM/CPU).
* **Main Process Table (Live 1s–2s refresh):**
  * Columns: `Status Badge` (`RUNNING` green, `CRASHED` red, `STOPPED` gray), `Name`, `PID`, `Uptime`, `CPU %`, `RAM (RSS / Threshold)`, `Disk I/O (R/W)`, `Crashes`, `Last Event`, and inline action buttons (`Restart`, `Stop`, `Unregister`).
* **Bottom / Split Inspector Drawer (for selected process):**
  * **Telemetry History:** Real-time rolling line charts (drawn via `Simp.immediate_quad` / line primitives) for RAM usage (with horizontal threshold markers) and CPU %.
  * **Live `.txt` Log Viewer:** Tabbed viewer switching between `<name>.out.txt`, `<name>.err.txt`, and `<name>.events.txt` with auto-scroll toggle and keyword filter.

---

## 5. Local `.txt` Logging & Audit Format

All logs are written to `%USERPROFILE%\.jpm\logs\` (Windows) or `~/.jpm/logs/` (Unix) unless overridden in `config.yml`:

* `<name>.out.txt` — Raw child `stdout` stream.
* `<name>.err.txt` — Raw child `stderr` stream.
* `<name>.events.txt` — Structured single-line lifecycle & watchdog audit trail:

```text
[2026-11-19 07:10:02] STARTED   pid=14820 cmd="java -Xmx1g -jar payment-service.jar"
[2026-11-21 14:22:10] WATCHDOG  rss=812MB threshold=800MB action=notify
[2026-11-22 03:05:44] WATCHDOG  rss=1420MB threshold=1.4GB action=restart
[2026-11-22 03:05:45] STOPPED   pid=14820 reason="memory_watchdog_restart" exit_code=1
[2026-11-22 03:05:46] STARTED   pid=19304 cmd="java -Xmx1g -jar payment-service.jar"
```

---

## 6. Configuration Schema (`config.yml`)

```yaml
name: payment-service
command: java -Xmx1g -jar payment-service.jar
cwd: C:/services/payment

env:
  SPRING_PROFILES_ACTIVE: prod

restart:
  policy: on-failure        # always | on-failure | never
  max_retries: 5
  backoff_ms: 1000

limits:
  hard_memory_max: 1.5GB    # Enforced via Win32 Job Objects / Linux cgroups v2
  memory:
    - threshold: 800MB
      duration: 15s         # Must stay above threshold continuously for 15s
      action: notify        # notify | restart | stop | exec
      cooldown: 5m
    - threshold: 1.2GB
      duration: 5s
      action: exec
      run: "powershell -File ./scripts/heap_dump.ps1 {{PID}}"
    - threshold: 1.4GB
      duration: 5s
      action: restart

logs:
  out: ./logs/payment.out.txt
  err: ./logs/payment.err.txt
  events: ./logs/payment.events.txt
  max_size: 50MB            # Rotate to .1.txt, .2.txt when exceeded
  max_backups: 3
```

---

## 7. Platform Implementation Details (`src/platform/`)

### Windows (`src/platform/windows.jai`)
* **IPC:** `CreateNamedPipeW` (`\\.\pipe\jpmd`, `PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT`) on server; `CreateFileW` on `jpm` and `jpm-ui` clients.
* **Process & Child Tree Management:**
  * Create a Win32 Job Object per registered app (`CreateJobObjectW`) configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. If `hard_memory_max` is set, add `JOB_OBJECT_LIMIT_PROCESS_MEMORY` (`ProcessMemoryLimit`).
  * Spawn via `CreateProcessW` with `CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP`, assign handle via `AssignProcessToJobObject`, redirect `hStdOutput` and `hStdError` to inheritable file/pipe handles, then call `ResumeThread`.
* **Lifecycle & Crash Detection:**
  * Monitor process handles via `WaitForSingleObject` / `RegisterWaitForSingleObject`.
  * Call `GetExitCodeProcess`: exit code `0` or an internal `intentional_stop` flag records `STOPPED`; any non-zero exit code (e.g., `0xC0000005` Access Violation) records `CRASHED` and triggers the `restart` policy.
* **Telemetry (`#foreign_system_library "Kernel32"`, `"Psapi"`):**
  * **RAM:** `GetProcessMemoryInfo` -> `PROCESS_MEMORY_COUNTERS.WorkingSetSize`.
  * **CPU %:** `GetProcessTimes` -> delta of `(KernelTime + UserTime)` over wall-clock delta divided by logical processor count (`GetSystemInfo`).
  * **Disk I/O:** `GetProcessIoCounters` -> `IO_COUNTERS.ReadTransferCount` & `WriteTransferCount`.

### Linux (`src/platform/linux.jai`)
* **IPC:** `socket(AF_UNIX, SOCK_STREAM, 0)` bound to `/tmp/jpmd.sock`.
* **Process & Child Tree Management:** `fork()` -> `setpgid(0, 0)` -> redirect `STDOUT_FILENO`/`STDERR_FILENO` -> `execve()`. Optional `cgroups v2` slice (`/sys/fs/cgroup/jpm/<name>/memory.max`).
* **Lifecycle:** `waitpid(-1, &status, WNOHANG)` inspecting `WIFEXITED` / `WEXITSTATUS` and `WIFSIGNALED` / `WTERMSIG`.
* **Telemetry:** Read `/proc/<pid>/status` (`VmRSS`), `/proc/<pid>/stat` (`utime`, `stime`), and `/proc/<pid>/io` (`read_bytes`, `write_bytes`).

---

## 8. IPC Binary Wire Protocol (`src/shared/protocol.jai`)

Use a simple, endian-safe length-prefixed framing header over Named Pipes / Unix Sockets:

```jai
Message_Type :: enum u16 {
    REGISTER_CONFIG     :: 1;
    REGISTER_TEMPLATE   :: 2;
    UNREGISTER          :: 3;
    GET_STATUS_ALL      :: 4;
    GET_STATUS_ONE      :: 5;
    CONTROL_ACTION      :: 6; // start, stop, restart
    CLEAN               :: 7;
    RESPONSE_OK         :: 100;
    RESPONSE_ERROR      :: 101;
    RESPONSE_STATUS     :: 102;
}

Packet_Header :: struct {
    magic:        u32 = 0x4A504D31; // "JPM1"
    version:      u16 = 1;
    type:         Message_Type;
    payload_size: u32;
}
```

---

## 9. Build Script Blueprint (`build.jai`)

```jai
#import "Basic";
#import "Compiler";

#run {
    set_build_options_dc(.{do_output = false});

    build_target("jpmd",   "src/daemon/daemon.jai",  is_gui = false);
    build_target("jpm",    "src/cli/main.jai",       is_gui = false);
    build_target("jpm-ui", "src/gui/gui_main.jai",   is_gui = true);
}

build_target :: (exe_name: string, entry_file: string, is_gui: bool) {
    w := compiler_create_workspace(exe_name);
    options := get_build_options(w);
    options.output_executable_name = exe_name;
    options.output_path = "bin/";

    #if OS == .WINDOWS {
        if is_gui {
            // Suppress console window on Windows for the GUI executable
            options.additional_linker_arguments = .["/SUBSYSTEM:WINDOWS", "/ENTRY:mainCRTStartup"];
        }
    }

    set_build_options(options, w);
    add_build_file(entry_file, w);
}
```

---

## 10. Step-by-Step Implementation Order for AI

1. **Shared Types & Protocol (`src/shared/`):** Define `Process_Config`, `Telemetry_Sample`, `Memory_Rule`, `Packet_Header`, and binary serialization helpers.
2. **Platform Abstraction (`src/platform/windows.jai` & `linux.jai`):** Implement Named Pipe / Unix Socket IPC, child process spawning with stdout/stderr redirection, Job Object / process group tracking, and OS telemetry readers.
3. **Daemon Core (`src/daemon/`):** Build `jpmd` with a 2-second supervisor tick loop, `.txt` logger with rotation, crash/exit state tracking, and memory threshold watchdog actions (`notify`, `restart`, `stop`, `exec`).
4. **CLI Client (`src/cli/main.jai`):** Implement `--register`, `--unregister`, `--register-template jar`, `--show`, `--clean`, and `--gui`.
5. **Desktop GUI (`src/gui/`):** Build `jpm-ui` with `Window_Creation` + `Simp` + `GetRect`, rendering the live process table, RAM/CPU history charts, action buttons, and tabbed `.txt` log viewer.