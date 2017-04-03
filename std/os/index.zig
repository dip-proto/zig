pub const windows = @import("windows.zig");
pub const darwin = @import("darwin.zig");
pub const linux = @import("linux.zig");
pub const posix = switch(@compileVar("os")) {
    Os.linux => linux,
    Os.darwin, Os.macosx, Os.ios => darwin,
    Os.windows => windows,
    else => @compileError("Unsupported OS"),
};

pub const max_noalloc_path_len = 1024;

const debug = @import("../debug.zig");
const assert = debug.assert;

const errno = @import("errno.zig");
const linking_libc = @import("../target.zig").linking_libc;
const c = @import("../c/index.zig");

const mem = @import("../mem.zig");
const Allocator = mem.Allocator;

const io = @import("../io.zig");
const HashMap = @import("../hash_map.zig").HashMap;
const cstr = @import("../cstr.zig");

error Unexpected;
error SysResources;
error AccessDenied;
error InvalidExe;
error FileSystem;
error IsDir;
error FileNotFound;
error FileBusy;

/// Fills `buf` with random bytes. If linking against libc, this calls the
/// appropriate OS-specific library call. Otherwise it uses the zig standard
/// library implementation.
pub fn getRandomBytes(buf: []u8) -> %void {
    while (true) {
        const err = switch (@compileVar("os")) {
            Os.linux => {
                if (linking_libc) {
                    if (c.getrandom(buf.ptr, buf.len, 0) == -1) *c._errno() else 0
                } else {
                    posix.getErrno(posix.getrandom(buf.ptr, buf.len, 0))
                }
            },
            Os.darwin, Os.macosx, Os.ios => {
                if (linking_libc) {
                    if (posix.getrandom(buf.ptr, buf.len) == -1) *c._errno() else 0
                } else {
                    posix.getErrno(posix.getrandom(buf.ptr, buf.len))
                }
            },
            Os.windows => {
                var hCryptProv: windows.HCRYPTPROV = undefined;
                if (!windows.CryptAcquireContext(&hCryptProv, null, null, windows.PROV_RSA_FULL, 0)) {
                    return error.Unexpected;
                }
                defer _ = windows.CryptReleaseContext(hCryptProv, 0);

                if (!windows.CryptGenRandom(hCryptProv, windows.DWORD(buf.len), buf.ptr)) {
                    return error.Unexpected;
                }
                return;
            },
            else => @compileError("Unsupported OS"),
        };
        if (err > 0) {
            return switch (err) {
                errno.EINVAL => unreachable,
                errno.EFAULT => unreachable,
                errno.EINTR  => continue,
                else         => error.Unexpected,
            }
        }
        return;
    }
}

/// Raises a signal in the current kernel thread, ending its execution.
/// If linking against libc, this calls the abort() libc function. Otherwise
/// it uses the zig standard library implementation.
pub coldcc fn abort() -> noreturn {
    if (linking_libc) {
        c.abort();
    }
    switch (@compileVar("os")) {
        Os.linux, Os.darwin, Os.macosx, Os.ios => {
            _ = posix.raise(posix.SIGABRT);
            _ = posix.raise(posix.SIGKILL);
            while (true) {}
        },
        else => @compileError("Unsupported OS"),
    }
}

fn makePipe() -> %[2]i32 {
    var fds: [2]i32 = undefined;
    const err = posix.getErrno(posix.pipe(&fds));
    if (err > 0) {
        return switch (err) {
            errno.EMFILE, errno.ENFILE => error.SysResources,
            else => error.Unexpected,
        }
    }
    return fds;
}

fn destroyPipe(pipe: &const [2]i32) {
    posixClose((*pipe)[0]);
    posixClose((*pipe)[1]);
}

/// Calls POSIX close, and keeps trying if it gets interrupted.
pub fn posixClose(fd: i32) {
    while (true) {
        const err = posix.getErrno(posix.close(fd));
        if (err == errno.EINTR) {
            continue;
        } else {
            return;
        }
    }
}

