#!/bin/bash

# Report the inventoried Google Chrome version and last check-in for target
# computers, looked up by serial number.
# Uses mjt instance picker for auth. Outputs CSV to /tmp.
#
# Usage: ./chrome-version-report.sh [-il INSTANCE_LIST] [-i INSTANCE_URL] [--debug]

# -------------------------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------------------------

target_serials=(
    "c426xkg17x"
    "d54ttgycjr"
    "d9xlw7clqh"
    "dcfjjn7ygj"
    "dlp6h2h6mw"
    "dn9qqc6l63"
    "fgm23lqjj4"
    "fhtvx296vh"
    "fv41j9wphr"
    "fw1ykf7x1x"
    "fx0ghd7347"
    "g1hhxrj9lj"
    "g6qn4clxl9"
    "g7k651qcf4"
    "gc5wjjmw6d"
    "gfthk4ld4x"
    "gkgwp6jx5j"
    "gl64rx9j2d"
    "gpmjy4m3q9"
    "h333gwkwq0"
    "h4cg6cw7vh"
    "h6yw04c612"
    "hcpxdgjwlf"
    "hd7vlxf3q9"
    "hqx5t2g9cp"
    "hx2qhwdph2"
    "j17vk0xxlm"
    "jgq9ft4291"
    "jgx7x3m2fw"
    "jjvm0dqnf7"
    "jmxp52q47k"
    "k3hwgxjyrr"
    "k4d4yqp6qq"
    "k93d2kl4ky"
    "k9ngqqmry2"
    "l477ycyyjf"
    "l4m52r3931"
    "l73912xpv3"
    "lhc4p4yyjx"
    "lvyj3190t7"
    "ly4wxv4y4g"
    "m4hf7n7c9n"
    "mfd9wp479c"
    "mghf4g627f"
    "mnq7p9xl7f"
    "mwg4qtjjxv"
    "nkwcxhhjwk"
    "pymqj6px0h"
    "qj16339426"
    "v1ffw6d063"
    "vrf2qnwqgq"
    "yn7f77x9m7"
)

# Application to report on (lowercase substring match against the app name)
app_label="Google Chrome"
app_pattern="google chrome"

# -------------------------------------------------------------------------
# ENVIRONMENT
# -------------------------------------------------------------------------

DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

debug=0

# -------------------------------------------------------------------------
# ARGS
# -------------------------------------------------------------------------

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -il|--instance-list) shift; chosen_instance_list_file="$1" ;;
        -i|--instance)       shift; chosen_instance="$1" ;;
        -a|--all)            all_instances=1 ;;
        --id|--client-id)    shift; chosen_id="$1" ;;
        -x|--nointeraction)  no_interaction=1 ;;
        -v|--verbose)        verbose=1 ;;
        --debug)             debug=1 ;;
        -h|--help)
            echo "Usage: $0 [-il INSTANCE_LIST] [-i INSTANCE_URL] [--debug]"
            exit 0
        ;;
    esac
    shift
done

# -------------------------------------------------------------------------
# MAIN
# -------------------------------------------------------------------------

choose_destination_instances

# Take the first chosen instance only - single-instance report
jss_instance="${instance_choice_array[0]:-$chosen_instance}"

if [[ -z "$jss_instance" ]]; then
    echo "ERROR: no instance selected."
    exit 1
fi

