//
// JPM — Background Supervisor Daemon Main Entry Point
//

#import "Basic";
#import "String";
#import "Thread";
#import "types";
#import "protocol";
#import "config";
#import "platform";
#import "logger";
#import "supervisor";
#import "state";

daemon_running := true;

handle_client :: (client: Platform_IPC_Client) {
    defer platform_ipc_close(*client);
    
    // Read packet header
    header: Packet_Header;
    read_bytes, ok_h := platform_ipc_read(client, cast(*u8)*header, size_of(Packet_Header));
    if !ok_h || header.magic != PACKET_MAGIC return;
    
    // Read payload
    payload: string;
    if header.payload_size > 0 {
        buf := alloc(header.payload_size);
        defer free(buf);
        read_p, ok_p := platform_ipc_read(client, cast(*u8)buf, header.payload_size);
        if !ok_p return;
        payload.data = buf;
        payload.count = header.payload_size;
    }
    
    // Process request
    resp_buf := init_byte_buffer();
    defer free_byte_buffer(*resp_buf);
    
    resp_type := Message_Type.RESPONSE_OK;
    
    if header.type == {
        case .REGISTER_CONFIG;
            cfg, ok := parse_yaml_config(payload);
            if !ok {
                resp_type = .RESPONSE_ERROR;
                write_string(*resp_buf, "Failed to parse YAML configuration");
            } else {
                _, err := supervisor_register(cfg);
                if err.count > 0 {
                    resp_type = .RESPONSE_ERROR;
                    write_string(*resp_buf, err);
                } else {
                    write_string(*resp_buf, tprint("Successfully registered '%'", cfg.name));
                }
            }
            
        case .REGISTER_TEMPLATE;
            // Payload format: "type\nfile_path"
            parts := split(payload, "\n");
            if parts.count < 2 {
                resp_type = .RESPONSE_ERROR;
                write_string(*resp_buf, "Invalid template arguments. Expected type and file.");
            } else {
                tmpl_type := parts[0];
                file_path := parts[1];
                cfg, yaml_str, ok := generate_template(tmpl_type, file_path);
                if !ok {
                    resp_type = .RESPONSE_ERROR;
                    write_string(*resp_buf, tprint("Unsupported template type '%' or invalid file", tmpl_type));
                } else {
                    _, err := supervisor_register(cfg);
                    if err.count > 0 {
                        resp_type = .RESPONSE_ERROR;
                        write_string(*resp_buf, err);
                    } else {
                        write_string(*resp_buf, tprint("Successfully registered template '%' for '%'", tmpl_type, cfg.name));
                    }
                }
            }
            
        case .UNREGISTER;
            ok := supervisor_unregister(payload);
            if !ok {
                resp_type = .RESPONSE_ERROR;
                write_string(*resp_buf, tprint("Could not find process matching '%'", payload));
            } else {
                write_string(*resp_buf, tprint("Successfully unregistered '%'", payload));
            }
            
        case .GET_STATUS_ALL;
            resp_type = .RESPONSE_STATUS;
            infos := supervisor_get_all_info();
            defer array_free(infos);
            serialize_process_info_list(*resp_buf, infos);
            
        case .GET_STATUS_ONE;
            entry := supervisor_find(payload);
            if entry == null {
                resp_type = .RESPONSE_ERROR;
                write_string(*resp_buf, tprint("Process '%' not found", payload));
            } else {
                resp_type = .RESPONSE_STATUS;
                infos: [1] Process_Info;
                all := supervisor_get_all_info();
                defer array_free(all);
                for it: all {
                    if equal(it.name, entry.config.name) {
                        infos[0] = it;
                        break;
                    }
                }
                serialize_process_info_list(*resp_buf, infos);
            }
            
        case .CONTROL_ACTION;
            // Payload: action: u8, target_name: string
            pbuf: Byte_Buffer;
            pbuf.data.data = payload.data;
            pbuf.data.count = payload.count;
            act, ok_a := read_u8(*pbuf);
            target, ok_t := read_string(*pbuf);
            
            entry := supervisor_find(target);
            if entry == null {
                resp_type = .RESPONSE_ERROR;
                write_string(*resp_buf, tprint("Process '%' not found", target));
            } else {
                if act == 1 { // START
                    if entry.status == .RUNNING {
                        write_string(*resp_buf, "Process is already running");
                    } else {
                        supervisor_start(entry);
                        write_string(*resp_buf, "Started process");
                    }
                } else if act == 2 { // STOP
                    supervisor_stop(entry, "manual_stop");
                    write_string(*resp_buf, "Stopped process");
                } else if act == 3 { // RESTART
                    supervisor_restart(entry, "manual_restart");
                    write_string(*resp_buf, "Restarted process");
                }
            }
            
        case .CLEAN;
            supervisor_clean();
            write_string(*resp_buf, "Purged dead processes and rotated log files");
            
        case .LAUNCH_GUI;
            ok := platform_spawn_gui_detached();
            if ok {
                write_string(*resp_buf, "GUI launched");
            } else {
                resp_type = .RESPONSE_ERROR;
                write_string(*resp_buf, "Failed to launch GUI binary");
            }
            
        case;
            resp_type = .RESPONSE_ERROR;
            write_string(*resp_buf, "Unknown IPC message type");
    }
    
    // Send response packet
    resp_header: Packet_Header;
    resp_header.magic = PACKET_MAGIC;
    resp_header.version = 1;
    resp_header.type = resp_type;
    resp_header.payload_size = cast(u32)resp_buf.data.count;
    
    platform_ipc_write(client, cast(*u8)*resp_header, size_of(Packet_Header));
    if resp_header.payload_size > 0 {
        platform_ipc_write(client, resp_buf.data.data, resp_header.payload_size);
    }
}

ipc_worker_proc :: (thread: *Thread) -> s64 {
    server := cast(*Platform_IPC_Server)thread.data;
    
    while daemon_running {
        ok, client := platform_ipc_server_accept(server);
        if ok {
            handle_client(client);
        } else {
            sleep_milliseconds(50);
        }
    }
    return 0;
}

main :: () {
    print("[jpmd] Starting JPM Supervisor Daemon...\n");
    
    supervisor_init();
    
    server := platform_ipc_server_create();
    if !server.is_valid {
        print("[jpmd] Error: Could not initialize IPC server (another instance running?). Exiting.\n");
        return;
    }
    
    // Launch background thread for IPC requests
    ipc_thread: Thread;
    thread_init(*ipc_thread, ipc_worker_proc);
    ipc_thread.data = *server;
    thread_start(*ipc_thread);
    
    print("[jpmd] JPM Supervisor Daemon is online and listening for IPC.\n");
    
    // Main event loop (2s telemetry ticker)
    last_tick := current_time_monotonic();
    while daemon_running {
        now := current_time_monotonic();
        elapsed_sec := to_seconds(now - last_tick);
        
        if elapsed_sec >= 2.0 {
            supervisor_tick();
            last_tick = now;
            
            // Periodically reset temporary storage to prevent heap fragmentation
            reset_temporary_storage();
        }
        
        sleep_milliseconds(100);
    }
}
