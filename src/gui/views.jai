//
// JPM GUI — Views (Action Bar, Process Table, Telemetry Charts, Log Tailer)
//

#import "Basic";
#import "String";
#import "Simp";
#import "File";
#import "File_Utilities";
#import "types";
#import "theme";

Tab_Type :: enum {
    TELEMETRY :: 0;
    LOG_OUT   :: 1;
    LOG_ERR   :: 2;
    LOG_EVENTS:: 3;
}

GUI_State :: struct {
    daemon_online:     bool;
    process_list:      [..] Process_Info;
    selected_idx:      s32 = -1;
    active_tab:        Tab_Type = .TELEMETRY;
    
    // Telemetry rolling history for selected process (up to 60 points)
    cpu_history:       [..] float32;
    ram_history:       [..] u64;
    
    // Log viewer state
    log_lines:         [..] string;
    log_filter:        string;
    auto_scroll:       bool = true;
    log_scroll_y:      float32 = 0;
    
    // Action trigger flags
    trigger_register:  bool;
    trigger_clean:     bool;
    trigger_action:    u8; // 1 = start, 2 = stop, 3 = restart, 4 = unregister
    action_target:     string;
    
    font:              *Simp.Dynamic_Font;
}

is_point_in_rect :: (px: float32, py: float32, rx: float32, ry: float32, rw: float32, rh: float32) -> bool {
    return px >= rx && px <= rx + rw && py >= ry && py <= ry + rh;
}

draw_button :: (state: *GUI_State, x: float32, y: float32, w: float32, h: float32, label: string, mx: float32, my: float32, is_accent: bool = false) -> bool {
    hovered := is_point_in_rect(mx, my, x, y, w, h);
    
    bg_color := ifx is_accent then COLOR_ACCENT else COLOR_SURFACE;
    if hovered {
        bg_color = ifx is_accent then COLOR_ACCENT_HOVER else COLOR_SURFACE_HOVER;
    }
    
    draw_rect(x, y, w, h, bg_color);
    draw_rect_outline(x, y, w, h, 1.0, COLOR_BORDER_LIGHT);
    
    // Label
    if state.font {
        tw := Simp.prepare_text(state.font, label);
        tx := x + (w - cast(float32)tw) * 0.5;
        ty := y + (h - cast(float32)state.font.character_height) * 0.5;
        Simp.draw_text(state.font, cast(s64)tx, cast(s64)ty, label, COLOR_TEXT_MAIN);
    }
    
    return hovered;
}

draw_action_bar :: (state: *GUI_State, x: float32, y: float32, w: float32, h: float32, mx: float32, my: float32, mouse_clicked: bool) {
    draw_rect(x, y, w, h, COLOR_SURFACE);
    draw_rect_outline(x, y, w, h, 1.0, COLOR_BORDER);
    
    btn_y := y + (h - 32.0) * 0.5;
    
    // 1. "+ Register Config" Button
    if draw_button(state, x + 16.0, btn_y, 140.0, 32.0, "+ Register Config", mx, my, is_accent = true) {
        if mouse_clicked state.trigger_register = true;
    }
    
    // 2. "Clean Dead & Logs" Button
    if draw_button(state, x + 168.0, btn_y, 140.0, 32.0, "Clean Dead & Logs", mx, my, is_accent = false) {
        if mouse_clicked state.trigger_clean = true;
    }
    
    // 3. Status indicator & Totals
    total_cpu: float32 = 0;
    total_ram: u64 = 0;
    running_count := 0;
    for p: state.process_list {
        if p.status == .RUNNING {
            total_cpu += p.current_cpu;
            total_ram += p.current_rss;
            running_count += 1;
        }
    }
    
    // Right side: Status badge + metrics
    status_color := ifx state.daemon_online then COLOR_RUNNING else COLOR_CRASHED;
    status_text  := ifx state.daemon_online then "jpmd ONLINE" else "jpmd OFFLINE";
    
    dot_x := x + w - 380.0;
    draw_rect(dot_x, y + (h - 10.0) * 0.5, 10.0, 10.0, status_color);
    
    if state.font {
        Simp.draw_text(state.font, cast(s64)(dot_x + 16.0), cast(s64)(y + (h - cast(float32)state.font.character_height) * 0.5), status_text, COLOR_TEXT_MAIN);
        
        metrics_str := tprint("Managed: % | Total CPU: %5.1f%% | RAM: %", running_count, total_cpu, format_bytes(total_ram));
        Simp.draw_text(state.font, cast(s64)(dot_x + 120.0), cast(s64)(y + (h - cast(float32)state.font.character_height) * 0.5), metrics_str, COLOR_TEXT_MUTED);
    }
}

