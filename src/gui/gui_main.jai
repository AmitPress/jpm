//
// JPM — Desktop GUI Dashboard Main (Window_Creation + Simp + Input)
//

#import "Basic";
#import "String";
#import "Window_Creation";
#import "Simp";
#import "Input";
#import "File";
#import "File_Utilities";
#import "types";
#import "protocol";
#import "platform";
#import "theme";
#import "views";

#if OS == .WINDOWS {
    #import "Windows";
    #foreign_system_library "Comdlg32";
    
    OPENFILENAMEW :: struct {
        lStructSize:       u32;
        hwndOwner:         HWND;
        hInstance:         HINSTANCE;
        lpstrFilter:       *u16;
        lpstrCustomFilter: *u16;
        nMaxCustFilter:    u32;
        nFilterIndex:      u32;
        lpstrFile:         *u16;
        nMaxFile:          u32;
        lpstrFileTitle:    *u16;
        nMaxFileTitle:     u32;
        lpstrInitialDir:   *u16;
        lpstrTitle:        *u16;
        Flags:             u32;
        nFileOffset:       u16;
        nFileExtension:    u16;
        lpstrDefExt:       *u16;
        lCustData:         s64;
        lpfnHook:          *void;
        lpTemplateName:    *u16;
        pvReserved:        *void;
        dwReserved:        u32;
        FlagsEx:           u32;
    }
    
    GetOpenFileNameW :: (lpofn: *OPENFILENAMEW) -> s32 #foreign Comdlg32;
}

open_file_dialog :: (hwnd: *void) -> (path: string, ok: bool) {
    #if OS == .WINDOWS {
        ofn: OPENFILENAMEW;
        ofn.lStructSize = size_of(OPENFILENAMEW);
        ofn.hwndOwner = hwnd;
        
        file_buffer: [1024] u16;
        ofn.lpstrFile = file_buffer.data;
        ofn.nMaxFile = 1024;
        
        // Filter: Configuration (*.yml;*.yaml;*.jar)\0*.yml;*.yaml;*.jar\0All Files (*.*)\0*.*\0\0
        filter_str :: *u16.[
            #char "A", #char "p", #char "p", #char " ", #char "C", #char "o", #char "n", #char "f", #char "i", #char "g", #char " ",
            #char "(", #char "*", #char ".", #char "y", #char "m", #char "l", #char ";", #char "*", #char ".", #char "j", #char "a", #char "r", #char ")", 0,
            #char "*", #char ".", #char "y", #char "m", #char "l", #char ";", #char "*", #char ".", #char "y", #char "a", #char "m", #char "l", #char ";", #char "*", #char ".", #char "j", #char "a", #char "r", 0,
            0
        ];
        ofn.lpstrFilter = filter_str.data;
        ofn.nFilterIndex = 1;
        ofn.Flags = 0x00000800 | 0x00001000; // OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST
        
        if GetOpenFileNameW(*ofn) != 0 {
            // Convert wide string to utf-8 string
            len := 0;
            while file_buffer[len] != 0 && len < 1024 len += 1;
            
            str_data := alloc(len);
            for i: 0..len-1 {
                str_data[i] = cast(u8)file_buffer[i];
            }
            res: string;
            res.data = str_data;
            res.count = len;
            return res, true;
        }
    }
    return "", false;
}

send_gui_ipc :: (type: Message_Type, payload: string) -> (ok: bool, resp_type: Message_Type, resp: string) {
    ok_c, client := platform_ipc_client_connect();
    if !ok_c return false, .RESPONSE_ERROR, "";
    defer platform_ipc_close(*client);
    
    header: Packet_Header;
    header.magic = PACKET_MAGIC;
    header.version = 1;
    header.type = type;
    header.payload_size = cast(u32)payload.count;
    
    if !platform_ipc_write(client, cast(*u8)*header, size_of(Packet_Header)) return false, .RESPONSE_ERROR, "";
    if header.payload_size > 0 {
        if !platform_ipc_write(client, payload.data, header.payload_size) return false, .RESPONSE_ERROR, "";
    }
    
    resp_hdr: Packet_Header;
    _, ok_rh := platform_ipc_read(client, cast(*u8)*resp_hdr, size_of(Packet_Header));
    if !ok_rh || resp_hdr.magic != PACKET_MAGIC return false, .RESPONSE_ERROR, "";
    
    resp_str := "";
    if resp_hdr.payload_size > 0 {
        buf := alloc(resp_hdr.payload_size);
        _, ok_rp := platform_ipc_read(client, cast(*u8)buf, resp_hdr.payload_size);
        if !ok_rp return false, .RESPONSE_ERROR, "";
        resp_str.data = buf;
        resp_str.count = resp_hdr.payload_size;
    }
    
    return true, resp_hdr.type, resp_str;
}

