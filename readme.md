# JPM — Jai Process Manager & Desktop GUI

A zero-dependency, cross-platform process manager, background supervisor daemon, and desktop dashboard built natively in the **Jai** programming language.

## Architecture

JPM consists of three native binaries compiled from a single build metaprogram:

1. **`jpm` (`jpm.exe`) — CLI Client:** Parses CLI flags, auto-spawns `jpmd` if offline, sends length-prefixed binary IPC requests, and prints live tabular telemetry and event histories.
2. **`jpmd` (`jpmd.exe`) — Supervisor Daemon:** Owns managed child processes, enforces Win32 Job Objects / cgroups memory ceilings, captures lifecycle timestamps, streams stdout/stderr/events to local `.txt` files with automatic rotation, polls telemetry (RAM/CPU/Disk) every 2 seconds, and executes memory watchdog actions (`notify`, `restart`, `stop`, `exec`).
3. **`jpm-ui` (`jpm-ui.exe`) — Hardware-Accelerated Desktop GUI:** Real-time desktop dashboard built with Jai's `Window_Creation` + `Simp` + `GetRect`. Renders live process tables, real-time rolling sparklines for CPU and RAM RSS, tabbed `.txt` log tailer, and one-click controls.

---

## Directory Structure

```text
jpm/
├── build.jai                     # Multi-workspace compiler script (builds jpm, jpmd, jpm-ui)
├── config.example.yml            # Example service configuration
├── src/
│   ├── shared/
│   │   ├── protocol.jai          # Packed binary IPC request/response structs & serialization
│   │   ├── config.jai            # Indentation-aware YAML parser & template generator
│   │   └── types.jai             # ProcessInfo, TelemetrySample, MemoryRule, LifecycleEvent
│   ├── daemon/
│   │   ├── daemon.jai            # Main event loop, 2s telemetry ticker, watchdog evaluator
│   │   ├── supervisor.jai        # Process spawn, restart backoff, crash vs. clean exit tracking
│   │   ├── logger.jai            # Local .txt writer + rotation (.out.txt, .err.txt, .events.txt)
│   │   └── state.jai             # Atomic binary state persistence (~/.jpm/state.jpm)
│   ├── cli/
│   │   └── main.jai              # CLI client (--register, --unregister, --show, --clean, --gui)
│   ├── gui/
│   │   ├── gui_main.jai          # Window_Creation + Simp 60 FPS render loop
│   │   ├── views.jai             # Process table, RAM/CPU sparklines, live .txt log viewer
│   │   └── theme.jai             # Dark-mode color palette and drawing primitives
│   └── platform/
│       ├── platform.jai          # Unified cross-platform procedure interfaces
│       ├── windows.jai           # Named Pipes, Win32 Job Objects, CreateProcessW, Win32 Telemetry
│       └── linux.jai             # Unix Domain Sockets, fork/exec, /proc Telemetry
```

---

## Compilation

Compile all three binaries with the Jai compiler:

```bash
jai build.jai
```

The resulting binaries will be placed in `bin/`:
- `bin/jpm.exe` (CLI)
- `bin/jpmd.exe` (Daemon)
- `bin/jpm-ui.exe` (Desktop GUI)

---

## CLI Usage

### Register and Supervise a Process
```bash
jpm --register config.example.yml
```

### Quick-Register from Built-In Templates
Automatically generates configuration and starts supervision for `.jar`, Node.js, Python, or native binaries:
```bash
jpm --register-template jar payment-service.jar
jpm --register-template node server.js
jpm --register-template python worker.py
```

### Display Status and Telemetry
Print real-time status table of all managed processes:
```bash
jpm --show
```

Print detailed telemetry and last 25 events from `<name>.events.txt`:
```bash
jpm --show payment-service
```

### Unregister a Process
Gracefully stops process tree, logs unregistration event, and removes from supervision:
```bash
jpm --unregister payment-service
```

### Clean Dead Processes & Rotate Logs
```bash
jpm --clean
```

### Launch Desktop GUI
```bash
jpm --gui
```

---

## Structured Audit Trail (`<name>.events.txt`)

Every lifecycle transition and watchdog event is recorded in a single-line format:

```text
[2026-11-23 19:40:02] STARTED   pid=14820 cmd="java -Xmx1g -jar payment-service.jar"
[2026-11-23 19:42:10] WATCHDOG  rss=812MB threshold=800MB action=notify
[2026-11-23 19:45:44] WATCHDOG  rss=1420MB threshold=1.4GB action=restart
[2026-11-23 19:45:45] STOPPED   pid=14820 reason="memory_watchdog_restart" exit_code=1
[2026-11-23 19:45:46] STARTED   pid=19304 cmd="java -Xmx1g -jar payment-service.jar"
```
