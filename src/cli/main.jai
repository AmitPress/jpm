//
// JPM — Command Line Interface (CLI) Client
//

#import "Basic";
#import "String";
#import "File";
#import "File_Utilities";
#import "types";
#import "protocol";
#import "config";
#import "platform";

ensure_daemon_connected :: () -> (ok: bool, client: Platform_IPC_Client) {
    ok_conn, client := platform_ipc_client_connect();
    if ok_conn return true, client;
    
    // Daemon is offline: auto-spawn detached
    print("[jpm] jpmd is offline. Spawning background daemon...\n");
    spawned := platform_spawn_daemon_detached();
    if !spawned {
        print("[jpm] Error: Could not start jpmd daemon executable.\n");
        return false, client;
    }
    
    // Retry connection up to 10 times (2 seconds total)
    for 1..10 {
        sleep_milliseconds(200);
        ok_conn, client = platform_ipc_client_connect();
        if ok_conn return true, client;
    }
    
    print("[jpm] Error: Timed out waiting for jpmd daemon to become responsive.\n");
    return false, client;
}

send_ipc_command :: (type: Message_Type, payload: string) -> (ok: bool, resp_type: Message_Type, resp_data: string) {
    ok_conn, client := ensure_daemon_connected();
    if !ok_conn return false, .RESPONSE_ERROR, "Daemon connection failed";
    defer platform_ipc_close(*client);
    
    header: Packet_Header;
    header.magic = PACKET_MAGIC;
    header.version = 1;
    header.type = type;
    header.payload_size = cast(u32)payload.count;
    
    // Write header
    ok_w := platform_ipc_write(client, cast(*u8)*header, size_of(Packet_Header));
    if !ok_w return false, .RESPONSE_ERROR, "Failed to send packet header";
    
    // Write payload
    if header.payload_size > 0 {
        ok_p := platform_ipc_write(client, payload.data, header.payload_size);
        if !ok_p return false, .RESPONSE_ERROR, "Failed to send packet payload";
    }
    
    // Read response header
    resp_hdr: Packet_Header;
    _, ok_rh := platform_ipc_read(client, cast(*u8)*resp_hdr, size_of(Packet_Header));
    if !ok_rh || resp_hdr.magic != PACKET_MAGIC {
        return false, .RESPONSE_ERROR, "Invalid response from daemon";
    }
    
    // Read response payload
    resp_str: string;
    if resp_hdr.payload_size > 0 {
        buf := alloc(resp_hdr.payload_size);
        _, ok_rp := platform_ipc_read(client, cast(*u8)buf, resp_hdr.payload_size);
        if !ok_rp return false, .RESPONSE_ERROR, "Failed to read response payload";
        resp_str.data = buf;
        resp_str.count = resp_hdr.payload_size;
    }
    
    return true, resp_hdr.type, resp_str;
}

print_help :: () {
    print("\n");
    print("JPM — Jai Process Manager (CLI)\n");
    print("--------------------------------------------------------------------------------\n");
    print("Usage: jpm [command] [options]\n\n");
    print("Commands:\n");
    print("  --register <config.yml>              Register and supervise a process from YAML\n");
    print("  --unregister <target>                Gracefully stop and unsupervise a process\n");
    print("  --register-template <type> <file>    Quick-register (types: jar, node, python, binary)\n");
    print("  --show [name]                        Display live telemetry table or process event history\n");
    print("  --clean                              Purge stopped/crashed processes and rotate logs\n");
    print("  --gui                                Launch JPM Desktop GUI dashboard\n");
    print("  --help, -h                           Show this help message\n");
    print("--------------------------------------------------------------------------------\n\n");
}

print_status_table :: (infos: [] Process_Info) {
    if infos.count == 0 {
        print("\nNo processes currently managed by JPM.\n\n");
        return;
    }
    
    print("\n+--------------------+---------+-------+----------+--------+--------------------+------------+---------+------------------------------+\n");
    print("| Process Name       | Status  | PID   | Uptime   | CPU %  | RAM (RSS / Limit)  | Disk R/W   | Crashes | Last Event                   |\n");
    print("+--------------------+---------+-------+----------+--------+--------------------+------------+---------+------------------------------+\n");
    
    for info: infos {
        status_str := "STOPPED";
        if info.status == .RUNNING status_str = "RUNNING";
        else if info.status == .CRASHED status_str = "CRASHED";
        
        limit_str := ifx info.hard_memory_max > 0 then format_bytes(info.hard_memory_max) else "unlimited";
        ram_str := tprint("% / %", format_bytes(info.current_rss), limit_str);
        disk_str := tprint("% / %", format_bytes(info.disk_read_bytes), format_bytes(info.disk_write_bytes));
        uptime_str := format_duration(info.uptime_sec);
        
        print("| %-18 | %-7 | %-5 | %-8 | %5.1f%% | %-18 | %-10 | %-7 | %-28 |\n",
            slice(info.name, 0, min(info.name.count, 18)),
            status_str,
            info.pid,
            uptime_str,
            info.current_cpu,
            slice(ram_str, 0, min(ram_str.count, 18)),
            slice(disk_str, 0, min(disk_str.count, 10)),
            info.crash_count,
            slice(info.last_event, 0, min(info.last_event.count, 28))
        );
    }
    print("+--------------------+---------+-------+----------+--------+--------------------+------------+---------+------------------------------+\n\n");
}