main :: () {
    #if OS == .WINDOWS {
        Windows.SetProcessDPIAware();
    }
    
    // Auto-connect / auto-spawn jpmd if offline
    ok_c, test_cli := platform_ipc_client_connect();
    if ok_c {
        platform_ipc_close(*test_cli);
    } else {
        platform_spawn_daemon_detached();
        sleep_milliseconds(300);
    }
    
    win_w: s32 = 1280;
    win_h: s32 = 820;
    
    window := create_window(
        window_name = "JPM — Jai Process Manager Dashboard",
        width = win_w,
        height = win_h
    );
    
    Simp.set_render_dimensions(win_w, win_h);
    
    state: GUI_State;
    // Load default font
    state.font = Simp.get_font_at_size("C:/Windows/Fonts/segoeui.ttf", 14);
    if !state.font {
        state.font = Simp.get_font_at_size("C:/Windows/Fonts/arial.ttf", 14);
    }
    
    last_refresh := current_time_monotonic();
    last_selected_name := "";
    
    quit := false;
    while !quit {
        Input.update_window_events();
        
        mouse_clicked := false;
        for event: Input.get_window_events() {
            if event.type == .QUIT {
                quit = true;
                break;
            }
            if event.type == .KEYBOARD && event.key_pressed && event.key_code == .ESCAPE {
                quit = true;
                break;
            }
            if event.type == .MOUSE_BUTTON && event.key_pressed && event.key_code == .MOUSE_BUTTON_LEFT {
                mouse_clicked = true;
            }
        }
        
        mouse_x, mouse_y := get_mouse_pointer_position(window, true);
        mx := cast(float32)mouse_x;
        my := cast(float32)(win_h - mouse_y); // Invert Y for bottom-left origin
        
        // 1s Refresh ticker over IPC
        now := current_time_monotonic();
        if to_seconds(now - last_refresh) >= 1.0 {
            last_refresh = now;
            
            ok_ipc, r_type, resp := send_gui_ipc(.GET_STATUS_ALL, "");
            state.daemon_online = ok_ipc;
            
            if ok_ipc && r_type == .RESPONSE_STATUS {
                buf: Byte_Buffer;
                buf.data.data = resp.data;
                buf.data.count = resp.count;
                
                infos, ok_list := deserialize_process_info_list(*buf);
                if ok_list {
                    array_reset(*state.process_list);
                    for item: infos array_add(*state.process_list, item);
                    
                    // Maintain selection index if process still exists
                    if last_selected_name.count > 0 {
                        found_idx := -1;
                        for i: 0..state.process_list.count-1 {
                            if equal(state.process_list[i].name, last_selected_name) {
                                found_idx = cast(s32)i;
                                break;
                            }
                        }
                        state.selected_idx = found_idx;
                    }
                    
                    // Update rolling telemetry history for selected process
                    if state.selected_idx >= 0 && state.selected_idx < state.process_list.count {
                        p := *state.process_list[state.selected_idx];
                        array_add(*state.cpu_history, p.current_cpu);
                        array_add(*state.ram_history, p.current_rss);
                        if state.cpu_history.count > 60 array_ordered_remove_by_index(*state.cpu_history, 0);
                        if state.ram_history.count > 60 array_ordered_remove_by_index(*state.ram_history, 0);
                    }
                }
            }
        }
        
        // Keep track of selected process name
        if state.selected_idx >= 0 && state.selected_idx < state.process_list.count {
            if !equal(state.process_list[state.selected_idx].name, last_selected_name) {
                last_selected_name = copy_string(state.process_list[state.selected_idx].name);
                array_reset(*state.cpu_history);
                array_reset(*state.ram_history);
            }
        }
        
        // Handle Action Triggers from Buttons
        if state.trigger_register {
            state.trigger_register = false;
            file_path, ok_file := open_file_dialog(window);
            if ok_file {
                if ends_with_nocase(file_path, ".jar") {
                    send_gui_ipc(.REGISTER_TEMPLATE, tprint("jar\n%", file_path));
                } else {
                    yaml_content, ok_y := read_entire_file(file_path);
                    if ok_y {
                        defer free(yaml_content);
                        send_gui_ipc(.REGISTER_CONFIG, yaml_content);
                    }
                }
            }
        }
        
        if state.trigger_clean {
            state.trigger_clean = false;
            send_gui_ipc(.CLEAN, "");
        }
        
        if state.trigger_action > 0 {
            act := state.trigger_action;
            tgt := state.action_target;
            state.trigger_action = 0;
            state.action_target = "";
            
            if act == 4 { // Unregister
                send_gui_ipc(.UNREGISTER, tgt);
            } else { // 1=Start, 2=Stop, 3=Restart
                pbuf := init_byte_buffer();
                write_u8(*pbuf, act);
                write_string(*pbuf, tgt);
                payload: string;
                payload.data = pbuf.data.data;
                payload.count = pbuf.data.count;
                send_gui_ipc(.CONTROL_ACTION, payload);
                free_byte_buffer(*pbuf);
            }
        }
        
        // Render Frame
        Simp.clear_render_target(COLOR_BG.x, COLOR_BG.y, COLOR_BG.z, 1.0);
        
        w_f := cast(float32)win_w;
        h_f := cast(float32)win_h;
        
        action_bar_h: float32 = 56.0;
        drawer_h:     float32 = 280.0;
        table_h := h_f - action_bar_h - drawer_h - 16.0;
        
        // Top Action Bar
        draw_action_bar(*state, 8.0, h_f - action_bar_h - 8.0, w_f - 16.0, action_bar_h, mx, my, mouse_clicked);
        
        // Main Process Table
        draw_process_table(*state, 8.0, drawer_h + 12.0, w_f - 16.0, table_h, mx, my, mouse_clicked);
        
        // Bottom Inspector Drawer (Telemetry & Logs)
        draw_inspector_drawer(*state, 8.0, 8.0, w_f - 16.0, drawer_h, mx, my, mouse_clicked);
        
        Simp.swap_buffers(window);
        reset_temporary_storage();
        
        sleep_milliseconds(16); // Target ~60 FPS
    }
}
