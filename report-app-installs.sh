#!/bin/bash

# Report whether specific apps are installed on target computers.
# Apps and target devices are specified at runtime — no hardcoded lists.
#
# Target selection (pick one):
#   --serial S1 S2 ...       Explicit serial numbers
#   --name N1 N2 ...         Exact computer names
#   --name-match PATTERN     Case-insensitive partial name match (fetches all inventory)
#   --group GROUP_NAME       Smart or static computer group
#
# Apps:
#   --app PATTERN            Substring to match (may be repeated for multiple apps)
#                            (interactive prompt if omitted)
#
# Usage:
#   ./report-app-installs.sh [-il LIST] [-i URL] \
#       --app "musescore" --app "sibelius" --app "logic pro" \
#       --group "NOR Music Labs"

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
app_patterns=()
output_dir=""

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
        --app)                shift; app_patterns+=("$(to_lower "$1")") ;;
        --serial|--name|--name-match|--group)
            parse_target_arg "$@" || exit 1
            shift "$target_args_used"
            continue
            ;;
        -h|--help)
            echo "Usage: $0 [MJT flags] --app PATTERN [--app PATTERN ...] [target flags]"
            echo ""
            print_target_usage
            echo ""
            echo "Apps:"
            echo "  --app PATTERN            Substring match (repeat for multiple apps)"
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

# Prompt for apps if none supplied
if [[ ${#app_patterns[@]} -eq 0 ]]; then
    echo "Enter app names to check (one per line, blank line to finish):"
    while true; do
        read -r -p '  App pattern: ' p
        [[ -z "$p" ]] && break
        app_patterns+=("$(to_lower "$p")")
    done
fi

if [[ ${#app_patterns[@]} -eq 0 ]]; then
    echo "ERROR: at least one --app pattern is required."
    exit 1
fi

require_computer_target || exit 1

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
csv_file="${output_dir}/report-app-installs_${instance_short}_${timestamp}.csv"

# Header: Serial, Computer Name, Username, one column per app
{
    printf 'Serial,Computer Name,Username'
    for p in "${app_patterns[@]}"; do
        printf ',"%s"' "${p//\"/\"\"}"
    done
    printf '\n'
} > "$csv_file"

# -------------------------------------------------------------------------
# FETCH AND PARSE
# -------------------------------------------------------------------------

echo ""
echo "Querying ${#resolved_serials[@]} computer(s) on $jss_instance..."
echo ""

for serial in "${resolved_serials[@]}"; do
    printf "  %-14s ... " "$serial"

    inv_json=$(fetch_computer_by_serial "$serial" GENERAL APPLICATIONS USER_AND_LOCATION)

    if [[ -z "$inv_json" ]]; then
        echo "NOT FOUND in Jamf"
        printf '%s,NOT FOUND,' "$serial" >> "$csv_file"
        for p in "${app_patterns[@]}"; do
            printf ',NOT FOUND' >> "$csv_file"
        done
        printf '\n' >> "$csv_file"
        continue
    fi

    patterns=$(printf '%s\n' "${app_patterns[@]}")
    row=$(printf '%s' "$inv_json" | J_PATTERNS="$patterns" J_SERIAL="$serial" /usr/bin/python3 -c '
import csv, io, json, os, sys

patterns = [p for p in os.environ.get("J_PATTERNS", "").split("\n") if p]

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

name     = (data.get("general") or {}).get("name") or ""
ul       = data.get("userAndLocation") or {}
username = (ul.get("username") or ul.get("realname") or "").strip()
apps     = data.get("applications") or []
app_names_lower = [str(a.get("name") or "").lower() for a in apps if isinstance(a, dict)]

results = ["Installed" if any(p in n for n in app_names_lower) else "Not Installed" for p in patterns]

# Line 1: console summary. Line 2: finished CSV row.
print("%s (%s, user: %s)" % (" | ".join(results), name, username or "unknown"))
buf = io.StringIO()
csv.writer(buf, lineterminator="").writerow([os.environ.get("J_SERIAL", ""), name, username] + results)
print(buf.getvalue())
' 2>/dev/null)

    if [[ -z "$row" ]]; then
        echo "PARSE ERROR"
        printf '%s,PARSE ERROR,' "$serial" >> "$csv_file"
        for p in "${app_patterns[@]}"; do
            printf ',' >> "$csv_file"
        done
        printf '\n' >> "$csv_file"
        continue
    fi

    printf '%s\n' "${row%%$'\n'*}"
    printf '%s\n' "${row#*$'\n'}" >> "$csv_file"
done

echo ""
echo "Done. CSV written to:"
echo "  $csv_file"
echo ""
