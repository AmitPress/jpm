//
// JPM — Indentation-aware YAML Parser & Template Generator
//

#import "Basic";
#import "String";
#import "File";
#import "File_Utilities";
#import "types";

parse_byte_size :: (raw: string) -> u64 {
    s := trim(raw);
    if s.count == 0 return 0;
    
    // Check suffix
    mult: u64 = 1;
    num_str := s;
    
    if ends_with_nocase(s, "gb") || ends_with_nocase(s, "gib") {
        mult = 1024 * 1024 * 1024;
        num_str = trim(slice(s, 0, s.count - 2));
        if ends_with_nocase(s, "gib") num_str = trim(slice(s, 0, s.count - 3));
    } else if ends_with_nocase(s, "mb") || ends_with_nocase(s, "mib") {
        mult = 1024 * 1024;
        num_str = trim(slice(s, 0, s.count - 2));
        if ends_with_nocase(s, "mib") num_str = trim(slice(s, 0, s.count - 3));
    } else if ends_with_nocase(s, "kb") || ends_with_nocase(s, "kib") {
        mult = 1024;
        num_str = trim(slice(s, 0, s.count - 2));
        if ends_with_nocase(s, "kib") num_str = trim(slice(s, 0, s.count - 3));
    } else if ends_with_nocase(s, "g") {
        mult = 1024 * 1024 * 1024;
        num_str = trim(slice(s, 0, s.count - 1));
    } else if ends_with_nocase(s, "m") {
        mult = 1024 * 1024;
        num_str = trim(slice(s, 0, s.count - 1));
    } else if ends_with_nocase(s, "k") {
        mult = 1024;
        num_str = trim(slice(s, 0, s.count - 1));
    } else if ends_with_nocase(s, "b") {
        num_str = trim(slice(s, 0, s.count - 1));
    }
    
    val, ok := string_to_float64(num_str);
    if !ok return 0;
    
    return cast(u64)(val * cast(float64)mult);
}

parse_duration_sec :: (raw: string) -> u32 {
    s := trim(raw);
    if s.count == 0 return 0;
    
    mult: u32 = 1;
    num_str := s;
    
    if ends_with_nocase(s, "ms") {
        num_str = trim(slice(s, 0, s.count - 2));
        ms_val, ok := string_to_int(num_str);
        if !ok return 0;
        return cast(u32)(ms_val / 1000);
    } else if ends_with_nocase(s, "s") {
        mult = 1;
        num_str = trim(slice(s, 0, s.count - 1));
    } else if ends_with_nocase(s, "m") {
        mult = 60;
        num_str = trim(slice(s, 0, s.count - 1));
    } else if ends_with_nocase(s, "h") {
        mult = 3600;
        num_str = trim(slice(s, 0, s.count - 1));
    } else if ends_with_nocase(s, "d") {
        mult = 86400;
        num_str = trim(slice(s, 0, s.count - 1));
    }
    
    val, ok := string_to_int(num_str);
    if !ok return 0;
    return cast(u32)val * mult;
}

ends_with_nocase :: (s: string, suffix: string) -> bool {
    if s.count < suffix.count return false;
    sub := slice(s, s.count - suffix.count, suffix.count);
    return equal_nocase(sub, suffix);
}

