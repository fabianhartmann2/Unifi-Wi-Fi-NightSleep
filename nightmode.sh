#!/bin/sh
# =============================================================================
# NightMode for UniFi (UDM / UniFi OS) - run on a Synology NAS
#
# Turns UniFi access points off and on by schedule. The shared JSON file
# gives each UniFi AP Group its own "off" time window (e.g. the evening group
# off 22:00-06:00, the night group never off), plus a default window for all
# APs that are in none of the listed groups (e.g. off 19:00-08:00).
#
# The script is idempotent: run it every 15 minutes from the DSM Task
# Scheduler and it converges to the desired state, only changing APs whose
# state differs. Needs only: sh, curl, awk, sed, grep, tr (no jq, no python).
#
# Usage:
#   nightmode.sh [-c local.conf] [--dry-run] [--list] [--debug]
#     -c FILE     local settings/credentials file (default: nightmode.conf
#                 next to this script)
#     --dry-run   show what would change, change nothing
#     --list      print all APs (name, MAC, state) and all AP groups, then
#                 exit; use it to get the group names for the shared JSON
#     --debug     print HTTP status and the start of each controller response
#                 to the terminal (passwords, keys and tokens are redacted)
#
# Testing hook: NIGHTMODE_NOW=HH:MM overrides the current time.
# =============================================================================

set -u
umask 077
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOCAL_CONF="$SCRIPT_DIR/nightmode.conf"
DRY_RUN=0
DEBUG=0
LIST_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c) LOCAL_CONF="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --debug) DEBUG=1; shift ;;
        -h|--help) sed -n "2,24p" "$0"; exit 0 ;;
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
trap 'exit 1' INT TERM HUP PIPE

# ---------------------------------------------------------------------------
# Minimal JSON flattener (awk). Input: JSON. Output lines: path<TAB>value
# e.g. "enabled<TAB>true", "keep_on.0<TAB>AP-Office", "data.3.mac<TAB>aa:.."
# The input is first cut at every double quote (tr), so awk only ever sees
# short lines. This keeps it fast and avoids line/string size limits of some
# awk versions (macOS awk failed on one 480 KB line). Raw newlines can only be
# whitespace in valid JSON, so they are turned into spaces first.
# ---------------------------------------------------------------------------
json_flat() {
    { tr '\r\n' '  '; echo; } | tr '"' '\n' | awk '
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
    # each input line is the text between two double quotes; lines
    # alternate between outside-a-string and inside-a-string
    {
        if (!inside) { lex($0); inside = 1; open_str = 0 }
        else {
            open_str = 1
            sbuf = sbuf $0
            if (trailing_bs(sbuf) % 2 == 1) { sbuf = sbuf "\""; next }   # escaped quote
            add("s", unesc(sbuf)); sbuf = ""; inside = 0; open_str = 0
        }
    }
    END {
        if (err) exit 1
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

# debug_resp LABEL CODE: show status, headers of interest and a redacted preview
debug_resp() {
    [ "$DEBUG" = 1 ] || return 0
    {
        echo "----- DEBUG $1: HTTP $2"
        grep -i -E '^(content-type|content-length|location):' "$WORK/hdr" 2>/dev/null | tr -d '\r' | sed 's/^/  /'
        echo "  csrf token received: $([ -n "$CSRF" ] && echo yes || echo no)"
        echo "  body bytes: $(wc -c < "$WORK/resp" 2>/dev/null | tr -d ' ')"
        if [ "${3:-}" = nobody ]; then echo "  (body not shown)"; echo; return 0; fi
        echo "  body start (redacted):"
        head -c 800 "$WORK/resp" 2>/dev/null | tr -d '\r' | redact | fold -w 160 | sed 's/^/    /'
        echo
    } >&2
}

# redact secrets in JSON text: any key containing pass, key, token, secret, psk
redact() {
    sed -E 's/"([A-Za-z0-9_]*([Pp]ass|[Kk]ey|[Tt]oken|[Ss]ecret|psk)[A-Za-z0-9_]*)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"***"/g'
}

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
    update_csrf
    debug_resp login "$_code" nobody
    if [ "$_code" != "200" ]; then
        log ERROR "Login to $UNIFI_HOST failed (HTTP $_code). Check user/password; the account must be a local account without 2FA."
        return 1
    fi
    LOGGED_IN=1
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
# 1) Read the shared config into rules
#
#   $WORK/rules : rule-no<TAB>active(1 = should be off now)<TAB>description
#   $WORK/rmatch: rule-no<TAB>group|ap<TAB>value
#   rule 0 is the "default" rule for APs that are in none of the groups.
# ---------------------------------------------------------------------------
FAILSAFE=""          # non-empty: turn every AP on, with this reason
DISABLED=0
IGNORE_LIST=""
RULES="$WORK/rules"; : > "$RULES"
RMATCH="$WORK/rmatch"; : > "$RMATCH"
TAB="$(printf '\t')"
NOW_RAW=${NIGHTMODE_NOW:-$(date '+%H:%M')}
NOW=$(to_minutes "$NOW_RAW")

# rule_state OFF FROM UNTIL -> prints "active<TAB>description", fails if invalid
rule_state() {
    case "$(lower "$1")" in
        never) printf '0\tnever off\n'; return 0 ;;
        always) printf '1\talways off\n'; return 0 ;;
        "") ;;
        *) return 1 ;;
    esac
    _s=$(to_minutes "$2") || return 1
    _e=$(to_minutes "$3") || return 1
    [ -n "$_s" ] && [ -n "$_e" ] && [ "$_s" != "$_e" ] || return 1
    if in_window "$_s" "$_e" "$NOW"; then _a=1; else _a=0; fi
    printf '%s\toff %s-%s\n' "$_a" "$2" "$3"
}

