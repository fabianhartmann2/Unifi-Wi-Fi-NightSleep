#!/bin/sh
# =============================================================================
# NightMode for UniFi (UDM / UniFi OS) - run on a Synology NAS
#
# During the night window defined in a shared JSON file, all UniFi access
# points except the "keep_on" ones (or the members of "keep_on_group") are disabled. Outside the window (or when
# NightMode is switched off) all APs are enabled again.
#
# The script is idempotent: run it every 15 minutes from the DSM Task
# Scheduler and it converges to the desired state, only changing APs whose
# state differs. Needs only: sh, curl, awk, sed, grep (no jq, no python).
#
# Usage:
#   nightmode.sh [-c local.conf] [--dry-run] [--list]
#     -c FILE     local settings/credentials file (default: nightmode.conf
#                 next to this script)
#     --dry-run   show what would change, change nothing
#     --list      print all APs (name, MAC, state) and exit; use this to fill
#                 in "keep_on" in the shared JSON
#
# Testing hook: NIGHTMODE_NOW=HH:MM overrides the current time.
# =============================================================================

set -u
umask 077
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOCAL_CONF="$SCRIPT_DIR/nightmode.conf"
DRY_RUN=0
LIST_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c) LOCAL_CONF="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Local settings (NOT on the shared folder). Parsed as KEY=VALUE, never
# executed, so the password may contain any characters.
# ---------------------------------------------------------------------------
conf_get() {
    # $1 = key, $2 = default
    _v=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$LOCAL_CONF" 2>/dev/null | tail -n 1 \
        | sed -e 's/^[^=]*=//' -e 's/\r$//')
    # strip one pair of surrounding quotes, if present
    case "$_v" in
        \"*\") _v=${_v#\"}; _v=${_v%\"} ;;
        \'*\') _v=${_v#\'}; _v=${_v%\'} ;;
    esac
    if [ -z "$_v" ]; then printf '%s' "${2:-}"; else printf '%s' "$_v"; fi
}

if [ ! -r "$LOCAL_CONF" ]; then
    echo "Cannot read local config $LOCAL_CONF (copy nightmode.conf.example)" >&2
    exit 2
fi

UNIFI_HOST=$(conf_get UNIFI_HOST)
UNIFI_USER=$(conf_get UNIFI_USER)
UNIFI_PASS=$(conf_get UNIFI_PASS)
UNIFI_SITE=$(conf_get UNIFI_SITE default)
UNIFI_CACERT=$(conf_get UNIFI_CACERT)
SHARED_CONFIG=$(conf_get SHARED_CONFIG "$SCRIPT_DIR/nightmode.json")
LOG_FILE=$(conf_get LOG_FILE "$SCRIPT_DIR/nightmode.log")
LOG_MAX_LINES=$(conf_get LOG_MAX_LINES 2000)

BASE="https://$UNIFI_HOST"
API="$BASE/proxy/network/api/s/$UNIFI_SITE"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    _line="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
    [ "$DRY_RUN" = 1 ] && _line="$_line (dry-run)"
    echo "$_line"
    [ "$LIST_ONLY" = 1 ] && return 0
    echo "$_line" >> "$LOG_FILE" 2>/dev/null
}

trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    _n=$(wc -l < "$LOG_FILE")
    if [ "$_n" -gt "$LOG_MAX_LINES" ]; then
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Work dir, lock, cleanup
# ---------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nightmode.XXXXXX") || exit 1
LOCK_DIR="${TMPDIR:-/tmp}/nightmode.lock"
LOGGED_IN=0

