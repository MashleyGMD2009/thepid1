thepid1.log("Entering Runlevel 1 (Root console)...")
thepid1.stop_all_daemons()
thepid1.spawn("/usr/bin/setsid", {"-c", "/bin/bash", "-i"}, true)