/// Calls POSIX write, and keeps trying if it gets interrupted.
pub fn posixWrite(fd: i32, bytes: []const u8) -> %void {
    while (true) {
        const write_ret = posix.write(fd, bytes.ptr, bytes.len);
        const write_err = posix.getErrno(write_ret);
        if (write_err > 0) {
            return switch (write_err) {
                errno.EINTR  => continue,
                errno.EINVAL => unreachable,
                errno.EDQUOT => error.DiskQuota,
                errno.EFBIG  => error.FileTooBig,
                errno.EIO    => error.Io,
                errno.ENOSPC => error.NoSpaceLeft,
                errno.EPERM  => error.BadPerm,
                errno.EPIPE  => error.PipeFail,
                else         => error.Unexpected,
            }
        }
        return;
    }
}


/// ::path may need to be copied in memory to add a null terminating byte. In this case
/// a fixed size buffer of size ::max_noalloc_path_len is an attempted solution. If the fixed
/// size buffer is too small, and the provided allocator is null, ::error.NameTooLong is returned.
/// otherwise if the fixed size buffer is too small, allocator is used to obtain the needed memory.
/// Calls POSIX open, keeps trying if it gets interrupted, and translates
/// the return value into zig errors.
pub fn posixOpen(path: []const u8, flags: usize, perm: usize, allocator: ?&Allocator) -> %i32 {
    var stack_buf: [max_noalloc_path_len]u8 = undefined;
    var path0: []u8 = undefined;
    var need_free = false;

    if (path.len < stack_buf.len) {
        path0 = stack_buf[0...path.len + 1];
    } else if (const a ?= allocator) {
        path0 = %return a.alloc(u8, path.len + 1);
        need_free = true;
    } else {
        return error.NameTooLong;
    }
    defer if (need_free) {
        (??allocator).free(path0);
    };
    mem.copy(u8, path0, path);
    path0[path.len] = 0;

    while (true) {
        const result = posix.open(path0.ptr, flags, perm);
        const err = posix.getErrno(result);
        if (err > 0) {
            return switch (err) {
                errno.EINTR => continue,

                errno.EFAULT => unreachable,
                errno.EINVAL => unreachable,
                errno.EACCES => error.BadPerm,
                errno.EFBIG, errno.EOVERFLOW => error.FileTooBig,
                errno.EISDIR => error.IsDir,
                errno.ELOOP => error.SymLinkLoop,
                errno.EMFILE => error.ProcessFdQuotaExceeded,
                errno.ENAMETOOLONG => error.NameTooLong,
                errno.ENFILE => error.SystemFdQuotaExceeded,
                errno.ENODEV => error.NoDevice,
                errno.ENOENT => error.PathNotFound,
                errno.ENOMEM => error.NoMem,
                errno.ENOSPC => error.NoSpaceLeft,
                errno.ENOTDIR => error.NotDir,
                errno.EPERM => error.BadPerm,
                else => error.Unexpected,
            }
        }
        return i32(result);
    }
}

const ErrInt = @intType(false, @sizeOf(error) * 8);
fn writeIntFd(fd: i32, value: ErrInt) -> %void {
    var bytes: [@sizeOf(ErrInt)]u8 = undefined;
    mem.writeInt(bytes[0...], value, true);

    var index: usize = 0;
    while (index < bytes.len) {
        const amt_written = posix.write(fd, &bytes[index], bytes.len - index);
        const err = posix.getErrno(amt_written);
        if (err > 0) {
            switch (err) {
                errno.EINTR => continue,
                errno.EINVAL => unreachable,
                else => return error.SysResources,
            }
        }
        index += amt_written;
    }
}