cleanup() {
    if [ "$LOGGED_IN" = 1 ]; then
        curl_api POST "$BASE/api/auth/logout" "" >/dev/null 2>&1
    fi
    rm -rf "$WORK"
    rmdir "$LOCK_DIR" 2>/dev/null
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # stale lock older than 30 minutes? remove it
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null; mkdir "$LOCK_DIR" 2>/dev/null || { rm -rf "$WORK"; exit 1; }
    else
        echo "Another NightMode run is active, exiting." >&2
        rm -rf "$WORK"; exit 0
    fi
fi
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# ---------------------------------------------------------------------------
# Minimal JSON flattener (awk). Input: JSON. Output lines: path<TAB>value
# e.g. "enabled<TAB>true", "keep_on.0<TAB>AP-Office", "data.3.mac<TAB>aa:.."
# Linear time: splits on quotes instead of scanning char by char.
# ---------------------------------------------------------------------------
json_flat() {
    awk '
    function add(t, v) { ntok++; T[ntok] = t; V[ntok] = v }
    function lex(s,   i, c, lit, L) {
        L = length(s); lit = ""
        for (i = 1; i <= L; i++) {
            c = substr(s, i, 1)
            if (index("{}[]:,", c) > 0) { if (lit != "") { add("l", lit); lit = "" } add(c, "") }
            else if (index(" \t\r\n", c) > 0) { if (lit != "") { add("l", lit); lit = "" } }
            else lit = lit c
        }
        if (lit != "") add("l", lit)
    }
    function unesc(s) {
        gsub(/\\\\/, "\001", s); gsub(/\\"/, "\"", s); gsub(/\\\//, "/", s)
        gsub(/\\[tnr]/, " ", s); gsub(/\001/, "\\", s)
        return s
    }
    function trailing_bs(s,   n) { n = 0; while (n < length(s) && substr(s, length(s) - n, 1) == "\\") n++; return n }
    function fail(msg) { print "__error__\t" msg; err = 1; exit 1 }
    function val(path,   k, idx) {
        if (pos > ntok) fail("unexpected end")
        if (T[pos] == "{") {
            pos++
            if (T[pos] == "}") { pos++; return }
            while (1) {
                if (T[pos] != "s") fail("expected key")
                k = V[pos]; pos++
                if (T[pos] != ":") fail("expected colon")
                pos++
                val(path == "" ? k : path "." k)
                if (T[pos] == ",") { pos++; continue }
                if (T[pos] == "}") { pos++; return }
                fail("expected , or }")
            }
        } else if (T[pos] == "[") {
            pos++; idx = 0
            if (T[pos] == "]") { pos++; return }
            while (1) {
                val(path == "" ? idx : path "." idx); idx++
                if (T[pos] == ",") { pos++; continue }
                if (T[pos] == "]") { pos++; return }
                fail("expected , or ]")
            }
        } else if (T[pos] == "s" || T[pos] == "l") {
            print path "\t" V[pos]; pos++
        } else fail("unexpected token " T[pos])
    }
    { buf_all = buf_all $0 "\n" }
    END {
        if (err) exit 1
        n = split(buf_all, P, "\"")
        inside = 0; sbuf = ""
        for (i = 1; i <= n; i++) {
            if (!inside) { lex(P[i]); inside = 1; open_str = 0 }
            else {
                open_str = 1
                sbuf = sbuf P[i]
                if (i == n) break
                if (trailing_bs(sbuf) % 2 == 1) { sbuf = sbuf "\""; continue }
                add("s", unesc(sbuf)); sbuf = ""; inside = 0; open_str = 0
            }
        }
        if (open_str) fail("unterminated string")
        pos = 1
        if (ntok == 0) fail("empty input")
        val("")
    }'
}

# json_get FLATFILE PATH -> value (first match)
json_get() { awk -F '\t' -v p="$2" '$1 == p { print substr($0, length($1) + 2); exit }' "$1"; }
# json_list FLATFILE PREFIX -> values of PREFIX.0, PREFIX.1, ...
json_list() { awk -F '\t' -v p="$2" 'index($1, p ".") == 1 && substr($1, length(p) + 2) ~ /^[0-9]+$/ { print substr($0, length($1) + 2) }' "$1"; }

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
norm_mac() { lower "$1" | tr '-' ':'; }

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
CSRF=""
curl_api() {
    # $1 method, $2 url, $3 body file ("" = none). Writes $WORK/resp, prints HTTP code.
    set -- "$1" "$2" "${3:-}"
    _tls="-k"
    [ -n "$UNIFI_CACERT" ] && _tls="--cacert $UNIFI_CACERT"
    if [ -n "$3" ]; then
        # shellcheck disable=SC2086
        curl -sS $_tls --max-time 30 -X "$1" -b "$WORK/cookies" -c "$WORK/cookies" \
            -D "$WORK/hdr" -o "$WORK/resp" -w '%{http_code}' \
            -H 'Content-Type: application/json' -H "X-CSRF-Token: $CSRF" \
            --data-binary "@$3" "$2"
    else
        # shellcheck disable=SC2086
        curl -sS $_tls --max-time 30 -X "$1" -b "$WORK/cookies" -c "$WORK/cookies" \
            -D "$WORK/hdr" -o "$WORK/resp" -w '%{http_code}' \
            -H "X-CSRF-Token: $CSRF" "$2"
    fi
}

update_csrf() {
    _t=$(grep -i -E '^x-(updated-)?csrf-token:' "$WORK/hdr" 2>/dev/null | tail -n 1 | cut -d: -f2- | tr -d ' \r')
    [ -n "$_t" ] && CSRF="$_t"
}

login() {
    printf '{"username":"%s","password":"%s","remember":false}' \
        "$(json_escape "$UNIFI_USER")" "$(json_escape "$UNIFI_PASS")" > "$WORK/login.json"
    : > "$WORK/cookies"
    _code=$(curl_api POST "$BASE/api/auth/login" "$WORK/login.json")
    rm -f "$WORK/login.json"
    if [ "$_code" != "200" ]; then
        log ERROR "Login to $UNIFI_HOST failed (HTTP $_code). Check user/password; the account must be a local account without 2FA."
        return 1
    fi
    LOGGED_IN=1
    update_csrf
    return 0
}

# ---------------------------------------------------------------------------
# Time window
# ---------------------------------------------------------------------------
to_minutes() {
    # accepts 23, "23", "23:30", "6:05"; prints minutes since midnight or nothing
    _t=$(printf '%s' "$1" | tr -d ' ')
    case "$_t" in
        [0-9]|[0-9][0-9]) _h=$_t; _m=0 ;;
        [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) _h=${_t%%:*}; _m=${_t#*:} ;;
        *) return 1 ;;
    esac
    _h=$(expr "$_h" + 0); _m=$(expr "$_m" + 0)
    [ "$_h" -le 23 ] && [ "$_m" -le 59 ] || return 1
    echo $((_h * 60 + _m))
}

in_window() {
    # $1 start, $2 end, $3 now (minutes). Handles windows crossing midnight.
    if [ "$1" -lt "$2" ]; then
        [ "$3" -ge "$1" ] && [ "$3" -lt "$2" ]
    else
        [ "$3" -ge "$1" ] || [ "$3" -lt "$2" ]
    fi
}

# ---------------------------------------------------------------------------
# 1) Read shared config and decide whether it is night
# ---------------------------------------------------------------------------
NIGHT=0
REASON=""
KEEP_LIST=""
KEEP_GROUPS=""
IGNORE_LIST=""

if [ "$LIST_ONLY" = 0 ]; then
    if [ ! -r "$SHARED_CONFIG" ]; then
        REASON="shared config $SHARED_CONFIG not readable -> fail-safe: all APs on"
        log WARN "$REASON"
    elif ! tr -d '\r' < "$SHARED_CONFIG" | json_flat > "$WORK/cfg" 2>/dev/null || grep -q '^__error__' "$WORK/cfg"; then
        REASON="shared config is not valid JSON ($(grep '^__error__' "$WORK/cfg" | cut -f2)) -> fail-safe: all APs on"
        log WARN "$REASON"
    else
        ENABLED=$(lower "$(json_get "$WORK/cfg" enabled)")
        START_RAW=$(json_get "$WORK/cfg" start)
        END_RAW=$(json_get "$WORK/cfg" end)
        KEEP_LIST=$(json_list "$WORK/cfg" keep_on)
        # keep_on_group may be a single name or a list of names
        KEEP_GROUPS=$( { json_get "$WORK/cfg" keep_on_group; json_list "$WORK/cfg" keep_on_group; } | grep -v '^$')
        IGNORE_LIST=$(json_list "$WORK/cfg" ignore)

        START=$(to_minutes "$START_RAW")
        END=$(to_minutes "$END_RAW")
        NOW_RAW=${NIGHTMODE_NOW:-$(date '+%H:%M')}
        NOW=$(to_minutes "$NOW_RAW")

        if [ "$ENABLED" != "true" ]; then
            REASON="NightMode disabled in config"
        elif [ -z "$START" ] || [ -z "$END" ]; then
            REASON="invalid start/end in config (start=\"$START_RAW\" end=\"$END_RAW\", use \"23:00\") -> fail-safe: all APs on"
            log WARN "$REASON"
        elif [ "$START" = "$END" ]; then
            REASON="start equals end ($START_RAW) -> no night window"
            log WARN "$REASON"
        elif [ -z "$KEEP_LIST" ] && [ -z "$KEEP_GROUPS" ]; then
            REASON="keep_on and keep_on_group are empty -> refusing to turn off every AP, all APs on"
            log WARN "$REASON"
        elif in_window "$START" "$END" "$NOW"; then
            NIGHT=1
            REASON="night window $START_RAW-$END_RAW, now $NOW_RAW"
        else
            REASON="outside night window $START_RAW-$END_RAW, now $NOW_RAW"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2) Get the AP list from the controller
