# UniFi Wi-Fi NightSleep (NightMode)

Turns off all UniFi access points overnight except the members of one AP Group, and turns them back on in the morning. It runs on a Synology NAS from the DSM Task Scheduler and needs only `sh`, `curl` and `awk`.

- `nightmode.sh`: the script, run every 15 minutes
- `nightmode.json`: shared settings (on/off, start/end time, AP group to keep on)
- `nightmode.conf.example`: local UniFi login, copy to `nightmode.conf` (ignored by git)

Setup steps and the list of untested assumptions are in [SETUP.md](SETUP.md).
