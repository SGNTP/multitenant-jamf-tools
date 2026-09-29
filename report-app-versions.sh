#!/bin/bash

# Report the inventoried version(s) of any app across target computers.
# App and target devices are specified at runtime — no hardcoded lists.
#
# Target selection (pick one):
#   --serial S1 S2 ...       Explicit serial numbers
#   --name N1 N2 ...         Exact computer names
#   --name-match PATTERN     Case-insensitive partial name match (fetches all inventory)
#   --group GROUP_NAME       Smart or static computer group
#
# Usage:
#   ./report-app-versions.sh [-il LIST] [-i URL] \
#       --app "google chrome" \
#       --group "All Managed"

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

# Record a target mode, rejecting a second, different one.
set_target_mode() {
    if [[ -n "$target_mode" && "$target_mode" != "$1" ]]; then
        echo "ERROR: only one of --serial, --name, --name-match, --group may be used at a time."
        exit 1
    fi
    target_mode="$1"
}

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
        --serial|--name)
            set_target_mode "${1#--}"
            shift
            while [[ "$#" -gt 0 && "$1" != -* ]]; do
                target_values+=("$1"); shift
            done
            continue
            ;;
        --name-match)  set_target_mode "name-match"; shift; target_values=("$1") ;;
        --group)       set_target_mode "group"; shift; group_name="$1" ;;
        -h|--help)
            echo "Usage: $0 [MJT flags] --app PATTERN [target flags]"
            echo ""
            echo "Target (pick one; interactive menu if omitted):"
            echo "  --serial S1 S2 ...       Explicit serial numbers"
            echo "  --name N1 N2 ...         Exact computer names"
            echo "  --name-match PATTERN     Partial name match"
            echo "  --group GROUP_NAME       Computer group (smart or static)"
            echo ""
            echo "App:"
            echo "  --app PATTERN            Substring to match against app names (case-insensitive)"
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

# Prompt for app if not supplied
if [[ -z "$app_label" ]]; then
    read -r -p 'App to report on (substring match, e.g. "google chrome"): ' app_label
fi
if [[ -z "$app_label" ]]; then
    echo "ERROR: an --app pattern is required."
    exit 1
fi
app_pattern=$(printf '%s' "$app_label" | /usr/bin/tr '[:upper:]' '[:lower:]')

if [[ -z "$target_mode" && ( "${no_interaction:-0}" -eq 1 || ! -t 0 ) ]]; then
    echo "ERROR: specify a target via --serial, --name, --name-match, or --group."
    exit 1
fi

# -------------------------------------------------------------------------
# INSTANCE SELECTION
# -------------------------------------------------------------------------

resolve_jamf_cli || exit 1

choose_destination_instances

jss_instance="${instance_choice_array[0]:-$chosen_instance}"
if [[ -z "$jss_instance" ]]; then
    echo "ERROR: no instance selected."
    exit 1
fi
if [[ ${#instance_choice_array[@]} -gt 1 ]]; then
    echo "NOTE: this report runs against one instance at a time. Using: $jss_instance"
fi

trap remove_jamfcli_token EXIT
if ! token_for_instance "$jss_instance"; then
    echo "ERROR: could not obtain a token for $jss_instance"
    exit 1
fi

# -------------------------------------------------------------------------
# RESOLVE TARGET SERIALS
# -------------------------------------------------------------------------

if [[ -z "$target_mode" ]]; then
    choose_computer_targets || exit 1
fi

resolve_target_serials

if [[ ${#resolved_serials[@]} -eq 0 ]]; then
    echo "ERROR: no target computers resolved."
    exit 1
fi

# -------------------------------------------------------------------------
# OUTPUT
# -------------------------------------------------------------------------

timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
instance_short="${jss_instance#*://}"
instance_short="${instance_short%%/*}"
choose_output_dir || exit 1
csv_file="${output_dir}/report-app-versions_${instance_short}_${timestamp}.csv"

csv_label=${app_label//\"/\"\"}
printf 'Serial,Computer Name,Username,"%s Version",Last Check-in,Days Since Check-in\n' "$csv_label" > "$csv_file"

# -------------------------------------------------------------------------
# FETCH AND PARSE
# -------------------------------------------------------------------------

echo ""
echo "Querying ${#resolved_serials[@]} computer(s) on $jss_instance for \"$app_label\"..."
echo ""

for serial in "${resolved_serials[@]}"; do
    printf "  %-14s ... " "$serial"

    inv_json=$(fetch_computer_by_serial "$serial" GENERAL APPLICATIONS USER_AND_LOCATION)

    if [[ -z "$inv_json" ]]; then
        echo "NOT FOUND in Jamf"
        printf '%s,NOT FOUND,,,,\n' "$serial" >> "$csv_file"
        continue
    fi

    if [[ $debug -eq 1 ]]; then
        printf '%s' "$inv_json" | /usr/bin/head -c 2000
        echo
    fi

    row=$( printf '%s' "$inv_json" | J_PATTERN="$app_pattern" J_SERIAL="$serial" /usr/bin/python3 -c '
import csv, datetime, io, json, os, re, sys

pattern = os.environ.get("J_PATTERN", "").lower()

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

if isinstance(data, dict) and isinstance(data.get("results"), list):
    data = data["results"][0] if data["results"] else {}
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    sys.exit(1)

general = data.get("general") or {}
name    = general.get("name") or ""

ul       = data.get("userAndLocation") or {}
username = (ul.get("username") or ul.get("realname") or "").strip()

apps     = data.get("applications") or []
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
