# NightMode setup guide

NightMode turns UniFi access points off and on by schedule, with a separate "off" window for each UniFi AP Group. For example, most APs are off 19:00 to 08:00, the evening group 22:00 to 06:00, and the night group is never off. The DSM Task Scheduler on a Synology NAS runs it every 15 minutes. Each run checks the real state of every AP and changes only what is wrong. Edits to the shared JSON therefore take effect within 15 minutes, and a missed run fixes itself on the next one.

For an overview and the architecture, see the [README](README.md).

**Contents**

1. [Create a least-privilege UniFi account](#1-create-a-least-privilege-unifi-account)
2. [Put the files on the NAS](#2-put-the-files-on-the-nas)
3. [Write the schedule](#3-write-the-schedule-nightmodejson)
4. [Test it](#4-test-it)
5. [Schedule it](#5-schedule-it)
6. [Testing from a Mac](#testing-from-a-mac)
7. [The log](#the-log)
8. [Troubleshooting](#troubleshooting)
9. [Assumptions to check on your setup](#assumptions-to-check-on-your-setup)

## Files

| File | Where it goes | Who edits it |
|---|---|---|
| `nightmode.sh` | private folder on the NAS, e.g. `/volume1/homes/admin/nightmode/` | nobody |
| `nightmode.conf` (copied from `nightmode.conf.example`) | same private folder, `chmod 600` | you (UDM address, login, paths) |
| `nightmode.json` | shared folder, e.g. `/volume1/Shared/NightMode/` | everyone who may change the schedule |
| `nightmode.log` | wherever `LOG_FILE` points, e.g. the shared folder | written by the script |

Keep `nightmode.conf` out of the shared folder. It holds the UniFi password. It is also listed in `.gitignore`, so it is never committed.

## 1. Create a least-privilege UniFi account

The script logs in with its own account, so your personal login never sits in a file on the NAS and you can revoke the script's access on its own.

In UniFi OS (`https://<udm>` > Admins & Users > Create New Admin):

1. Choose **Restrict to local access only**. The script cannot do 2FA or UI.com cloud logins, and a local-only account can't be used from the internet.
2. Use a username such as `nightmode` and a long, random password. The password may contain any characters, because the config file is never executed.
3. Give it access to the **Network** app only, with a role that may manage devices (Site Admin or Full Management, depending on the UniFi OS version). Give it **no access** to Protect, Access, Talk or the other apps, and no UniFi OS (console) admin rights.
4. A View Only role is not enough: the script has to change each AP's `disabled` setting.

That is everything the script needs. It reads the device list and AP groups, and enables or disables access points. It never touches the UDM itself, switches or gateways.

## 2. Put the files on the NAS

1. In File Station, create a private folder such as `homes/admin/nightmode` and upload `nightmode.sh` and `nightmode.conf.example`.
2. Rename the example to `nightmode.conf` and fill it in:

   | Key | Meaning | Default if empty |
   |---|---|---|
   | `UNIFI_HOST` | IP or hostname of the UDM | required |
   | `UNIFI_USER` / `UNIFI_PASS` | the local account from step 1 | required |
   | `UNIFI_SITE` | UniFi site name | `default` |
   | `UNIFI_CACERT` | path to the UDM's certificate (PEM) to verify TLS. Empty accepts the UDM's self-signed certificate. | empty |
   | `SHARED_CONFIG` | path of the shared `nightmode.json` | `nightmode.json` next to the script |
   | `LOG_FILE` | path of the log | `nightmode.log` next to the script |
   | `LOG_MAX_LINES` | the log is trimmed to this many lines | `2000` |

   The format is `KEY=VALUE`, one per line. One pair of surrounding quotes is removed. If a key appears twice, the last one wins.
3. Create (or reuse) a shared folder, e.g. `Shared/NightMode`, put `nightmode.json` in it, and give the people who may change the schedule read/write permission on that folder. Putting the log there too lets everyone see what happened.
4. Lock down the credentials file. Either SSH in (`sudo -i`) or create a one-time Task Scheduler task (user `root`) that runs:
   ```sh
   chmod 600 /volume1/homes/admin/nightmode/nightmode.conf
   chmod 700 /volume1/homes/admin/nightmode/nightmode.sh
   sed -i 's/\r$//' /volume1/homes/admin/nightmode/nightmode.sh
   ```
   The `sed` line removes Windows line endings, in case the script was opened in a Windows editor. The script copes with Windows line endings in the `.conf` and `.json` files on its own.

## 3. Write the schedule (`nightmode.json`)

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

### Keys

- `enabled`: `true` or `false`. Setting it to `false` turns all APs back on at the next run.
- `default`: when the APs that are in **none** of the listed groups are off. Use `"off": "never"` to leave them on. If `default` is left out, those APs are never off.
- `groups`: one entry per UniFi AP Group, with the time its APs are off:
  - `group`: the AP Group's name in UniFi (not case sensitive). Create groups in UniFi Network under Settings > WiFi > AP Groups (the exact menu depends on the version). Run `--list` to see the exact names. An entry can also name several groups as a list: `"group": ["Kids", "Guests"]`.
  - `off_from` / `off_until`: 24 hour local time of the machine running the script, `"HH:MM"` or just the hour (`22`). The window can cross midnight, and `off_from` and `off_until` must differ. It ends at `off_until`, so a group that is off until 06:00 comes back at the 06:00 run.
  - `"off": "never"` keeps the group on all the time. `"off": "always"` keeps it off all the time.
  - Instead of `group`, an entry can list single APs by name or MAC: `{ "aps": ["AP-Keller"], "off": "never" }`.
  - Add as many entries as you like, for example a third phase.
- `ignore`: APs the script never touches, by name or MAC, e.g. one you disabled by hand for maintenance. Without this, the next run would switch it back to its schedule.
- Keys starting with `_`, such as `_comment`, are ignored, so you can leave notes in the file.

**APs in more than one group:** an AP in two of the listed groups is only off when **all** of its groups are off, so the group that keeps it on longest wins. The log notes this whenever such an AP is switched. To keep things clear, put each AP in only one of the listed groups. Leave UniFi's built-in "All APs" group out of the list, because it contains every AP.

To change which APs belong to which phase, change the group members in UniFi. The JSON doesn't need to change.

### Fail-safes

The script turns everything **on** and writes the reason to the log if:

- the file is missing or not valid JSON,
- a time is invalid, or a `groups` entry has neither `group` nor `aps`,
- a group name doesn't exist, or the AP groups can't be read,
- or the schedule would turn off every AP at once.

On every run it first turns on the APs that should be on, and only then turns others off. It only turns APs off once at least one AP that should stay on is actually online. Otherwise it waits for the next run.

### Older format

The first format (`start`, `end`, `keep_on_group`, `keep_on`) still works. It means: default off from `start` to `end`, and the `keep_on_group` and `keep_on` APs are never off.

## 4. Test it

Over SSH (as root), or as a one-off task with "Send run details by email" turned on, first list what the script sees:

```sh
sh /volume1/homes/admin/nightmode/nightmode.sh -c /volume1/homes/admin/nightmode/nightmode.conf --list
```

This logs in and prints every AP with name, MAC, disabled flag and online state, followed by every AP group and its members. It changes nothing and writes nothing to the log. Check that your groups contain the right APs, and use their exact names in `groups`.

Then do a dry run, which shows what it would switch right now:

```sh
sh /volume1/homes/admin/nightmode/nightmode.sh -c /volume1/homes/admin/nightmode/nightmode.conf --dry-run
```

A dry run changes nothing on the UDM. Its lines do go to the log, marked `(dry-run)`.

To test another time of day, set `NIGHTMODE_NOW`, e.g. `NIGHTMODE_NOW=20:30 sh ... --dry-run` (evening) or `NIGHTMODE_NOW=23:30 sh ... --dry-run` (night).

## 5. Schedule it

Control Panel > Task Scheduler > Create > Scheduled Task > User-defined script:

- **General:** Task `NightMode`, User `root`, Enabled.
- **Schedule:** Run on the following days: *Daily*. First run time *00:00*, Frequency *Every 15 minutes*, Last run time *23:45*.
- **Task Settings > Run command:**
  ```sh
  sh /volume1/homes/admin/nightmode/nightmode.sh -c /volume1/homes/admin/nightmode/nightmode.conf
  ```
  Optional: "Send run details by email" with "only when the script terminates abnormally".

Exit codes: `0` success (or another run was still active), `1` the UDM couldn't be reached, login failed, the device list was unexpected or an AP change failed, `2` the local config is missing or incomplete. Runs never overlap: a second run exits while the first holds the lock, and a lock older than 30 minutes is cleared.

Your off windows should start and end on a quarter hour (e.g. `22:00`, `06:15`), because that is when the task runs.

## Testing from a Mac

You can run the script from a Mac on the same network before (or instead of) putting it on the NAS. macOS ships `sh`, `curl`, `awk` and the other tools it needs.

1. Put `nightmode.sh`, `nightmode.json` and a copy of `nightmode.conf.example` in one folder, e.g. `~/nightmode`.
2. Rename the copy to `nightmode.conf` and fill in `UNIFI_HOST`, `UNIFI_USER` and `UNIFI_PASS`. Leave `SHARED_CONFIG` and `LOG_FILE` **empty** (or delete those lines): the script then uses `nightmode.json` and `nightmode.log` in the same folder. The example's `/volume1/...` paths only exist on the NAS.
3. In Terminal:
   ```sh
   cd ~/nightmode
   chmod 600 nightmode.conf
   sh nightmode.sh --list
   sh nightmode.sh --dry-run
   NIGHTMODE_NOW=23:30 sh nightmode.sh --dry-run
   ```
   Without `-c`, the script reads `nightmode.conf` next to itself.

A run without `--dry-run` really switches APs, from the Mac just as from the NAS. Don't leave both scheduled: run it from one machine only. The window uses the clock and time zone of whichever machine runs it.

## The log

Each run writes one summary line, plus one line per AP it switched, e.g.

```
2026-11-27 22:00:04 [INFO] turned OFF AP-Kueche (aa:bb:cc:00:00:0e) [Evening]
2026-11-27 22:00:05 [INFO] now 22:00, default: off 19:00-08:00 (active); Evening: off 22:00-06:00 (active); Night: never off: 16 of 17 APs scheduled off, 3 change(s), 0 failure(s)
2026-11-27 22:15:03 [OK] now 22:15, default: off 19:00-08:00 (active); Evening: off 22:00-06:00 (active); Night: never off: 16 of 17 APs scheduled off, nothing to change
```

The levels are `OK` (nothing to do), `INFO` (something changed), `WARN` (fail-safe or waiting) and `ERROR`. The log is trimmed to the last `LOG_MAX_LINES` lines (2000 by default, about 3 weeks).

## Troubleshooting

| Log message | What to do |
|---|---|
| `Login to ... failed (HTTP 401/403)` | Check user and password. The account must be local-only, without 2FA. |
| `Login ... failed (HTTP 000)` | The UDM can't be reached. Check `UNIFI_HOST` and that the machine can reach it over HTTPS. |
| `Reading AP groups failed` | AP groups need UniFi Network 8 or newer. Until then, list APs by name with `"aps"` instead of `"group"`. |
| `AP group(s) not found: ...` | Run `--list` and copy the group name exactly as shown. |
| `Controller returned no access points` | Check `UNIFI_SITE`. |
| `no AP that should stay on is online yet` | An AP that should stay on is offline or still booting. The next run retries. |

If something fails, add `--debug`. It prints the HTTP status of each request and the start of the controller's response to the terminal, not to the log. Passwords, keys and tokens are replaced by `***`, and the login response isn't shown at all. Look over the output before sending it to anyone: it still contains device names, MACs and IP addresses.

## Requirements

`sh`, `curl`, `awk`, `sed`, `grep` and `tr`, all built into DSM and macOS. No jq, Python or Docker needed.

## Assumptions to check on your setup

The script was tested on Linux against a simulated UDM (login, device list, AP groups, switching APs, all the fail-safes, Windows line endings in the config), not against a real UDM or the DS216play. Please check these with the `--list` and `--dry-run` steps above:

1. **API details.** Login at `/api/auth/login` with the CSRF token, device list at `/proxy/network/api/s/<site>/stat/device`, and `PUT .../rest/device/<id>` with `{"disabled":true}`. AP groups come from the newer v2 API, `GET /proxy/network/v2/api/site/<site>/apgroups`, which is expected to return a list of groups with `name` and `device_macs`. If that endpoint is missing or looks different on your UDM, the script logs an error and leaves all APs on. `--list` shows right away whether it works. Disabling is the same action as "Disable" on a device in the UniFi UI.
2. **Only devices of type `uap` are touched.** The UDM itself (and its built-in WiFi, if it has one), switches and gateways are never changed.
3. **Account role.** The exact role names differ between UniFi OS versions. If `--list` works but switching an AP fails with HTTP 403, the role can't manage devices.
4. **Mesh.** The APs that stay on must be wired. An AP that reaches the network wirelessly through an AP that gets turned off goes offline too.
5. **In-wall APs with LAN ports** (e.g. U6 IW). A disabled AP may also stop its wired ports or PoE passthrough. Put those in `ignore` if devices are plugged into them.
6. **Morning.** Re-enabled APs need a few minutes to come back and get their config. The night group stays on the whole time, so there is no gap in coverage.
7. **Time zone.** The clock and time zone of the machine running the script decide the window (on the NAS: Control Panel > Regional Options).
