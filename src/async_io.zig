pub fn Res(comptime fd: type) type {
    return struct { rc: fd, usr_data: u64 };
}
