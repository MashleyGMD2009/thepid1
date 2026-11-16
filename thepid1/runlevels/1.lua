thepid1.log("Entering Runlevel 1 (Root console)...")
thepid1.stop_all_daemons()
thepid1.spawn("/bin/sh", {"-c", "exec /usr/bin/setsid -c /bin/bash -i </dev/tty1 >/dev/tty1 2>&1"}, false)