draw_process_table :: (state: *GUI_State, x: float32, y: float32, w: float32, h: float32, mx: float32, my: float32, mouse_clicked: bool) {
    draw_rect(x, y, w, h, COLOR_BG);
    draw_rect_outline(x, y, w, h, 1.0, COLOR_BORDER);
    
    header_h: float32 = 36.0;
    row_h:    float32 = 38.0;
    
    // Header
    draw_rect(x, y + h - header_h, w, header_h, COLOR_HEADER);
    draw_rect_outline(x, y + h - header_h, w, header_h, 1.0, COLOR_BORDER);
    
    // Column headers
    cols := string.[
        "Status", "Process Name", "PID", "Uptime", "CPU %", "RAM (RSS / Limit)", "Disk R/W", "Crashes", "Last Event", "Actions"
    ];
    col_x := float32.[
        16.0, 110.0, 260.0, 320.0, 410.0, 480.0, 640.0, 740.0, 810.0, 1050.0
    ];
    
    if state.font {
        for i: 0..cols.count-1 {
            Simp.draw_text(state.font, cast(s64)(x + col_x[i]), cast(s64)(y + h - header_h + 10.0), cols[i], COLOR_TEXT_MUTED);
        }
    }
    
    // Rows
    curr_y := y + h - header_h - row_h;
    for i: 0..state.process_list.count-1 {
        if curr_y < y break; // Out of bounds
        
        info := *state.process_list[i];
        is_selected := (state.selected_idx == cast(s32)i);
        is_hovered := is_point_in_rect(mx, my, x, curr_y, w, row_h);
        
        row_color := ifx (i % 2 == 0) then COLOR_ROW_EVEN else COLOR_ROW_ODD;
        if is_selected {
            row_color = COLOR_ROW_SELECTED;
        } else if is_hovered {
            row_color = COLOR_SURFACE_HOVER;
        }
        
        draw_rect(x, curr_y, w, row_h, row_color);
        draw_rect_outline(x, curr_y, w, row_h, 0.5, COLOR_BORDER);
        
        if is_hovered && mouse_clicked {
            state.selected_idx = cast(s32)i;
        }
        
        // Status Badge
        badge_w: float32 = 70.0;
        badge_h: float32 = 22.0;
        badge_x := x + col_x[0];
        badge_y := curr_y + (row_h - badge_h) * 0.5;
        
        badge_color := COLOR_STOPPED;
        badge_text  := "STOPPED";
        if info.status == .RUNNING {
            badge_color = COLOR_RUNNING;
            badge_text  = "RUNNING";
        } else if info.status == .CRASHED {
            badge_color = COLOR_CRASHED;
            badge_text  = "CRASHED";
        }
        
        draw_rect(badge_x, badge_y, badge_w, badge_h, badge_color);
        if state.font {
            tw := Simp.prepare_text(state.font, badge_text);
            Simp.draw_text(state.font, cast(s64)(badge_x + (badge_w - cast(float32)tw) * 0.5), cast(s64)(badge_y + 4.0), badge_text, COLOR_TEXT_MAIN);
        }
        
        // Text Columns
        if state.font {
            ty := curr_y + 11.0;
            Simp.draw_text(state.font, cast(s64)(x + col_x[1]), cast(s64)ty, slice(info.name, 0, min(info.name.count, 18)), COLOR_TEXT_MAIN);
            Simp.draw_text(state.font, cast(s64)(x + col_x[2]), cast(s64)ty, tprint("%", info.pid), COLOR_TEXT_MUTED);
            Simp.draw_text(state.font, cast(s64)(x + col_x[3]), cast(s64)ty, format_duration(info.uptime_sec), COLOR_TEXT_MUTED);
            Simp.draw_text(state.font, cast(s64)(x + col_x[4]), cast(s64)ty, tprint("%5.1f%%", info.current_cpu), COLOR_TEXT_MAIN);
            
            limit_str := ifx info.hard_memory_max > 0 then format_bytes(info.hard_memory_max) else "unlimited";
            ram_str := tprint("% / %", format_bytes(info.current_rss), limit_str);
            Simp.draw_text(state.font, cast(s64)(x + col_x[5]), cast(s64)ty, ram_str, COLOR_TEXT_MAIN);
            
            disk_str := tprint("% / %", format_bytes(info.disk_read_bytes), format_bytes(info.disk_write_bytes));
            Simp.draw_text(state.font, cast(s64)(x + col_x[6]), cast(s64)ty, disk_str, COLOR_TEXT_MUTED);
            
            Simp.draw_text(state.font, cast(s64)(x + col_x[7]), cast(s64)ty, tprint("%", info.crash_count), ifx info.crash_count > 0 then COLOR_CRASHED else COLOR_TEXT_MUTED);
            Simp.draw_text(state.font, cast(s64)(x + col_x[8]), cast(s64)ty, slice(info.last_event, 0, min(info.last_event.count, 30)), COLOR_TEXT_MUTED);
        }
        
        // Inline Action Buttons: Restart, Stop, Unregister
        act_y := curr_y + (row_h - 24.0) * 0.5;
        if draw_button(state, x + col_x[9], act_y, 55.0, 24.0, "Restart", mx, my) {
            if mouse_clicked {
                state.trigger_action = 3;
                state.action_target = copy_string(info.name);
            }
        }
        if draw_button(state, x + col_x[9] + 62.0, act_y, 45.0, 24.0, "Stop", mx, my) {
            if mouse_clicked {
                state.trigger_action = 2;
                state.action_target = copy_string(info.name);
            }
        }
        if draw_button(state, x + col_x[9] + 114.0, act_y, 75.0, 24.0, "Unregister", mx, my) {
            if mouse_clicked {
                state.trigger_action = 4;
                state.action_target = copy_string(info.name);
            }
        }
        
        curr_y -= row_h;
    }
}