# ---------------------------------------------------------------------------
if [ -z "$UNIFI_HOST" ] || [ -z "$UNIFI_USER" ] || [ -z "$UNIFI_PASS" ]; then
    log ERROR "UNIFI_HOST / UNIFI_USER / UNIFI_PASS missing in $LOCAL_CONF"
    exit 2
fi

login || exit 1

CODE=$(curl_api GET "$API/stat/device" "")
if [ "$CODE" != "200" ]; then
    log ERROR "Reading device list failed (HTTP $CODE)"
    exit 1
fi
json_flat < "$WORK/resp" > "$WORK/dev" 2>/dev/null
if grep -q '^__error__' "$WORK/dev" || [ "$(json_get "$WORK/dev" meta.rc)" != "ok" ]; then
    log ERROR "Unexpected device list response from controller"
    exit 1
fi

# One line per access point: id<TAB>mac<TAB>disabled<TAB>state<TAB>name
awk -F '\t' '
    {
        split($1, p, ".")
        if (p[1] != "data" || p[3] == "" || p[4] != "") next
        i = p[2]; v = substr($0, length($1) + 2)
        seen[i] = 1
        if (p[3] == "_id") id[i] = v
        else if (p[3] == "mac") mac[i] = v
        else if (p[3] == "type") type[i] = v
        else if (p[3] == "disabled") dis[i] = v
        else if (p[3] == "state") st[i] = v
        else if (p[3] == "name") nm[i] = v
    }
    END {
        for (i = 0; i in seen; i++) {
            if (type[i] != "uap") continue
            d = (dis[i] == "true") ? "true" : "false"
            printf "%s\t%s\t%s\t%s\t%s\n", id[i], tolower(mac[i]), d, st[i], (nm[i] == "" ? mac[i] : nm[i])
        }
    }' "$WORK/dev" > "$WORK/aps"

