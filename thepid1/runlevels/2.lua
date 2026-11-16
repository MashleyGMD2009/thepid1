local scripts_dir = "/etc/thepid1/scripts"
thepid1.log("Runlevel 2: Scanning services on " .. scripts_dir .. "...")
local count = thepid1.scan_and_run_scripts(scripts_dir)
if count == 0 then
thepid1.log("Warning: No scripts on " .. scripts_dir .. ". Fallback to Runlevel 1.")
thepid1.switch_runlevel(1)
end