main :: () {
    args := get_command_line_arguments();
    defer array_free(args);
    
    if args.count <= 1 {
        print_help();
        return;
    }
    
    cmd := args[1];
    
    if cmd == "--help" || cmd == "-h" {
        print_help();
    } else if cmd == "--register" {
        if args.count < 3 {
            print("[jpm] Error: Expected config file path. Usage: jpm --register <config.yml>\n");
            return;
        }
        config_path := args[2];
        yaml_content, ok_read := read_entire_file(config_path);
        if !ok_read {
            print("[jpm] Error: Could not read configuration file '%'\n", config_path);
            return;
        }
        defer free(yaml_content);
        
        ok, r_type, resp := send_ipc_command(.REGISTER_CONFIG, yaml_content);
        if !ok || r_type == .RESPONSE_ERROR {
            print("[jpm] Failed to register: %\n", resp);
        } else {
            print("[jpm] %\n", resp);
        }
    } else if cmd == "--unregister" {
        if args.count < 3 {
            print("[jpm] Error: Expected target name. Usage: jpm --unregister <target>\n");
            return;
        }
        target := args[2];
        ok, r_type, resp := send_ipc_command(.UNREGISTER, target);
        if !ok || r_type == .RESPONSE_ERROR {
            print("[jpm] Failed to unregister: %\n", resp);
        } else {
            print("[jpm] %\n", resp);
        }
    } else if cmd == "--register-template" {
        if args.count < 4 {
            print("[jpm] Error: Usage: jpm --register-template <jar|node|python|binary> <file>\n");
            return;
        }
        tmpl_type := args[2];
        file_path := args[3];
        payload := tprint("%\n%", tmpl_type, file_path);
        
        ok, r_type, resp := send_ipc_command(.REGISTER_TEMPLATE, payload);
        if !ok || r_type == .RESPONSE_ERROR {
            print("[jpm] Failed to register template: %\n", resp);
        } else {
            print("[jpm] %\n", resp);
        }
    } else if cmd == "--show" {
        target := "";
        if args.count >= 3 target = args[2];
        
        if target.count > 0 {
            // Query specific process and print event audit trail
            ok, r_type, resp := send_ipc_command(.GET_STATUS_ONE, target);
            if !ok || r_type == .RESPONSE_ERROR {
                print("[jpm] Error: %\n", resp);
                return;
            }
            
            buf: Byte_Buffer;
            buf.data.data = resp.data;
            buf.data.count = resp.count;
            infos, ok_list := deserialize_process_info_list(*buf);
            if ok_list && infos.count > 0 {
                info := infos[0];
                print("\nProcess: %\n", info.name);
                print("Command: %\n", info.command);
                print("PID:     %\n", info.pid);
                print("Status:  %\n", info.status);
                print("CPU:     %.1f%%\n", info.current_cpu);
                print("RAM:     %\n", format_bytes(info.current_rss));
                print("Crashes: %\n", info.crash_count);
                print("Logs:    %\n", info.log_events);
                
                // Read and print events.txt if exists
                if info.log_events.count > 0 && file_exists(info.log_events) {
                    print("\n--- Event Audit Trail (Last entries) ---\n");
                    content, ok_f := read_entire_file(info.log_events);
                    if ok_f {
                        defer free(content);
                        lines := split(content, "\n");
                        defer array_free(lines);
                        start_idx := max(0, lines.count - 25);
                        for i: start_idx .. lines.count-1 {
                            if lines[i].count > 0 print("%\n", lines[i]);
                        }
                    }
                }
                print("\n");
            } else {
                print("[jpm] No process found matching '%'\n", target);
            }
        } else {
            // Query all processes
            ok, r_type, resp := send_ipc_command(.GET_STATUS_ALL, "");
            if !ok || r_type == .RESPONSE_ERROR {
                print("[jpm] Error: %\n", resp);
                return;
            }
            
            buf: Byte_Buffer;
            buf.data.data = resp.data;
            buf.data.count = resp.count;
            infos, ok_list := deserialize_process_info_list(*buf);
            if ok_list {
                print_status_table(infos);
            } else {
                print("[jpm] Failed to decode status list from daemon.\n");
            }
        }
    } else if cmd == "--clean" {
        ok, r_type, resp := send_ipc_command(.CLEAN, "");
        if !ok || r_type == .RESPONSE_ERROR {
            print("[jpm] Error during clean: %\n", resp);
        } else {
            print("[jpm] %\n", resp);
        }
    } else if cmd == "--gui" {
        ok, r_type, resp := send_ipc_command(.LAUNCH_GUI, "");
        if !ok || r_type == .RESPONSE_ERROR {
            // Direct launch fallback
            if platform_spawn_gui_detached() {
                print("[jpm] Desktop GUI dashboard launched.\n");
            } else {
                print("[jpm] Failed to launch GUI dashboard binary.\n");
            }
        } else {
            print("[jpm] %\n", resp);
        }
    } else {
        print("[jpm] Unknown command '%'. Run 'jpm --help' for usage.\n", cmd);
    }
}
