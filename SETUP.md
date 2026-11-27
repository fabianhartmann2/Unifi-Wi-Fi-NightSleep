# NightMode: Synology setup

NightMode turns UniFi access points off and on by schedule, with a separate "off" window for each UniFi AP Group. For example, most APs are off 19:00 to 08:00, the evening group 22:00 to 06:00, and the night group is never off. The DSM Task Scheduler runs it every 15 minutes. Each run checks the real state and changes only what is wrong. This means edits to the shared JSON take effect within 15 minutes, and a missed run fixes itself on the next one.

## Files

| File | Where it goes | Who edits it |
|---|---|---|
| `nightmode.sh` | private folder on the NAS, e.g. `/volume1/homes/admin/nightmode/` | nobody |
| `nightmode.conf` (copied from `nightmode.conf.example`) | same private folder, `chmod 600` | you (UDM address, login) |
| `nightmode.json` | shared folder, e.g. `/volume1/Shared/NightMode/` | everyone |

### The shared `nightmode.json`

```json
{
  "enabled": true,
  "default": { "off_from": "19:00", "off_until": "08:00" },
  "groups": [
    { "group": "Evening", "off_from": "22:00", "off_until": "06:00" },
    { "group": "Night", "off": "never" }
  ],
  "ignore": []
}
```

With this file the day looks like this:

| Time | On | Off |
|---|---|---|
| 08:00 to 19:00 | all APs | none |
| 19:00 to 22:00 | Evening and Night groups | all other APs |
| 22:00 to 06:00 | Night group | everything else |
| 06:00 to 08:00 | Evening and Night groups | all other APs |

- `enabled`: `true` or `false`. Setting it to `false` turns all APs back on at the next run.
- `default`: when the APs that are in **none** of the listed groups are off. Use `"off": "never"` to leave them alone.
- `groups`: one entry per UniFi AP Group, with the time its APs are off:
  - `group`: the AP Group's name in UniFi (not case sensitive). Create groups in UniFi Network under Settings > WiFi > AP Groups (the exact menu depends on the version). Run `--list` to see the exact names.
  - `off_from` / `off_until`: 24 hour local time of the NAS, `"HH:MM"` or just the hour (`22`). The window can cross midnight. It ends at `off_until`, so a group off until 06:00 comes back at the 06:00 run.
  - `"off": "never"` keeps the group on all the time. `"off": "always"` keeps it off all the time.
  - Instead of `group`, an entry can list single APs by name or MAC: `{ "aps": ["AP-Keller"], "off": "never" }`.
  - You can add as many entries as you like, for example a third phase.
- `ignore`: APs the script never touches, e.g. one you disabled by hand for maintenance. Without this, the next run would switch it back to its schedule.

**APs in more than one group:** an AP that is in two of the listed groups is only off when **all** of its groups are off, so the group that keeps it on longest wins. The log notes this whenever such an AP is switched. To keep things clear, it's best to put each AP in only one of the listed groups. Also leave UniFi's built-in "All APs" group out of the list, because it contains every AP.

To change which APs belong to which phase, just change the group members in UniFi. The JSON doesn't need to change.

**Fail-safes:** the script turns everything **on** and writes the reason to the log if:
- the file is missing or not valid JSON,
- a time is invalid,
- a group name doesn't exist (or the groups can't be read),
- or the schedule would turn off every AP at once.

It also only turns APs off once at least one of the APs that should stay on is actually online.

The older format (`start`, `end`, `keep_on_group`, `keep_on`) still works. It means: default off from `start` to `end`, and the `keep_on_group` and `keep_on` APs are never off.

## 1. Create a dedicated UniFi account

In UniFi OS (`https://<udm>` > Admins & Users > Create New Admin):

1. Choose **Restrict to local access only**. The script cannot do 2FA or UI.com cloud logins.
2. Username e.g. `nightmode`, with a strong password.
3. Give it the Network app with a role that may manage devices (Site Admin / Full Management) and no access to the other apps (Protect, etc.).

This keeps your own account out of a file on the NAS, and you can revoke the account on its own.

## 2. Put the files on the NAS

1. In File Station, create a private folder such as `homes/admin/nightmode` and upload `nightmode.sh` and `nightmode.conf.example`. Rename the example to `nightmode.conf` and fill it in: `UNIFI_HOST`, `UNIFI_USER`, `UNIFI_PASS`, plus the paths `SHARED_CONFIG` and `LOG_FILE`.
2. Create (or reuse) a shared folder, e.g. `Shared/NightMode`, put `nightmode.json` in it, and give the others read/write permission on that folder. The log file can go there too, so everyone can see what happened.
3. Lock down the credentials file. Either SSH in (`sudo -i`) or create a one-time Task Scheduler task (user `root`) that runs:
   ```sh
   chmod 600 /volume1/homes/admin/nightmode/nightmode.conf
   chmod 700 /volume1/homes/admin/nightmode/nightmode.sh
   sed -i 's/\r$//' /volume1/homes/admin/nightmode/nightmode.sh
   ```
   The `sed` line removes Windows line endings, in case the script was opened in a Windows editor. The script copes with Windows line endings in the `.conf` and `.json` files on its own.