if [[ ${#instance_choice_array[@]} -gt 1 ]]; then
    echo "NOTE: this report runs against one instance at a time. Using: $jss_instance"
fi

# Authenticate
if [[ "$chosen_id" ]]; then
    set_credentials "$jss_instance" "$chosen_id"
else
    set_credentials "$jss_instance"
fi
check_token "$jss_instance"

token_file=$(/usr/bin/mktemp /tmp/jamfcli_token.XXXXXX)
echo "$token" > "$token_file"
trap '/bin/rm -f "$token_file"' EXIT

# Prepare output CSV
timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
instance_short="${jss_instance#*://}"
instance_short="${instance_short%%/*}"
csv_file="/tmp/chrome-version-report_${instance_short}_${timestamp}.csv"

printf 'Serial,Computer Name,%s Version,Last Check-in,Days Since Check-in\n' "$app_label" > "$csv_file"

echo
echo "Querying ${#target_serials[@]} computers on $jss_instance ..."
echo

# Look a serial up in Jamf. Jamf stores serials upper-cased, so try that first,
# then the serial exactly as supplied.
fetch_inventory() {
    local serial="$1" upper out variant
    upper=$(printf '%s' "$serial" | /usr/bin/tr 'a-z' 'A-Z')

    for variant in "$upper" "$serial"; do
        out=$(jamf-cli pro computer-inventory get \
            --serial "$variant" \
            --section GENERAL --section APPLICATIONS \
            --url "$jss_instance" \
            --token-file "$token_file" \
            -o json --no-hints --no-update-check --quiet 2>/dev/null)
        # jamf-cli prints a JSON error envelope on stdout when lookup fails
        if [[ -n "$out" && "$out" != "null" ]] \
            && ! printf '%s' "$out" | /usr/bin/grep -q '"exitCode"'; then
            printf '%s' "$out"
            return 0
        fi
        [[ "$upper" == "$serial" ]] && break
    done
    return 1
}

for serial in "${target_serials[@]}"; do
    printf "  %-12s ... " "$serial"

    inv_json=$(fetch_inventory "$serial")

    if [[ -z "$inv_json" ]]; then
        echo "NOT FOUND in Jamf"
        printf '%s,NOT FOUND,NOT FOUND,NOT FOUND,\n' "$serial" >> "$csv_file"
        continue
    fi

    if [[ $debug -eq 1 ]]; then
        echo
        printf '%s' "$inv_json" | /usr/bin/head -c 2000
        echo
        debug=0
    fi

    # Emit: computer name, app version, last contact date, days since contact
    row=$(printf '%s' "$inv_json" | J_PATTERN="$app_pattern" /usr/local/autopkg/python -c '
import sys, json, os, datetime, re

pattern = os.environ.get("J_PATTERN", "").lower()

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

# unwrap a list or a {"results": [...]} envelope
if isinstance(data, dict) and isinstance(data.get("results"), list):
    data = data["results"][0] if data["results"] else {}
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    sys.exit(1)

general = data.get("general") or {}
name = general.get("name") or ""

apps = data.get("applications") or []
versions = []
for a in apps:
    if not isinstance(a, dict):
        continue
    if pattern in str(a.get("name") or "").lower():
        v = str(a.get("version") or "").strip()
        if v and v not in versions:
            versions.append(v)
version = " / ".join(versions) if versions else "Not Installed"

last = ""
for key in ("lastContact", "lastCheckIn", "lastContactTime"):
    v = general.get(key)
    if v:
        last = str(v)
        break
last_fmt = ""
days = ""
if last:
    iso = last.replace("Z", "+00:00")
    # Python 3.10 fromisoformat only accepts 3 or 6 fractional digits
    iso = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), iso)
    try:
        dt = datetime.datetime.fromisoformat(iso)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        last_fmt = dt.strftime("%Y-%m-%d %H:%M")
        days = str((datetime.datetime.now(datetime.timezone.utc) - dt).days)
    except Exception:
        last_fmt = last
else:
    last_fmt = "Never"

def esc(s):
    s = str(s)
    if "," in s or "\"" in s:
        return "\"" + s.replace("\"", "\"\"") + "\""
    return s

print("\t".join([esc(name), esc(version), esc(last_fmt), esc(days)]))
' 2>/dev/null)

    if [[ -z "$row" ]]; then
        echo "PARSE ERROR"
        printf '%s,PARSE ERROR,,,\n' "$serial" >> "$csv_file"
        continue
    fi

    IFS=$'\t' read -r c_name c_version c_last c_days <<< "$row"

    printf '%s (%s, last seen %s)\n' "$c_version" "$c_name" "$c_last"
    printf '%s,%s,%s,%s,%s\n' "$serial" "$c_name" "$c_version" "$c_last" "$c_days" >> "$csv_file"
done

echo
echo "Done. CSV written to:"
echo "  $csv_file"
echo