draw_sparkline :: (x: float32, y: float32, w: float32, h: float32, values: [] float32, max_val: float32, line_color: Vector4, label: string, current_str: string, font: *Simp.Dynamic_Font) {
    draw_rect(x, y, w, h, COLOR_SURFACE);
    draw_rect_outline(x, y, w, h, 1.0, COLOR_BORDER);
    
    // Header text
    if font {
        Simp.draw_text(font, cast(s64)(x + 12.0), cast(s64)(y + h - 24.0), label, COLOR_TEXT_MUTED);
        Simp.draw_text(font, cast(s64)(x + w - 100.0), cast(s64)(y + h - 24.0), current_str, line_color);
    }
    
    // Grid lines
    grid_y1 := y + h * 0.25;
    grid_y2 := y + h * 0.5;
    grid_y3 := y + h * 0.75;
    draw_rect(x, grid_y1, w, 1.0, COLOR_CHART_GRID);
    draw_rect(x, grid_y2, w, 1.0, COLOR_CHART_GRID);
    draw_rect(x, grid_y3, w, 1.0, COLOR_CHART_GRID);
    
    if values.count < 2 || max_val <= 0 return;
    
    chart_y := y + 10.0;
    chart_h := h - 45.0;
    step_x := w / cast(float32)(max(values.count - 1, 1));
    
    for i: 0..values.count-2 {
        v0 := min(values[i] / max_val, 1.0);
        v1 := min(values[i + 1] / max_val, 1.0);
        
        px0 := x + cast(float32)i * step_x;
        py0 := chart_y + v0 * chart_h;
        px1 := x + cast(float32)(i + 1) * step_x;
        py1 := chart_y + v1 * chart_h;
        
        // Quad line segment
        draw_rect(px0, min(py0, py1), max(px1 - px0, 2.0), max(abs(py1 - py0), 2.0), line_color);
    }
}