## 3. Test it once

Over SSH (as root), or as a one-off task with "Send run details by email" turned on:

```sh
sh /volume1/homes/admin/nightmode/nightmode.sh -c /volume1/homes/admin/nightmode/nightmode.conf --list
```

This logs in and prints all APs with name, MAC and state, followed by all AP groups and their members, without changing anything. Check that your groups contain the right APs, and use their exact names in `groups`. Then do a dry run, which shows what it would switch right now:

```sh
sh /volume1/homes/admin/nightmode/nightmode.sh -c /volume1/homes/admin/nightmode/nightmode.conf --dry-run
```

To test another time of day, use e.g. `NIGHTMODE_NOW=20:30 sh ... --dry-run` (evening) or `NIGHTMODE_NOW=23:30 sh ... --dry-run` (night).

If something fails, add `--debug`. It prints the HTTP status of each request and the start of the controller's response to the terminal, not to the log. Passwords, keys and tokens are replaced by `***`, and the login response isn't shown at all. Look over the output before sending it to anyone: it still contains device names, MACs and IP addresses.

## 4. Schedule it

Control Panel > Task Scheduler > Create > Scheduled Task > User-defined script:

- **General:** Task `NightMode`, User `root`, Enabled.
- **Schedule:** Run on the following days: *Daily*. First run time *00:00*, Frequency *Every 15 minutes*, Last run time *23:45*.
- **Task Settings > Run command:**
  ```sh
  sh /volume1/homes/admin/nightmode/nightmode.sh -c /volume1/homes/admin/nightmode/nightmode.conf
  ```
  Optional: "Send run details by email" with "only when the script terminates abnormally". The script exits with an error when login fails, the UDM can't be reached, or an AP change fails.

## The log

Each run writes one line, e.g.

```
2026-11-27 22:00:04 [INFO] turned OFF AP-Kueche (aa:bb:cc:00:00:0e) [Evening]
2026-11-27 22:00:05 [INFO] now 22:00, default: off 19:00-08:00 (active); Evening: off 22:00-06:00 (active); Night: never off: 16 of 17 APs scheduled off, 3 change(s), 0 failure(s)
2026-11-27 22:15:03 [OK] now 22:15, default: off 19:00-08:00 (active); Evening: off 22:00-06:00 (active); Night: never off: 16 of 17 APs scheduled off, nothing to change
```

It is trimmed to the last 2000 lines (about 3 weeks).

## Requirements

DSM's built-in `sh`, `curl`, `awk`, `sed` and `grep`. No jq, Python or Docker needed.

## Assumptions not yet tested on your setup

I tested the script on Linux against a simulated UDM (login, device list, switching APs, all the fail-safes, Windows line endings in the config), not against your real UDM or the DS216play. Please check these with the `--list` and `--dry-run` steps above:

1. **API details.** Login at `/api/auth/login` with the CSRF token, device list at `/proxy/network/api/s/<site>/stat/device`, and `PUT .../rest/device/<id>` with `{"disabled":true}`. AP groups come from the newer v2 API, `GET /proxy/network/v2/api/site/<site>/apgroups`, which I expect to return a list of groups with `name` and `device_macs`. It needs UniFi Network 8 or newer. If that endpoint is missing or looks different on your UDM, the script logs an error and leaves all APs on. `--list` shows you right away whether it works. This is the same action as "Disable" on a device in the UniFi UI, and is how current UniFi OS versions work as far as I know.
2. **Only devices of type `uap` are touched.** The UDM itself (and its built-in WiFi, if it has one), switches and gateways are never changed. If you count the UDM as one of the 17 APs and want it off at night too, let me know.
3. **Mesh.** The APs that stay on must be wired. If it reaches the network wirelessly through an AP that gets turned off, it goes offline too.
4. **In-wall APs with LAN ports** (e.g. U6 IW). A disabled AP may also stop its wired ports or PoE passthrough. Put those in `ignore` if devices are plugged into them.
5. **Morning.** Re-enabled APs need a few minutes to come back and get their config. The night group stays on the whole time, so there is no gap.
6. **Time zone.** The NAS clock and time zone decide the window (Control Panel > Regional Options).