// Strip quotes and inline comments from value
clean_yaml_value :: (val: string) -> string {
    v := trim(val);
    // Remove inline comment if any: " # ..."
    comment_pos := find_index_from_left(v, "#");
    if comment_pos >= 0 {
        v = trim(slice(v, 0, comment_pos));
    }
    
    if v.count >= 2 {
        if (v[0] == #char "\"" && v[v.count-1] == #char "\"") ||
           (v[0] == #char "'"  && v[v.count-1] == #char "'") {
            v = slice(v, 1, v.count - 2);
        }
    }
    return v;
}

get_indent_level :: (line: string) -> (indent: int, trimmed: string) {
    count := 0;
    while count < line.count && (line[count] == #char " " || line[count] == #char "\t") {
        count += 1;
    }
    return count, slice(line, count, line.count - count);
}

parse_yaml_config :: (yaml_text: string) -> (config: Process_Config, ok: bool) {
    cfg: Process_Config;
    
    lines := split(yaml_text, "\n");
    defer array_free(lines);
    
    current_section := "";
    in_memory_rules := false;
    current_rule: *Memory_Rule = null;
    
    for raw_line: lines {
        indent, line := get_indent_level(raw_line);
        line = trim(line);
        if line.count == 0 || begins_with(line, "#") continue;
        
        // Strip inline comments if outside quotes
        // Check for root keys
        if indent == 0 {
            colon_idx := find_index_from_left(line, ":");
            if colon_idx >= 0 {
                key := trim(slice(line, 0, colon_idx));
                val := clean_yaml_value(slice(line, colon_idx + 1, line.count - colon_idx - 1));
                
                if key == {
                    case "name";
                        cfg.name = copy_string(val);
                    case "command";
                        cfg.command = copy_string(val);
                    case "cwd";
                        cfg.cwd = copy_string(val);
                    case "env";
                        current_section = "env";
                        in_memory_rules = false;
                    case "restart";
                        current_section = "restart";
                        in_memory_rules = false;
                    case "limits";
                        current_section = "limits";
                        in_memory_rules = false;
                    case "logs";
                        current_section = "logs";
                        in_memory_rules = false;
                }
            }
            continue;
        }
        
        // Indented keys
        if current_section == "env" {
            colon_idx := find_index_from_left(line, ":");
            if colon_idx >= 0 {
                k := trim(slice(line, 0, colon_idx));
                v := clean_yaml_value(slice(line, colon_idx + 1, line.count - colon_idx - 1));
                array_add(*cfg.env_vars, copy_string(tprint("%=%", k, v)));
            }
        } else if current_section == "restart" {
            colon_idx := find_index_from_left(line, ":");
            if colon_idx >= 0 {
                k := trim(slice(line, 0, colon_idx));
                v := clean_yaml_value(slice(line, colon_idx + 1, line.count - colon_idx - 1));
                if k == {
                    case "policy";
                        if equal_nocase(v, "always") cfg.restart_policy = .ALWAYS;
                        else if equal_nocase(v, "never") cfg.restart_policy = .NEVER;
                        else cfg.restart_policy = .ON_FAILURE;
                    case "max_retries";
                        ival, _ := string_to_int(v);
                        cfg.max_retries = cast(u32)ival;
                    case "backoff_ms";
                        ival, _ := string_to_int(v);
                        cfg.backoff_ms = cast(u32)ival;
                }
            }
        } else if current_section == "limits" {
            if begins_with(line, "hard_memory_max:") {
                colon_idx := find_index_from_left(line, ":");
                v := clean_yaml_value(slice(line, colon_idx + 1, line.count - colon_idx - 1));
                cfg.hard_memory_max = parse_byte_size(v);
            } else if begins_with(line, "memory:") {
                in_memory_rules = true;
            } else if in_memory_rules {
                // Check if this is a new list item: "- threshold: ..."
                trimmed_item := line;
                if begins_with(trimmed_item, "- ") {
                    new_rule: Memory_Rule;
                    array_add(*cfg.memory_rules, new_rule);
                    current_rule = *cfg.memory_rules[cfg.memory_rules.count - 1];
                    trimmed_item = trim(slice(trimmed_item, 2, trimmed_item.count - 2));
                }
                
                if current_rule != null && trimmed_item.count > 0 {
                    colon_idx := find_index_from_left(trimmed_item, ":");
                    if colon_idx >= 0 {
                        k := trim(slice(trimmed_item, 0, colon_idx));
                        v := clean_yaml_value(slice(trimmed_item, colon_idx + 1, trimmed_item.count - colon_idx - 1));
                        if k == {
                            case "threshold";
                                current_rule.threshold_bytes = parse_byte_size(v);
                            case "duration";
                                current_rule.duration_sec = parse_duration_sec(v);
                            case "action";
                                if equal_nocase(v, "restart") current_rule.action = .RESTART;
                                else if equal_nocase(v, "stop") current_rule.action = .STOP;
                                else if equal_nocase(v, "exec") current_rule.action = .EXEC;
                                else current_rule.action = .NOTIFY;
                            case "run";
                                current_rule.run_cmd = copy_string(v);
                            case "cooldown";
                                current_rule.cooldown_sec = parse_duration_sec(v);
                        }
                    }
                }
            }
        } else if current_section == "logs" {
            colon_idx := find_index_from_left(line, ":");
            if colon_idx >= 0 {
                k := trim(slice(line, 0, colon_idx));
                v := clean_yaml_value(slice(line, colon_idx + 1, line.count - colon_idx - 1));
                if k == {
                    case "out";
                        cfg.log_out = copy_string(v);
                    case "err";
                        cfg.log_err = copy_string(v);
                    case "events";
                        cfg.log_events = copy_string(v);
                    case "max_size";
                        cfg.max_log_size = parse_byte_size(v);
                    case "max_backups";
                        ival, _ := string_to_int(v);
                        cfg.max_backups = cast(u32)ival;
                }
            }
        }
    }
    
    if cfg.name.count == 0 || cfg.command.count == 0 {
        return cfg, false;
    }
    
    return cfg, true;
}

generate_template :: (type: string, file_path: string) -> (config: Process_Config, yaml_text: string, ok: bool) {
    cfg: Process_Config;
    
    norm_path := copy_string(file_path);
    // Replace backslashes with slashes for portability
    for i: 0..norm_path.count-1 {
        if norm_path[i] == #char "\\" norm_path[i] = #char "/";
    }
    
    parent_dir, base_name := path_decomp(norm_path);
    if parent_dir.count == 0 parent_dir = ".";
    
    // Remove extension for default name
    name_ext_idx := find_index_from_right(base_name, ".");
    app_name := base_name;
    if name_ext_idx > 0 {
        app_name = slice(base_name, 0, name_ext_idx);
    }
    
    cmd := "";
    if equal_nocase(type, "jar") {
        cmd = tprint("java -jar %", base_name);
        cfg.hard_memory_max = 2 * 1024 * 1024 * 1024; // 2GB default
    } else if equal_nocase(type, "node") || equal_nocase(type, "js") {
        cmd = tprint("node %", base_name);
        cfg.hard_memory_max = 1024 * 1024 * 1024; // 1GB default
    } else if equal_nocase(type, "python") || equal_nocase(type, "py") {
        cmd = tprint("python %", base_name);
        cfg.hard_memory_max = 1024 * 1024 * 1024; // 1GB default
    } else if equal_nocase(type, "binary") || equal_nocase(type, "bin") || equal_nocase(type, "exe") {
        cmd = tprint("./%", base_name);
    } else {
        return cfg, "", false;
    }
    
    cfg.name = copy_string(app_name);
    cfg.command = copy_string(cmd);
    cfg.cwd = copy_string(parent_dir);
    cfg.restart_policy = .ON_FAILURE;
    cfg.max_retries = 5;
    cfg.backoff_ms = 1000;
    
    // Add default notify watchdog rule
    rule: Memory_Rule;
    rule.threshold_bytes = cast(u64)(cast(float64)cfg.hard_memory_max * 0.8);
    if rule.threshold_bytes == 0 rule.threshold_bytes = 800 * 1024 * 1024;
    rule.duration_sec = 15;
    rule.action = .NOTIFY;
    rule.cooldown_sec = 300;
    array_add(*cfg.memory_rules, rule);
    
    builder: String_Builder;
    append(*builder, tprint("name: %\n", cfg.name));
    append(*builder, tprint("command: %\n", cfg.command));
    append(*builder, tprint("cwd: %\n\n", cfg.cwd));
    
    append(*builder, "restart:\n");
    append(*builder, "  policy: on-failure\n");
    append(*builder, "  max_retries: 5\n");
    append(*builder, "  backoff_ms: 1000\n\n");
    
    append(*builder, "limits:\n");
    if cfg.hard_memory_max > 0 {
        append(*builder, tprint("  hard_memory_max: %\n", format_bytes(cfg.hard_memory_max)));
    }
    append(*builder, "  memory:\n");
    append(*builder, tprint("    - threshold: %\n", format_bytes(rule.threshold_bytes)));
    append(*builder, "      duration: 15s\n");
    append(*builder, "      action: notify\n");
    append(*builder, "      cooldown: 5m\n\n");
    
    append(*builder, "logs:\n");
    append(*builder, tprint("  out: ./logs/%.out.txt\n", cfg.name));
    append(*builder, tprint("  err: ./logs/%.err.txt\n", cfg.name));
    append(*builder, tprint("  events: ./logs/%.events.txt\n", cfg.name));
    append(*builder, "  max_size: 50MB\n");
    append(*builder, "  max_backups: 3\n");
    
    yaml_str := builder_to_string(*builder);
    return cfg, yaml_str, true;
}