add_rule() {
    # $1 no, $2 label, $3 off, $4 from, $5 until
    if ! _st=$(rule_state "$3" "$4" "$5"); then
        FAILSAFE="invalid time in $2 (off_from=\"$4\" off_until=\"$5\" off=\"$3\"; use \"22:00\" or \"off\": \"never\")"
        return 1
    fi
    printf '%s\t%s\t%s: %s\n' "$1" "${_st%%"$TAB"*}" "$2" "${_st#*"$TAB"}" >> "$RULES"
}

if [ "$LIST_ONLY" = 0 ]; then
    if [ ! -r "$SHARED_CONFIG" ]; then
        FAILSAFE="shared config $SHARED_CONFIG not readable"
    elif ! tr -d '\r' < "$SHARED_CONFIG" | json_flat > "$WORK/cfg" 2>/dev/null || grep -q '^__error__' "$WORK/cfg"; then
        FAILSAFE="shared config is not valid JSON ($(grep '^__error__' "$WORK/cfg" | cut -f2))"
    elif [ "$(lower "$(json_get "$WORK/cfg" enabled)")" != "true" ]; then
        DISABLED=1
    else
        IGNORE_LIST=$(json_list "$WORK/cfg" ignore)
        if [ -z "$NOW" ]; then
            FAILSAFE="cannot read current time \"$NOW_RAW\""
        elif grep -q -E '^(default|groups)(\.|	)' "$WORK/cfg"; then
            # current format: "default" + "groups"
            if grep -q '^default\.' "$WORK/cfg"; then
                add_rule 0 "default" "$(json_get "$WORK/cfg" default.off)" \
                    "$(json_get "$WORK/cfg" default.off_from)" "$(json_get "$WORK/cfg" default.off_until)"
            else
                printf '0\t0\tdefault: never off\n' >> "$RULES"
            fi
            for _n in $(awk -F '\t' '{ split($1, p, "."); if (p[1] == "groups" && p[2] ~ /^[0-9]+$/ && !s[p[2]]++) print p[2] }' "$WORK/cfg"); do
                [ -n "$FAILSAFE" ] && break
                _r=$((_n + 1))
                _gl=$( { json_get "$WORK/cfg" "groups.$_n.group"; json_list "$WORK/cfg" "groups.$_n.group"; } | grep -v '^$')
                _al=$(json_list "$WORK/cfg" "groups.$_n.aps")
                if [ -z "$_gl" ] && [ -z "$_al" ]; then
                    FAILSAFE="entry $_r in \"groups\" has neither \"group\" nor \"aps\""; break
                fi
                _label=$(printf '%s' "$_gl $_al" | tr '\n' ',' | sed 's/^ //; s/,$//; s/ $//')
                add_rule "$_r" "$_label" "$(json_get "$WORK/cfg" "groups.$_n.off")" \
                    "$(json_get "$WORK/cfg" "groups.$_n.off_from")" "$(json_get "$WORK/cfg" "groups.$_n.off_until")" || break
                printf '%s\n' "$_gl" | while IFS= read -r _v; do [ -n "$_v" ] && printf '%s\tgroup\t%s\n' "$_r" "$_v"; done >> "$RMATCH"
                printf '%s\n' "$_al" | while IFS= read -r _v; do [ -n "$_v" ] && printf '%s\tap\t%s\n' "$_r" "$_v"; done >> "$RMATCH"
            done
        elif [ -n "$(json_get "$WORK/cfg" start)" ]; then
            # old format (start/end/keep_on_group/keep_on): still understood
            add_rule 0 "default" "" "$(json_get "$WORK/cfg" start)" "$(json_get "$WORK/cfg" end)"
            printf '1\t0\tkeep_on: never off\n' >> "$RULES"
            { json_get "$WORK/cfg" keep_on_group; json_list "$WORK/cfg" keep_on_group; } | grep -v '^$' \
                | while IFS= read -r _v; do printf '1\tgroup\t%s\n' "$_v"; done >> "$RMATCH"
            json_list "$WORK/cfg" keep_on | while IFS= read -r _v; do [ -n "$_v" ] && printf '1\tap\t%s\n' "$_v"; done >> "$RMATCH"
        else
            FAILSAFE="config has no \"default\" or \"groups\""
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
debug_resp "stat/device ($API/stat/device)" "$CODE"
if [ "$CODE" != "200" ]; then
    log ERROR "Reading device list failed (HTTP $CODE)"
    exit 1