AP_COUNT=$(wc -l < "$WORK/aps" | tr -d ' ')

# AP groups (Network app 8+): GET /proxy/network/v2/api/site/<site>/apgroups
# Returns a JSON array of {"_id","name","device_macs":[...]}.
# Writes $WORK/groups: name<TAB>mac mac mac...
fetch_groups() {
    _code=$(curl_api GET "$BASE/proxy/network/v2/api/site/$UNIFI_SITE/apgroups" "")
    if [ "$_code" != "200" ]; then
        log ERROR "Reading AP groups failed (HTTP $_code). AP groups need UniFi Network 8 or newer."
        return 1
    fi
    json_flat < "$WORK/resp" > "$WORK/grpflat" 2>/dev/null
    if grep -q '^__error__' "$WORK/grpflat"; then
        log ERROR "Unexpected AP group response from controller"
        return 1
    fi
    awk -F '\t' '
        {
            n = split($1, p, "."); v = substr($0, length($1) + 2)
            if (p[1] !~ /^[0-9]+$/) next
            seen[p[1]] = 1
            if (n == 2 && p[2] == "name") nm[p[1]] = v
            else if (n == 3 && p[2] == "device_macs") macs[p[1]] = macs[p[1]] " " tolower(v)
        }
        END { for (i = 0; i in seen; i++) printf "%s\t%s\n", nm[i], substr(macs[i], 2) }
    ' "$WORK/grpflat" > "$WORK/groups"
    return 0
}