fn readIntFd(fd: i32) -> %ErrInt {
    var bytes: [@sizeOf(ErrInt)]u8 = undefined;

    var index: usize = 0;
    while (index < bytes.len) {
        const amt_written = posix.read(fd, &bytes[index], bytes.len - index);
        const err = posix.getErrno(amt_written);
        if (err > 0) {
            switch (err) {
                errno.EINTR => continue,
                errno.EINVAL => unreachable,
                else => return error.SysResources,
            }
        }
        index += amt_written;
    }

    return mem.readInt(bytes[0...], ErrInt, true);
}

// Child of fork calls this to report an error to the fork parent.
// Then the child exits.
fn forkChildErrReport(fd: i32, err: error) -> noreturn {
    _ = writeIntFd(fd, ErrInt(err));
    posix.exit(1);
}

fn dup2NoIntr(old_fd: i32, new_fd: i32) -> %void {
    while (true) {
        const err = posix.getErrno(posix.dup2(old_fd, new_fd));
        if (err > 0) {
            return switch (err) {
                errno.EBUSY, errno.EINTR => continue,
                errno.EMFILE => error.SysResources,
                errno.EINVAL => unreachable,
                else => error.Unexpected,
            };
        }
        return;
    }
}

pub const ChildProcess = struct {
    pid: i32,
    err_pipe: [2]i32,

    stdin: ?io.OutStream,
    stdout: ?io.InStream,
    stderr: ?io.InStream,

    pub const Term = enum {
        Clean: i32,
        Signal: i32,
        Stopped: i32,
        Unknown: i32,
    };

    pub const StdIo = enum {
        Inherit,
        Ignore,
        Pipe,
        Close,
    };

    pub fn spawn(exe_path: []const u8, args: []const []const u8, env_map: &const EnvMap,
        stdin: StdIo, stdout: StdIo, stderr: StdIo, allocator: &Allocator) -> %ChildProcess
    {
        switch (@compileVar("os")) {
            Os.linux, Os.macosx, Os.ios, Os.darwin => {
                return spawnPosix(exe_path, args, env_map, stdin, stdout, stderr, allocator);
            },
            else => @compileError("Unsupported OS"),
        }
    }

    pub fn wait(self: &ChildProcess) -> %Term {
        defer {
            posixClose(self.err_pipe[0]);
            posixClose(self.err_pipe[1]);
        };

        var status: i32 = undefined;
        while (true) {
            const err = posix.getErrno(posix.waitpid(self.pid, &status, 0));
            if (err > 0) {
                switch (err) {
                    errno.EINVAL, errno.ECHILD => unreachable,
                    errno.EINTR => continue,
                    else => {
                        if (const *stdin ?= self.stdin) { stdin.close(); }
                        if (const *stdout ?= self.stdin) { stdout.close(); }
                        if (const *stderr ?= self.stdin) { stderr.close(); }
                        return error.Unexpected;
                    },
                }
            }
            break;
        }

        if (const *stdin ?= self.stdin) { stdin.close(); }
        if (const *stdout ?= self.stdin) { stdout.close(); }
        if (const *stderr ?= self.stdin) { stderr.close(); }

        // Write @maxValue(ErrInt) to the write end of the err_pipe. This is after
        // waitpid, so this write is guaranteed to be after the child
        // pid potentially wrote an error. This way we can do a blocking
        // read on the error pipe and either get @maxValue(ErrInt) (no error) or
        // an error code.
        %return writeIntFd(self.err_pipe[1], @maxValue(ErrInt));
        const err_int = %return readIntFd(self.err_pipe[0]);
        // Here we potentially return the fork child's error
        // from the parent pid.
        if (err_int != @maxValue(ErrInt)) {
            return error(err_int);
        }

        return statusToTerm(status);
    }

    fn statusToTerm(status: i32) -> Term {
        return if (posix.WIFEXITED(status)) {
            Term.Clean { posix.WEXITSTATUS(status) }
        } else if (posix.WIFSIGNALED(status)) {
            Term.Signal { posix.WTERMSIG(status) }
        } else if (posix.WIFSTOPPED(status)) {
            Term.Stopped { posix.WSTOPSIG(status) }
        } else {
            Term.Unknown { status }
        };
    }

    fn spawnPosix(exe_path: []const u8, args: []const []const u8, env_map: &const EnvMap,
        stdin: StdIo, stdout: StdIo, stderr: StdIo, allocator: &Allocator) -> %ChildProcess
    {
        // TODO issue #295
        //const stdin_pipe = if (stdin == StdIo.Pipe) %return makePipe() else undefined;
        var stdin_pipe: [2]i32 = undefined;
        if (stdin == StdIo.Pipe)
            stdin_pipe = %return makePipe();
        %defer if (stdin == StdIo.Pipe) { destroyPipe(stdin_pipe); };

        // TODO issue #295
        //const stdout_pipe = if (stdout == StdIo.Pipe) %return makePipe() else undefined;
        var stdout_pipe: [2]i32 = undefined;
        if (stdout == StdIo.Pipe) 
            stdout_pipe = %return makePipe();
        %defer if (stdout == StdIo.Pipe) { destroyPipe(stdout_pipe); };

        // TODO issue #295
        //const stderr_pipe = if (stderr == StdIo.Pipe) %return makePipe() else undefined;
        var stderr_pipe: [2]i32 = undefined;
        if (stderr == StdIo.Pipe) 
            stderr_pipe = %return makePipe();
        %defer if (stderr == StdIo.Pipe) { destroyPipe(stderr_pipe); };

        const any_ignore = (stdin == StdIo.Ignore or stdout == StdIo.Ignore or stderr == StdIo.Ignore);
        // TODO issue #295
        //const dev_null_fd = if (any_ignore) {
        //    %return posixOpen("/dev/null", posix.O_RDWR, 0, null)
        //} else {
        //    undefined
        //};
        var dev_null_fd: i32 = undefined;
        if (any_ignore)
            dev_null_fd = %return posixOpen("/dev/null", posix.O_RDWR, 0, null);

        // This pipe is used to communicate errors between the time of fork
        // and execve from the child process to the parent process.
        const err_pipe = %return makePipe();
        %defer destroyPipe(err_pipe);

        const pid = posix.fork();
        const pid_err = linux.getErrno(pid);
        if (pid_err > 0) {
            return switch (pid_err) {
                errno.EAGAIN, errno.ENOMEM, errno.ENOSYS => error.SysResources,
                else => error.Unexpected,
            };
        }
        if (pid == 0) {
            // we are the child
            setUpChildIo(stdin, stdin_pipe[0], posix.STDIN_FILENO, dev_null_fd) %%
                |err| forkChildErrReport(err_pipe[1], err);
            setUpChildIo(stdout, stdout_pipe[1], posix.STDOUT_FILENO, dev_null_fd) %%
                |err| forkChildErrReport(err_pipe[1], err);
            setUpChildIo(stderr, stderr_pipe[1], posix.STDERR_FILENO, dev_null_fd) %%
                |err| forkChildErrReport(err_pipe[1], err);

            const err = posix.getErrno(%return execve(exe_path, args, env_map, allocator));
            assert(err > 0);
            forkChildErrReport(err_pipe[1], switch (err) {
                errno.EFAULT => unreachable,
                errno.E2BIG, errno.EMFILE, errno.ENAMETOOLONG, errno.ENFILE, errno.ENOMEM => error.SysResources,
                errno.EACCES, errno.EPERM => error.AccessDenied,
                errno.EINVAL, errno.ENOEXEC => error.InvalidExe,
                errno.EIO, errno.ELOOP => error.FileSystem,
                errno.EISDIR => error.IsDir,
                errno.ENOENT, errno.ENOTDIR => error.FileNotFound,
                errno.ETXTBSY => error.FileBusy,
                else => error.Unexpected,
            });
        }

        // we are the parent
        if (stdin == StdIo.Pipe) { posixClose(stdin_pipe[0]); }
        if (stdout == StdIo.Pipe) { posixClose(stdout_pipe[1]); }
        if (stderr == StdIo.Pipe) { posixClose(stderr_pipe[1]); }
        if (any_ignore) { posixClose(dev_null_fd); }

        return ChildProcess {
            .pid = i32(pid),
            .err_pipe = err_pipe,

            .stdin = if (stdin == StdIo.Pipe) {
                io.OutStream {
                    .fd = stdin_pipe[1],
                    .buffer = undefined,
                    .index = 0,
                }
            } else {
                null
            },
            .stdout = if (stdout == StdIo.Pipe) {
                io.InStream {
                    .fd = stdout_pipe[0],
                }
            } else {
                null
            },
            .stderr = if (stderr == StdIo.Pipe) {
                io.InStream {
                    .fd = stderr_pipe[0],
                }
            } else {
                null
            },
        };
    }

    fn setUpChildIo(stdio: StdIo, pipe_fd: i32, std_fileno: i32, dev_null_fd: i32) -> %void {
        switch (stdio) {
            StdIo.Pipe => %return dup2NoIntr(pipe_fd, std_fileno),
            StdIo.Close => posixClose(std_fileno),
            StdIo.Inherit => {},
            StdIo.Ignore => %return dup2NoIntr(dev_null_fd, std_fileno),
        }
    }
};