fi
json_flat < "$WORK/resp" > "$WORK/dev" 2>"$WORK/awkerr"
if [ "$DEBUG" = 1 ]; then
    {
        echo "----- DEBUG parsed device list: $(wc -l < "$WORK/dev" | tr -d ' ') values, awk: $(awk --version 2>&1 | head -n 1)"
        [ -s "$WORK/awkerr" ] && sed 's/^/  awk stderr: /' "$WORK/awkerr"
        grep -E '^(__error__|meta\.)' "$WORK/dev" | sed 's/^/  /'
        grep -E '^data\.0\.(type|model|name|state|disabled)	' "$WORK/dev" | sed 's/^/  /'
    } >&2
fi
if grep -q '^__error__' "$WORK/dev"; then
    log ERROR "Could not parse device list ($(grep '^__error__' "$WORK/dev" | cut -f2)). Run with --debug and send the output."
    exit 1
fi
if [ ! -s "$WORK/dev" ] && [ -s "$WORK/awkerr" ]; then
    log ERROR "JSON parser failed: $(head -n 1 "$WORK/awkerr"). Run with --debug and send the output."
    exit 1
fi
RC=$(json_get "$WORK/dev" meta.rc)
if [ "$RC" != "ok" ]; then
    log ERROR "Unexpected device list response from controller (meta.rc=\"$RC\" msg=\"$(json_get "$WORK/dev" meta.msg)\"). Run with --debug and send the output."
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
    debug_resp apgroups "$_code"
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
        echo "AP groups (use these names in \"group\"):"
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
# 3) Resolve groups to MACs and work out the wanted state of every AP
# ---------------------------------------------------------------------------
# $WORK/matchers: rule-no<TAB>lowercase MAC or AP name
: > "$WORK/matchers"
if [ -z "$FAILSAFE" ] && [ "$DISABLED" = 0 ]; then
    awk -F '\t' '$2 == "ap" { v = tolower($3); if (v ~ /^([0-9a-f][0-9a-f][-:]){5}[0-9a-f][0-9a-f]$/) gsub(/-/, ":", v); print $1 "\t" v }' "$RMATCH" >> "$WORK/matchers"
    if grep -q "	group	" "$RMATCH"; then
        if ! fetch_groups; then
            FAILSAFE="AP groups could not be read"
        else
            _missing=$(awk -F '\t' '
                FILENAME == gf { g[tolower($1)] = $2; next }
                $2 == "group" {
                    k = tolower($3)
                    if (!(k in g)) { miss = miss (miss == "" ? "" : ", ") $3; next }
                    n = split(g[k], m, " ")
                    for (j = 1; j <= n; j++) print $1 "\t" m[j] >> out
                }
                END { print miss }' out="$WORK/matchers" gf="$WORK/groups" "$WORK/groups" "$RMATCH")
            [ -n "$_missing" ] && FAILSAFE="AP group(s) not found: $_missing (run --list to see group names)"
        fi
    fi
fi
printf '%s\n' "$IGNORE_LIST" | awk 'NF { v = tolower($0); gsub(/-/, ":", v); print v; print tolower($0) }' > "$WORK/ignore"

# plan: id<TAB>mac<TAB>disabled<TAB>state<TAB>name<TAB>want(on|off|skip)<TAB>note
plan() {
    awk -F '\t' -v failsafe="$1" '
        FILENAME == ARGV[1] { act[$1] = $2; desc[$1] = $3; next }
        FILENAME == ARGV[2] { mt[$2] = mt[$2] " " $1; next }
        FILENAME == ARGV[3] { ign[$0] = 1; next }
        {
            mac = $2; nm = tolower($5)
            if ((mac in ign) || (nm in ign)) { print $0 "\tskip\tignored"; next }
            if (failsafe != "") { print $0 "\ton\t"; next }
            # rules this AP belongs to (by MAC, or by name for "aps" entries)
            list = mt[mac] " " mt[nm]; n = split(list, r, " ")
            delete seen; cnt = 0; off = 1; names = ""
            for (j = 1; j <= n; j++) {
                if (r[j] in seen) continue
                seen[r[j]] = 1; cnt++
                if (act[r[j]] != 1) off = 0
                d = desc[r[j]]; sub(/:.*/, "", d); names = names (names == "" ? "" : ", ") d
            }
            if (cnt == 0) { off = (act[0] == 1); note = "default" }
            else if (cnt == 1) note = names
            else note = "in " cnt " groups (" names "), longest on-time wins"
            print $0 "\t" (off ? "off" : "on") "\t" note
        }' "$RULES" "$WORK/matchers" "$WORK/ignore" "$WORK/aps"
}

plan "$FAILSAFE$( [ "$DISABLED" = 1 ] && echo disabled)" > "$WORK/plan"

# Safety: never turn off every AP; and only turn APs off while at least one
# AP that should stay on is actually online.
WANT_OFF=$(awk -F '\t' '$6 == "off"' "$WORK/plan" | wc -l | tr -d ' ')
WANT_ON=$(awk -F '\t' '$6 == "on"' "$WORK/plan" | wc -l | tr -d ' ')
ON_ONLINE=$(awk -F '\t' '$6 != "off" && $3 == "false" && $4 == "1"' "$WORK/plan" | wc -l | tr -d ' ')
if [ -z "$FAILSAFE" ] && [ "$WANT_OFF" -gt 0 ] && [ "$WANT_ON" -eq 0 ]; then
    FAILSAFE="the schedule would turn off every AP right now"
fi
if [ -n "$FAILSAFE" ]; then
    log WARN "$FAILSAFE -> fail-safe: all APs on"
    plan "$FAILSAFE" > "$WORK/plan"
    WANT_OFF=0
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

# Pass 1: turn on everything that should be on, before anything goes dark.
while IFS="$TAB" read -r id mac dis st name want note; do
    [ "$want" = on ] && [ "$dis" = true ] && set_disabled "$id" false "$name ($mac)${note:+ [$note]}"
done < "$WORK/plan"

# Pass 2: turn off the rest, but only once an AP that stays on is online.
if [ "$WANT_OFF" -gt 0 ]; then
    if [ "$ON_ONLINE" -eq 0 ]; then
        log WARN "no AP that should stay on is online yet -> waiting before turning others off (next run will retry)"
    else
        while IFS="$TAB" read -r id mac dis st name want note; do
            [ "$want" = off ] && [ "$dis" = false ] && set_disabled "$id" true "$name ($mac)${note:+ [$note]}"
        done < "$WORK/plan"
    fi
fi

if [ "$DISABLED" = 1 ]; then
    SUMMARY="NightMode disabled in config"
elif [ -n "$FAILSAFE" ]; then
    SUMMARY="fail-safe: $FAILSAFE"
else
    SUMMARY="now $NOW_RAW, $(awk -F '\t' '{ printf "%s%s%s", (NR > 1 ? "; " : ""), $3, ($2 == 1 ? " (active)" : "") }' "$RULES")"
fi
WANT_OFF_NOW=$(awk -F '\t' '$6 == "off"' "$WORK/plan" | wc -l | tr -d ' ')
COUNTS="$WANT_OFF_NOW of $AP_COUNT APs scheduled off"
if [ "$CHANGES" -gt 0 ] || [ "$FAILS" -gt 0 ]; then
    log INFO "$SUMMARY: $COUNTS, $CHANGES change(s), $FAILS failure(s)"
else
    # one quiet line per run so you can see the job is alive
    log OK "$SUMMARY: $COUNTS, nothing to change"
fi
trim_log
[ "$FAILS" -eq 0 ]