if [ "$LIST_ONLY" = 1 ]; then
    printf '%-28s %-18s %-9s %s\n' NAME MAC DISABLED STATE
    while IFS="$(printf '\t')" read -r id mac dis st name; do
        case "$st" in 1) s=online ;; 0) s=offline ;; *) s="state=$st" ;; esac
        printf '%-28s %-18s %-9s %s\n' "$name" "$mac" "$dis" "$s"
    done < "$WORK/aps"
    echo "$AP_COUNT access point(s)"
    if fetch_groups; then
        echo
        echo "AP groups (use the name in \"keep_on_group\"):"
        while IFS="$(printf '\t')" read -r gname gmacs; do
            _members=""
            for _m in $gmacs; do
                _n=$(awk -F '\t' -v m="$_m" '$2 == m { print $5; exit }' "$WORK/aps")
                _members="$_members${_members:+, }${_n:-$_m}"
            done
            echo "  $gname: ${_members:-(no APs)}"
        done < "$WORK/groups"
    fi
    exit 0
fi

if [ "$AP_COUNT" -eq 0 ]; then
    log ERROR "Controller returned no access points (wrong site \"$UNIFI_SITE\"?)"
    exit 1
fi

# ---------------------------------------------------------------------------
# 3) Matching helpers (name case-insensitive, or MAC with : or -)
# ---------------------------------------------------------------------------
matches_list() {
    # $1 list (newline separated), $2 mac, $3 name
    _mac=$(norm_mac "$2"); _name=$(lower "$3")
    printf '%s\n' "$1" | while IFS= read -r _e; do
        [ -z "$_e" ] && continue
        _el=$(lower "$_e")
        if [ "$_el" = "$_name" ] || [ "$(norm_mac "$_e")" = "$_mac" ]; then echo yes; break; fi
    done
}

# Resolve keep_on_group names into MACs and add them to KEEP_LIST. If a named
# group can't be read or found, nothing is turned off (fail-safe).
if [ "$NIGHT" = 1 ] && [ -n "$KEEP_GROUPS" ]; then
    if ! fetch_groups; then
        NIGHT=0; REASON="AP groups unavailable -> fail-safe: all APs on"
    else
        _nl='
'
        _missing=""
        while IFS= read -r _g; do
            _gm=$(awk -F '\t' -v g="$(lower "$_g")" 'tolower($1) == g { print $2; exit }' "$WORK/groups")
            if ! awk -F '\t' -v g="$(lower "$_g")" 'tolower($1) == g { f = 1 } END { exit !f }' "$WORK/groups"; then
                _missing="$_missing${_missing:+, }$_g"
                continue
            fi
            for _m in $_gm; do KEEP_LIST="$KEEP_LIST${KEEP_LIST:+$_nl}$_m"; done
        done <<EOF_GROUPS