draw_inspector_drawer :: (state: *GUI_State, x: float32, y: float32, w: float32, h: float32, mx: float32, my: float32, mouse_clicked: bool) {
    draw_rect(x, y, w, h, COLOR_CARD);
    draw_rect_outline(x, y, w, h, 1.0, COLOR_BORDER);
    
    tab_bar_h: float32 = 36.0;
    draw_rect(x, y + h - tab_bar_h, w, tab_bar_h, COLOR_HEADER);
    
    // Tab buttons
    tab_w: float32 = 140.0;
    tabs := string.["Telemetry Charts", "Standard Out", "Standard Err", "Lifecycle Events"];
    
    for i: 0..tabs.count-1 {
        tx := x + 16.0 + cast(float32)i * (tab_w + 4.0);
        is_active := (state.active_tab == cast(Tab_Type)i);
        
        tab_bg := ifx is_active then COLOR_CARD else COLOR_SURFACE;
        draw_rect(tx, y + h - tab_bar_h, tab_w, tab_bar_h, tab_bg);
        draw_rect_outline(tx, y + h - tab_bar_h, tab_w, tab_bar_h, 1.0, COLOR_BORDER);
        
        if is_point_in_rect(mx, my, tx, y + h - tab_bar_h, tab_w, tab_bar_h) && mouse_clicked {
            state.active_tab = cast(Tab_Type)i;
        }
        
        if state.font {
            tw := Simp.prepare_text(state.font, tabs[i]);
            Simp.draw_text(state.font, cast(s64)(tx + (tab_w - cast(float32)tw) * 0.5), cast(s64)(y + h - tab_bar_h + 10.0), tabs[i], ifx is_active then COLOR_TEXT_MAIN else COLOR_TEXT_MUTED);
        }
    }
    
    content_y := y;
    content_h := h - tab_bar_h;
    
    if state.selected_idx < 0 || state.selected_idx >= state.process_list.count {
        if state.font {
            Simp.draw_text(state.font, cast(s64)(x + 24.0), cast(s64)(y + content_h * 0.5), "Select a process from the table above to view live telemetry and logs.", COLOR_TEXT_MUTED);
        }
        return;
    }
    
    selected_proc := *state.process_list[state.selected_idx];
    
    if state.active_tab == .TELEMETRY {
        // Draw CPU & RAM sparklines
        chart_w := (w - 48.0) * 0.5;
        chart_h := content_h - 24.0;
        
        // CPU Chart
        cpu_str := tprint("%.1f%%", selected_proc.current_cpu);
        draw_sparkline(x + 16.0, y + 12.0, chart_w, chart_h, state.cpu_history, 100.0, COLOR_CHART_CPU, "Real-time CPU Usage", cpu_str, state.font);
        
        // RAM Chart
        ram_vals: [..] float32;
        max_ram: float32 = 1.0;
        for r: state.ram_history {
            rf := cast(float32)r;
            array_add(*ram_vals, rf);
            if rf > max_ram max_ram = rf;
        }
        defer array_free(ram_vals);
        if selected_proc.hard_memory_max > 0 && cast(float32)selected_proc.hard_memory_max > max_ram {
            max_ram = cast(float32)selected_proc.hard_memory_max;
        }
        
        ram_str := format_bytes(selected_proc.current_rss);
        draw_sparkline(x + 32.0 + chart_w, y + 12.0, chart_w, chart_h, ram_vals, max_ram, COLOR_CHART_RAM, "Real-time RAM Usage (RSS)", ram_str, state.font);
        
    } else {
        // Live .txt Log Viewer
        log_file := selected_proc.log_out;
        if state.active_tab == .LOG_ERR log_file = selected_proc.log_err;
        else if state.active_tab == .LOG_EVENTS log_file = selected_proc.log_events;
        
        // Read lines from file if exists
        draw_rect(x + 16.0, y + 12.0, w - 32.0, content_h - 24.0, COLOR_BG);
        draw_rect_outline(x + 16.0, y + 12.0, w - 32.0, content_h - 24.0, 1.0, COLOR_BORDER);
        
        if log_file.count > 0 && file_exists(log_file) {
            content, ok := read_entire_file(log_file);
            if ok {
                defer free(content);
                lines := split(content, "\n");
                defer array_free(lines);
                
                line_y := y + content_h - 36.0;
                start := max(0, lines.count - 18);
                for idx: start .. lines.count-1 {
                    if line_y < y + 20.0 break;
                    line_str := lines[idx];
                    
                    line_color := COLOR_TEXT_MAIN;
                    if find_index_from_left(line_str, "CRASHED") >= 0 line_color = COLOR_CRASHED;
                    else if find_index_from_left(line_str, "WATCHDOG") >= 0 line_color = COLOR_WARNING;
                    else if find_index_from_left(line_str, "STARTED") >= 0 line_color = COLOR_RUNNING;
                    
                    if state.font {
                        Simp.draw_text(state.font, cast(s64)(x + 28.0), cast(s64)line_y, line_str, line_color);
                    }
                    line_y -= 18.0;
                }
            }
        } else {
            if state.font {
                Simp.draw_text(state.font, cast(s64)(x + 28.0), cast(s64)(y + content_h * 0.5), tprint("Log file '%' not found or empty.", log_file), COLOR_TEXT_MUTED);
            }
        }
    }
}
