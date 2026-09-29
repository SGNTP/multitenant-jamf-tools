#!/bin/bash

# Report the inventoried version(s) of any app across target macOS computers
# or iOS / iPadOS devices. Platform, app and targets are chosen at runtime —
# no hardcoded lists.
#
# Platform (menu if omitted):
#   --macos | --ios
#
# Target selection (pick one):
#   --serial S1 S2 ...       Explicit serial numbers
#   --name N1 N2 ...         Exact computer / device names
#   --name-match PATTERN     Case-insensitive partial name match (fetches all inventory)
#   --group GROUP_NAME       Smart or static computer / mobile device group
#
# Usage:
#   ./report-app-versions.sh [-il LIST] [-i URL] [--macos|--ios] \
#       --app "google chrome" \
#       --group "All Managed"

# set to mac or ios by choose_device_platform
instance_list_type="mac"

# -------------------------------------------------------------------------
# ENVIRONMENT
# -------------------------------------------------------------------------

DIR=$(/usr/bin/dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# -------------------------------------------------------------------------
# ARGS
# -------------------------------------------------------------------------

target_mode=""
target_values=()
group_name=""
app_pattern=""
app_label=""
output_dir=""
debug=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -il|--instance-list)  shift; chosen_instance_list_file="$1" ;;
        -i|--instance)        shift; chosen_instance="$1" ;;
        -a|--all-instances)   all_instances=1 ;;
        --id|--client-id)     shift; chosen_id="$1" ;;
        -x|--nointeraction)   no_interaction=1 ;;
        -v|--verbose)         verbose=1 ;;
        -j|--jamf-cli)        shift; jamf_cli_path="$1" ;;
        -o|--output-dir)      shift; output_dir="$1" ;;
        --debug)              debug=1 ;;
        --app)                shift; app_label="$1" ;;
        --macos|--mac|--ios|--ipados|--mobile) parse_platform_arg "$1" ;;
        --serial|--name|--name-match|--group)
            parse_target_arg "$@" || exit 1
            shift "$target_args_used"
            continue
            ;;
        -h|--help)
            echo "Usage: $0 [MJT flags] [--macos|--ios] --app PATTERN [target flags]"
            echo ""
            print_platform_usage
            echo ""
            print_target_usage
            echo ""
            echo "App:"
            echo "  --app PATTERN            Substring to match against app names or bundle IDs"
            echo "                           (case-insensitive)"
            echo "                           (interactive prompt if omitted)"
            echo ""
            echo "Output:"
            echo "  -o  | --output-dir DIR   Where to save the CSV (prompts /tmp or ~/Desktop if omitted)"
            echo ""
            echo "MJT flags:"
            echo "  -il | --instance-list FILENAME"
            echo "  -i  | --instance URL"
            echo "  -a  | --all-instances"
            echo "  --id | --client-id CLIENT_ID"
            echo "  -j  | --jamf-cli PATH"
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1 (see --help)"
            exit 1
            ;;
    esac
    shift
done

choose_device_platform || exit 1

# Prompt for app if not supplied
if [[ -z "$app_label" ]]; then
    read -r -p 'App to report on (substring match, e.g. "google chrome"): ' app_label
fi
if [[ -z "$app_label" ]]; then
    echo "ERROR: an --app pattern is required."
    exit 1
fi
app_pattern=$(to_lower "$app_label")

require_device_target || exit 1

# -------------------------------------------------------------------------
# INSTANCE SELECTION
# -------------------------------------------------------------------------

resolve_jamf_cli || exit 1

trap remove_jamfcli_token EXIT
choose_single_instance || exit 1

# -------------------------------------------------------------------------
# RESOLVE TARGET SERIALS
# -------------------------------------------------------------------------

select_target_serials || exit 1

# -------------------------------------------------------------------------
# OUTPUT
# -------------------------------------------------------------------------

timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
instance_short=$(url_host "$jss_instance")
choose_output_dir || exit 1
csv_file="${output_dir}/report-app-versions_$(platform_slug)_${instance_short}_${timestamp}.csv"

csv_label=${app_label//\"/\"\"}
if is_mobile_platform; then
    name_col="Device Name"; seen_col="Last Inventory Update"; seen_days_col="Days Since Inventory"
else
    name_col="Computer Name"; seen_col="Last Check-in"; seen_days_col="Days Since Check-in"
fi
printf 'Serial,%s,Username,"%s Version",%s,%s\n' \
    "$name_col" "$csv_label" "$seen_col" "$seen_days_col" > "$csv_file"

# -------------------------------------------------------------------------
# FETCH AND PARSE
# -------------------------------------------------------------------------

echo ""
echo "Querying ${#resolved_serials[@]} $(device_noun)(s) on $jss_instance for \"$app_label\"..."
echo ""

for serial in "${resolved_serials[@]}"; do
    printf "  %-14s ... " "$serial"

    raw_json=$(fetch_device_by_serial "$serial" GENERAL APPLICATIONS USER_AND_LOCATION)

    if [[ $debug -eq 1 && -n "$raw_json" ]]; then
        printf '%s' "$raw_json" | /usr/bin/head -c 2000
        echo
    fi

    if [[ -z "$raw_json" ]]; then
        echo "NOT FOUND in Jamf"
        printf '%s,NOT FOUND,,,,\n' "$serial" >> "$csv_file"
        continue
    fi

    inv_json=$(printf '%s' "$raw_json" | normalise_device_json)

    row=$( printf '%s' "$inv_json" | J_PATTERN="$app_pattern" J_SERIAL="$serial" /usr/bin/python3 -c '
import csv, datetime, io, json, os, re, sys

pattern = os.environ.get("J_PATTERN", "").lower()

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

# normalise_device_json shape: name, username, last_seen, apps[{name, id, version}]
name     = data.get("name") or ""
username = data.get("username") or ""

versions = []
for a in data.get("apps") or []:
    if pattern in a.get("name", "").lower() or pattern in a.get("id", "").lower():
        v = a.get("version", "")
        if v and v not in versions:
            versions.append(v)
version = " / ".join(versions) if versions else "Not Installed"

last = data.get("last_seen") or ""
last_fmt = ""
days = ""
if last:
    iso = last.replace("Z", "+00:00")
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

# Line 1: console summary. Line 2: finished CSV row.
print("%s (%s, user: %s, last seen %s)" % (version, name, username or "unknown", last_fmt))
buf = io.StringIO()
csv.writer(buf, lineterminator="").writerow([os.environ.get("J_SERIAL", ""), name, username, version, last_fmt, days])
print(buf.getvalue())
' 2>/dev/null)

    if [[ -z "$row" ]]; then
        echo "PARSE ERROR"
        printf '%s,PARSE ERROR,,,,\n' "$serial" >> "$csv_file"
        continue
    fi

    printf '%s\n' "${row%%$'\n'*}"
    printf '%s\n' "${row#*$'\n'}" >> "$csv_file"
done

echo ""
echo "Done. CSV written to:"
echo "  $csv_file"
echo ""