$KEEP_GROUPS
EOF_GROUPS
        if [ -n "$_missing" ]; then
            log ERROR "AP group(s) not found: $_missing -> not turning anything off (run --list to see group names)"
            NIGHT=0; REASON="keep_on_group not found"
        fi
    fi
fi

# Safety: at night, at least one keep_on AP must exist and be online.
if [ "$NIGHT" = 1 ]; then
    KEEP_FOUND=0; KEEP_ONLINE=0
    while IFS="$(printf '\t')" read -r id mac dis st name; do
        if [ -n "$(matches_list "$KEEP_LIST" "$mac" "$name")" ]; then
            KEEP_FOUND=$((KEEP_FOUND + 1))
            [ "$dis" = "false" ] && [ "$st" = "1" ] && KEEP_ONLINE=$((KEEP_ONLINE + 1))
        fi
    done < "$WORK/aps"
    if [ "$KEEP_FOUND" -eq 0 ]; then
        log ERROR "None of keep_on/keep_on_group ($(printf '%s' "$KEEP_LIST" | tr '\n' ',')) matches an AP name or MAC -> not turning anything off"
        NIGHT=0; REASON="keep_on matched no AP"
    fi
    KEEP_WAIT=0
    [ "$NIGHT" = 1 ] && [ "$KEEP_ONLINE" -eq 0 ] && KEEP_WAIT=1
fi

# ---------------------------------------------------------------------------
# 4) Converge
# ---------------------------------------------------------------------------
set_disabled() {
    # $1 id, $2 true|false, $3 label
    if [ "$DRY_RUN" = 1 ]; then
        log INFO "would set disabled=$2 on $3"
        return 0
    fi
    printf '{"disabled":%s}' "$2" > "$WORK/put.json"
    _code=$(curl_api PUT "$API/rest/device/$1" "$WORK/put.json")
    update_csrf
    if [ "$_code" = "200" ]; then
        if [ "$2" = "true" ]; then log INFO "turned OFF $3"; else log INFO "turned ON $3"; fi
        CHANGES=$((CHANGES + 1))
    else
        log ERROR "failed to set disabled=$2 on $3 (HTTP $_code)"
        FAILS=$((FAILS + 1))
    fi
}

CHANGES=0; FAILS=0
TAB="$(printf '\t')"

# Pass 1: enable everything that should be on (keep_on APs first, so they are
# up before others go dark).
while IFS="$TAB" read -r id mac dis st name; do
    [ -n "$(matches_list "$IGNORE_LIST" "$mac" "$name")" ] && continue
    want=false
    if [ "$NIGHT" = 1 ] && [ -z "$(matches_list "$KEEP_LIST" "$mac" "$name")" ]; then want=true; fi
    if [ "$want" = false ] && [ "$dis" = true ]; then
        set_disabled "$id" false "$name ($mac)"
    fi
done < "$WORK/aps"

# Pass 2: disable the rest (only if a keep_on AP is actually online).
if [ "$NIGHT" = 1 ]; then
    if [ "${KEEP_WAIT:-0}" = 1 ]; then
        log WARN "no keep_on AP is online yet -> waiting before turning others off (next run will retry)"
    else
        while IFS="$TAB" read -r id mac dis st name; do
            [ -n "$(matches_list "$IGNORE_LIST" "$mac" "$name")" ] && continue
            [ -n "$(matches_list "$KEEP_LIST" "$mac" "$name")" ] && continue
            [ "$dis" = false ] && set_disabled "$id" true "$name ($mac)"
        done < "$WORK/aps"
    fi
fi

MODE=day; [ "$NIGHT" = 1 ] && MODE=night
if [ "$CHANGES" -gt 0 ] || [ "$FAILS" -gt 0 ]; then
    log INFO "mode=$MODE ($REASON): $CHANGES change(s), $FAILS failure(s), $AP_COUNT APs"
else
    # one quiet line per run so you can see the job is alive
    log OK "mode=$MODE ($REASON): nothing to change, $AP_COUNT APs"
fi
trim_log
[ "$FAILS" -eq 0 ]