/// This function must allocate memory to add a null terminating bytes on path and each arg.
/// It must also convert to KEY=VALUE\0 format for environment variables, and include null
/// pointers after the args and after the environment variables.
/// Also make the first arg equal to path.
fn execve(path: []const u8, argv: []const []const u8, env_map: &const EnvMap, allocator: &Allocator) -> %usize {
    const path_buf = %return allocator.alloc(u8, path.len + 1);
    defer allocator.free(path_buf);
    @memcpy(&path_buf[0], &path[0], path.len);
    path_buf[path.len] = 0;

    const argv_buf = %return allocator.alloc(?&const u8, argv.len + 2);
    mem.set(?&const u8, argv_buf, null);
    defer {
        for (argv_buf) |arg, i| {
            const arg_buf = if (const ptr ?= arg) ptr[0...argv[i].len + 1] else break;
            allocator.free(arg_buf);
        }
        allocator.free(argv_buf);
    }
    {
        // Add path to the first argument.
        const arg_buf = %return allocator.alloc(u8, path.len + 1);
        @memcpy(&arg_buf[0], path.ptr, path.len);
        arg_buf[path.len] = 0;

        argv_buf[0] = arg_buf.ptr;
    }
    for (argv) |arg, i| {
        const arg_buf = %return allocator.alloc(u8, arg.len + 1);
        @memcpy(&arg_buf[0], arg.ptr, arg.len);
        arg_buf[arg.len] = 0;

        argv_buf[i + 1] = arg_buf.ptr;
    }
    argv_buf[argv.len + 1] = null;

    const envp_count = env_map.count();
    const envp_buf = %return allocator.alloc(?&const u8, envp_count + 1);
    mem.set(?&const u8, envp_buf, null);
    defer {
        for (envp_buf) |env, i| {
            const env_buf = if (const ptr ?= env) ptr[0...cstr.len(ptr)] else break;
            allocator.free(env_buf);
        }
        allocator.free(envp_buf);
    }
    {
        var it = env_map.iterator();
        var i: usize = 0;
        while (true; i += 1) {
            const pair = it.next() ?? break;

            const env_buf = %return allocator.alloc(u8, pair.key.len + pair.value.len + 2);
            @memcpy(&env_buf[0], pair.key.ptr, pair.key.len);
            env_buf[pair.key.len] = '=';
            @memcpy(&env_buf[pair.key.len + 1], pair.value.ptr, pair.value.len);
            env_buf[env_buf.len - 1] = 0;

            envp_buf[i] = env_buf.ptr;
        }
        assert(i == envp_count);
    }
    envp_buf[envp_count] = null;

    return posix.execve(path_buf.ptr, argv_buf.ptr, envp_buf.ptr);
}

