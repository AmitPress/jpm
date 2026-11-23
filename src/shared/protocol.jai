//
// JPM — Binary Wire IPC Protocol & Framing
//

#import "Basic";
#import "String";
#import "types";

Message_Type :: enum u16 {
    REGISTER_CONFIG     :: 1;
    REGISTER_TEMPLATE   :: 2;
    UNREGISTER          :: 3;
    GET_STATUS_ALL      :: 4;
    GET_STATUS_ONE      :: 5;
    CONTROL_ACTION      :: 6; // start, stop, restart
    CLEAN               :: 7;
    LAUNCH_GUI          :: 8;
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

PACKET_MAGIC :: 0x4A504D31;
PACKET_HEADER_SIZE :: size_of(Packet_Header);

Byte_Buffer :: struct {
    data: [..] u8;
    read_cursor: s64 = 0;
}

init_byte_buffer :: (capacity: s64 = 256) -> Byte_Buffer {
    buf: Byte_Buffer;
    array_reserve(*buf.data, capacity);
    return buf;
}

free_byte_buffer :: (buf: *Byte_Buffer) {
    array_free(buf.data);
    buf.read_cursor = 0;
}

write_u8 :: (buf: *Byte_Buffer, val: u8) {
    array_add(*buf.data, val);
}

write_u16 :: (buf: *Byte_Buffer, val: u16) {
    p := cast(*u8)*val;
    array_add(*buf.data, p[0]);
    array_add(*buf.data, p[1]);
}

write_u32 :: (buf: *Byte_Buffer, val: u32) {
    p := cast(*u8)*val;
    for i: 0..3 array_add(*buf.data, p[i]);
}

write_u64 :: (buf: *Byte_Buffer, val: u64) {
    p := cast(*u8)*val;
    for i: 0..7 array_add(*buf.data, p[i]);
}

write_float32 :: (buf: *Byte_Buffer, val: float32) {
    p := cast(*u8)*val;
    for i: 0..3 array_add(*buf.data, p[i]);
}

write_string :: (buf: *Byte_Buffer, str: string) {
    len := cast(u32)str.count;
    write_u32(buf, len);
    if len > 0 {
        old_count := buf.data.count;
        array_resize(*buf.data, old_count + len);
        memcpy(buf.data.data + old_count, str.data, len);
    }
}

read_u8 :: (buf: *Byte_Buffer) -> (val: u8, ok: bool) {
    if buf.read_cursor + 1 > buf.data.count return 0, false;
    val := buf.data[buf.read_cursor];
    buf.read_cursor += 1;
    return val, true;
}

read_u16 :: (buf: *Byte_Buffer) -> (val: u16, ok: bool) {
    if buf.read_cursor + 2 > buf.data.count return 0, false;
    val: u16;
    memcpy(*val, buf.data.data + buf.read_cursor, 2);
    buf.read_cursor += 2;
    return val, true;
}

read_u32 :: (buf: *Byte_Buffer) -> (val: u32, ok: bool) {
    if buf.read_cursor + 4 > buf.data.count return 0, false;
    val: u32;
    memcpy(*val, buf.data.data + buf.read_cursor, 4);
    buf.read_cursor += 4;
    return val, true;
}

read_u64 :: (buf: *Byte_Buffer) -> (val: u64, ok: bool) {
    if buf.read_cursor + 8 > buf.data.count return 0, false;
    val: u64;
    memcpy(*val, buf.data.data + buf.read_cursor, 8);
    buf.read_cursor += 8;
    return val, true;
}

read_float32 :: (buf: *Byte_Buffer) -> (val: float32, ok: bool) {
    if buf.read_cursor + 4 > buf.data.count return 0.0, false;
    val: float32;
    memcpy(*val, buf.data.data + buf.read_cursor, 4);
    buf.read_cursor += 4;
    return val, true;
}

read_string :: (buf: *Byte_Buffer) -> (val: string, ok: bool) {
    len, ok_len := read_u32(buf);
    if !ok_len return "", false;
    if len == 0 return "", true;
    if buf.read_cursor + len > buf.data.count return "", false;
    
    // Allocate string copy in caller's memory context
    str_data := alloc(len);
    memcpy(str_data, buf.data.data + buf.read_cursor, len);
    buf.read_cursor += len;
    
    s: string;
    s.count = len;
    s.data = str_data;
    return s, true;
}

serialize_process_info :: (buf: *Byte_Buffer, info: *Process_Info) {
    write_string(buf, info.name);
    write_string(buf, info.command);
    write_u8(buf, cast(u8)info.status);
    write_u32(buf, info.pid);
    write_u64(buf, info.uptime_sec);
    write_float32(buf, info.current_cpu);
    write_u64(buf, info.current_rss);
    write_u64(buf, info.hard_memory_max);
    write_u64(buf, info.disk_read_bytes);
    write_u64(buf, info.disk_write_bytes);
    write_u32(buf, info.crash_count);
    write_u32(buf, info.restart_count);
    write_string(buf, info.last_event);
    write_string(buf, info.log_out);
    write_string(buf, info.log_err);
    write_string(buf, info.log_events);
}

deserialize_process_info :: (buf: *Byte_Buffer) -> (info: Process_Info, ok: bool) {
    info: Process_Info;
    var_ok: bool;
    
    info.name, var_ok = read_string(buf);
    if !var_ok return info, false;
    info.command, var_ok = read_string(buf);
    if !var_ok return info, false;
    
    status_u8: u8;
    status_u8, var_ok = read_u8(buf);
    if !var_ok return info, false;
    info.status = cast(Process_Status)status_u8;
    
    info.pid, var_ok = read_u32(buf);
    if !var_ok return info, false;
    info.uptime_sec, var_ok = read_u64(buf);
    if !var_ok return info, false;
    info.current_cpu, var_ok = read_float32(buf);
    if !var_ok return info, false;
    info.current_rss, var_ok = read_u64(buf);
    if !var_ok return info, false;
    info.hard_memory_max, var_ok = read_u64(buf);
    if !var_ok return info, false;
    info.disk_read_bytes, var_ok = read_u64(buf);
    if !var_ok return info, false;
    info.disk_write_bytes, var_ok = read_u64(buf);
    if !var_ok return info, false;
    info.crash_count, var_ok = read_u32(buf);
    if !var_ok return info, false;
    info.restart_count, var_ok = read_u32(buf);
    if !var_ok return info, false;
    info.last_event, var_ok = read_string(buf);
    if !var_ok return info, false;
    info.log_out, var_ok = read_string(buf);
    if !var_ok return info, false;
    info.log_err, var_ok = read_string(buf);
    if !var_ok return info, false;
    info.log_events, var_ok = read_string(buf);
    if !var_ok return info, false;
    
    return info, true;
}

serialize_process_info_list :: (buf: *Byte_Buffer, list: [] Process_Info) {
    write_u32(buf, cast(u32)list.count);
    for * info: list {
        serialize_process_info(buf, info);
    }
}

deserialize_process_info_list :: (buf: *Byte_Buffer) -> (list: [..] Process_Info, ok: bool) {
    res: [..] Process_Info;
    count, ok_count := read_u32(buf);
    if !ok_count return res, false;
    
    array_reserve(*res, count);
    for i: 0..count-1 {
        item, ok_item := deserialize_process_info(buf);
        if !ok_item return res, false;
        array_add(*res, item);
    }
    return res, true;
}
