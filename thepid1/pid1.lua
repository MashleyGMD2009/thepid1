#!/usr/bin/env luajit
-- /etc/thepid1/pid1.lua
-- "Will never gonna give you up, never gonna let you down and never gonna provoke a kernel panic and curse you."

local ffi = require("ffi")

ffi.cdef[[
    int prctl(int option, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5);
]]

local PR_SET_NAME = 15
ffi.C.prctl(PR_SET_NAME, ffi.cast("unsigned long", "thepid1"), 0, 0, 0)

ffi.cdef[[
    typedef int pid_t;
    typedef unsigned int mode_t;
    typedef unsigned int uid_t;
    typedef long time_t;

    struct dirent {
        unsigned long  d_ino;
        long           d_off;
        unsigned short d_reclen;
        unsigned char  d_type;
        char           d_name[256];
    };
    typedef struct __dirstream DIR;

    int mount(const char *source, const char *target, const char *filesystemtype, unsigned long mountflags, const void *data);
    pid_t fork(void);
    int execve(const char *pathname, char *const argv[], char *const envp[]);
    pid_t waitpid(pid_t pid, int *wstatus, int options);
    int kill(pid_t pid, int sig);
    pid_t getpid(void);
    pid_t setsid(void);
    int sethostname(const char *name, size_t len);
    int sync(void);
    int reboot(int magic, int magic2, int cmd, void *arg);
    int mkfifo(const char *pathname, mode_t mode);
    int open(const char *pathname, int flags, ...);
    ssize_t read(int fd, void *buf, size_t count);
    int close(int fd);
    int unlink(const char *pathname);
    int access(const char *pathname, int mode);
    unsigned int usleep(unsigned int usec);
    time_t time(time_t *tloc);

    DIR *opendir(const char *name);
    struct dirent *readdir(DIR *dirp);
    int closedir(DIR *dirp);
]]

local MS_NOSUID  = 2
local MS_NODEV   = 4
local MS_NOEXEC  = 8
local MS_REMOUNT = 32

local WNOHANG    = 1
local O_RDONLY   = 0
local O_NONBLOCK = 2048
local X_OK       = 1
local SIGTERM    = 15

local LINUX_REBOOT_MAGIC1        = 0xfee1dead
local LINUX_REBOOT_MAGIC2        = 672274793
local LINUX_REBOOT_CMD_POWER_OFF = 0x4321fedc
local LINUX_REBOOT_CMD_RESTART   = 0x01234567

local BASE_DIR = "/etc/thepid1"
local CTL_FIFO = "/run/thepid1.ctl"

local daemons_by_pid  = {}
local oneshots_by_pid = {}
local respawn_queue   = {}
local ctl_fd          = -1

local function log(msg)
    io.write("[thepid1] " .. msg .. "\n")
    io.flush()
end

if ffi.C.getpid() ~= 1 then
    io.stderr:write("Error: pid1.lua must be executed as PID 1. Try to manage it with pid.\n")
    os.exit(1)
end

_G.thepid1 = {
    ffi           = ffi,
    log           = log,
    REBOOT_MAGIC1 = LINUX_REBOOT_MAGIC1,
    REBOOT_MAGIC2 = LINUX_REBOOT_MAGIC2,
    CMD_POWEROFF  = LINUX_REBOOT_CMD_POWER_OFF,
    CMD_RESTART   = LINUX_REBOOT_CMD_RESTART
}

local function split_words(str)
    local t = {}
    for w in str:gmatch("%S+") do
        table.insert(t, w)
    end
    return t
end

local function is_executable(path)
    return ffi.C.access(path, X_OK) == 0
end

local function list_dir_sorted(dir_path)
    local entries = {}
    local dir = ffi.C.opendir(dir_path)
    if dir == nil then return entries end
    while true do
        local ent = ffi.C.readdir(dir)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." then
            table.insert(entries, name)
        end
    end
    ffi.C.closedir(dir)
    table.sort(entries)
    return entries
end

local function spawn_process(path, args, is_daemon)
    if not is_executable(path) then
        log("Warning: This directory does not exist -> " .. path)
        return -1
    end

    args = args or {}
    local pid = ffi.C.fork()
    if pid == 0 then
        if ctl_fd >= 0 then ffi.C.close(ctl_fd) end
        ffi.C.setsid()

        local argc = #args + 1
        local argv = ffi.new("const char*[?]", argc + 1)
        argv[0] = path
        for i, v in ipairs(args) do
            argv[i] = v
        end
        argv[argc] = nil

        local envp = ffi.new("const char*[4]")
        envp[0] = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        envp[1] = "TERM=linux"
        envp[2] = "HOME=/root"
        envp[3] = nil

        ffi.C.execve(path, ffi.cast("char *const*", argv), ffi.cast("char *const*", envp))
        os.exit(127)
    elseif pid > 0 then
        if is_daemon then
            daemons_by_pid[pid] = { path = path, args = args }
        else
            oneshots_by_pid[pid] = path
        end
    else
        log("Error: fork() failed to run " .. path)
    end
    return pid
end

