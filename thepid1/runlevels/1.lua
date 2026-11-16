thepid1.log("Entering Runlevel 1 (Root console)...")
thepid1.stop_all_daemons()
thepid1.spawn("/bin/sh", {"-c", "exec /bin/sh </dev/console >/dev/console 2>&1"}, true)