pub var environ_raw: []&u8 = undefined;

pub const EnvMap = struct {
    hash_map: EnvHashMap,

    const EnvHashMap = HashMap([]const u8, []const u8, hash_slice_u8, eql_slice_u8);

    pub fn init(allocator: &Allocator) -> EnvMap {
        var self = EnvMap {
            .hash_map = undefined,
        };
        self.hash_map.init(allocator);
        return self;
    }

    pub fn deinit(self: &EnvMap) {
        var it = self.hash_map.entryIterator();
        while (true) {
            const entry = it.next() ?? break; 
            self.free(entry.key);
            self.free(entry.value);
        }

        self.hash_map.deinit();
    }

    pub fn set(self: &EnvMap, key: []const u8, value: []const u8) -> %void {
        if (const entry ?= self.hash_map.get(key)) {
            const value_copy = %return self.copy(value);
            %defer self.free(value_copy);
            %return self.hash_map.put(key, value_copy);
            self.free(entry.value);
        } else {
            const key_copy = %return self.copy(key);
            %defer self.free(key_copy);
            const value_copy = %return self.copy(value);
            %defer self.free(value_copy);
            %return self.hash_map.put(key_copy, value_copy);
        }
    }

    pub fn delete(self: &EnvMap, key: []const u8) {
        const entry = self.hash_map.remove(key) ?? return;
        self.free(entry.key);
        self.free(entry.value);
    }

    pub fn count(self: &const EnvMap) -> usize {
        return self.hash_map.size;
    }

    pub fn iterator(self: &const EnvMap) -> EnvHashMap.Iterator {
        return self.hash_map.entryIterator();
    }

    fn free(self: &EnvMap, value: []const u8) {
        // remove the const
        const mut_value = @ptrcast(&u8, value.ptr)[0...value.len];
        self.hash_map.allocator.free(mut_value);
    }

    fn copy(self: &EnvMap, value: []const u8) -> %[]const u8 {
        const result = %return self.hash_map.allocator.alloc(u8, value.len);
        mem.copy(u8, result, value);
        return result;
    }
};