_G.thepid1.spawn = spawn_process

local function stop_all_daemons()
    respawn_queue = {}
    for pid, info in pairs(daemons_by_pid) do
        log("Stopping daemon PID " .. pid .. " (" .. info.path .. ")")
        ffi.C.kill(pid, SIGTERM)
    end
    daemons_by_pid = {}
end

_G.thepid1.stop_all_daemons = stop_all_daemons

local function scan_and_run_scripts(scripts_dir)
    local folders = list_dir_sorted(scripts_dir)
    local launched_count = 0

    for _, folder in ipairs(folders) do
        local base = scripts_dir .. "/" .. folder
        local exec_file = base .. "/exec"
        local daemon_file = base .. "/daemon"

        if is_executable(exec_file) then
            log("Executing oneshot (exec): " .. exec_file)
            spawn_process(exec_file, {}, false)
            launched_count = launched_count + 1
        end

        if is_executable(daemon_file) then
            log("Running process (daemon): " .. daemon_file)
            spawn_process(daemon_file, {}, true)
            launched_count = launched_count + 1
        end
    end

    return launched_count
end

_G.thepid1.scan_and_run_scripts = scan_and_run_scripts

local function switch_runlevel(rl)
    rl = tonumber(rl)
    if not rl then return end
    local rl_file = string.format("%s/runlevels/%d.lua", BASE_DIR, rl)
    log("Changing to Runlevel " .. rl .. " (" .. rl_file .. ")")

    local ok, err = pcall(dofile, rl_file)
    if not ok then
        log("ERROR on Runlevel " .. rl .. ": " .. tostring(err))
        if rl ~= 1 then
            log("Activating Runlevel 1...")
            switch_runlevel(1)
        end
    end
end

_G.thepid1.switch_runlevel = switch_runlevel

local function early_mount()
    log("Mounting /proc, /sys, /dev and /run...")
    ffi.C.mount("proc", "/proc", "proc", MS_NOSUID + MS_NOEXEC + MS_NODEV, nil)
    ffi.C.mount("sysfs", "/sys", "sysfs", MS_NOSUID + MS_NOEXEC + MS_NODEV, nil)
    ffi.C.mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755")
    ffi.C.mount("tmpfs", "/run", "tmpfs", MS_NOSUID + MS_NODEV, "mode=0755")

    ffi.C.mount(nil, "/", nil, MS_REMOUNT, nil)
    os.execute("/bin/mount -a >/dev/null 2>&1")
end

local function setup_control_fifo()
    ffi.C.unlink(CTL_FIFO)
    ffi.C.mkfifo(CTL_FIFO, 384) -- 0600
    ctl_fd = ffi.C.open(CTL_FIFO, O_RDONLY + O_NONBLOCK)
end

local function process_cli_commands()
    if ctl_fd < 0 then return end
    local buf = ffi.new("char[1024]")
    local n = ffi.C.read(ctl_fd, buf, 1023)
    if n > 0 then
        local data = ffi.string(buf, n)
        for line in data:gmatch("[^\r\n]+") do
            local tokens = split_words(line)
            local cmd = tokens[1]
            if cmd == "RUNLEVEL" and tokens[2] then
                switch_runlevel(tokens[2])
            elseif cmd == "DAEMON" and tokens[2] then
                local bin = tokens[2]
                local args = {}
                for i = 3, #tokens do table.insert(args, tokens[i]) end
                log("CLI -> Lanzando daemon supervisado: " .. bin)
                spawn_process(bin, args, true)
            elseif cmd == "EXEC" and tokens[2] then
                local bin = tokens[2]
                local args = {}
                for i = 3, #tokens do table.insert(args, tokens[i]) end
                log("CLI -> Lanzando oneshot exec: " .. bin)
                spawn_process(bin, args, false)
            end
        end
    end
end

-- === BOOT ===
early_mount()
setup_control_fifo()

local initial_rl = 2
if arg and tonumber(arg[1]) then
    initial_rl = tonumber(arg[1])
end

switch_runlevel(initial_rl)

-- === PID 1 LOOP ===
local status = ffi.new("int[1]")
while true do
    while true do
        local dead = ffi.C.waitpid(-1, status, WNOHANG)
        if dead <= 0 then break end

        if daemons_by_pid[dead] then
            local info = daemons_by_pid[dead]
            daemons_by_pid[dead] = nil
            log("Fallen daemon (" .. info.path .. ", PID " .. dead .. "). Relaunching in 1s...")
            table.insert(respawn_queue, {
                path = info.path,
                args = info.args,
                due = tonumber(ffi.C.time(nil)) + 1
            })
        elseif oneshots_by_pid[dead] then
            oneshots_by_pid[dead] = nil
        end
    end

    local now = tonumber(ffi.C.time(nil))
    for i = #respawn_queue, 1, -1 do
        local item = respawn_queue[i]
        if now >= item.due then
            table.remove(respawn_queue, i)
            log("Relaunching daemon: " .. item.path)
            spawn_process(item.path, item.args, true)
        end
    end

    pcall(process_cli_commands)
    ffi.C.usleep(50000)
end