pub fn getEnvMap(allocator: &Allocator) -> %EnvMap {
    var result = EnvMap.init(allocator);
    %defer result.deinit();

    for (environ_raw) |ptr| {
        var line_i: usize = 0;
        while (ptr[line_i] != 0 and ptr[line_i] != '='; line_i += 1) {}
        const key = ptr[0...line_i];

        var end_i: usize = line_i;
        while (ptr[end_i] != 0; end_i += 1) {}
        const value = ptr[line_i + 1...end_i];

        %return result.set(key, value);
    }
    return result;
}

pub fn getEnv(key: []const u8) -> ?[]const u8 {
    for (environ_raw) |ptr| {
        var line_i: usize = 0;
        while (ptr[line_i] != 0 and ptr[line_i] != '='; line_i += 1) {}
        const this_key = ptr[0...line_i];
        if (!mem.eql(u8, key, this_key))
            continue;

        var end_i: usize = line_i;
        while (ptr[end_i] != 0; end_i += 1) {}
        const this_value = ptr[line_i + 1...end_i];

        return this_value;
    }
    return null;
}

fn hash_slice_u8(k: []const u8) -> u32 {
    // FNV 32-bit hash
    var h: u32 = 2166136261;
    for (k) |b| {
        h = (h ^ b) *% 16777619;
    }
    return h;
}

fn eql_slice_u8(a: []const u8, b: []const u8) -> bool {
    return mem.eql(u8, a, b);
}
