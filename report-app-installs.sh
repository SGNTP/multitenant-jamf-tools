#!/bin/bash

# Report which version (if any) of specific apps is installed on target macOS
# computers or iOS / iPadOS devices. Platform, apps and targets are chosen at
# runtime — no hardcoded lists.
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
# Apps:
#   --app PATTERN            Substring of app name or bundle ID (may be repeated)
#                            (interactive prompt if omitted)
#
# Usage:
#   ./report-app-installs.sh [-il LIST] [-i URL] [--macos|--ios] \
#       --app "musescore" --app "sibelius" --app "logic pro" \
#       --group "NOR Music Labs"

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
        --macos|--mac|--ios|--ipados|--mobile) parse_platform_arg "$1" ;;
        --serial|--name|--name-match|--group)
            parse_target_arg "$@" || exit 1
            shift "$target_args_used"
            continue
            ;;
        -h|--help)
            echo "Usage: $0 [MJT flags] [--macos|--ios] --app PATTERN [--app PATTERN ...] [target flags]"
            echo ""
            print_platform_usage
            echo ""
            print_target_usage
            echo ""
            echo "Apps:"
            echo "  --app PATTERN            Substring of app name or bundle ID (repeat for multiple apps)"
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

# Prompt for apps if none supplied
if [[ ${#app_patterns[@]} -eq 0 ]]; then
    echo "Enter apps to check: part of the app name or bundle ID, case-insensitive"
    echo "(one per line, blank line to finish), e.g. \"sibelius\" or \"com.avid.sibelius\":"
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
csv_file="${output_dir}/report-app-installs_$(platform_slug)_${instance_short}_${timestamp}.csv"

# Rows are collected first and the header written last, because the app
# column headers come from the app names actually matched on the devices.
name_col="Computer Name"; seen_col="Last Check-in"
if is_mobile_platform; then
    name_col="Device Name"; seen_col="Last Inventory Update"
fi
rows_file=$(/usr/bin/mktemp /tmp/mjt_app_installs_rows.XXXXXX)
names_file=$(/usr/bin/mktemp /tmp/mjt_app_installs_names.XXXXXX)
trap 'remove_jamfcli_token; /bin/rm -f "$rows_file" "$names_file"' EXIT

# blank_row SERIAL STATUS: a row with no inventory data
blank_row() {
    local p
    printf '%s,%s,,' "$1" "$2"
    for p in "${app_patterns[@]}"; do
        printf ','
    done
    printf '\n'
}

# -------------------------------------------------------------------------
# FETCH AND PARSE
# -------------------------------------------------------------------------

echo ""
echo "Querying ${#resolved_serials[@]} $(device_noun)(s) on $jss_instance..."
echo ""

patterns=$(printf '%s\n' "${app_patterns[@]}")

for serial in "${resolved_serials[@]}"; do
    printf "  %-14s ... " "$serial"

    raw_json=$(fetch_device_by_serial "$serial" GENERAL APPLICATIONS USER_AND_LOCATION)

    if [[ -z "$raw_json" ]]; then
        echo "NOT FOUND in Jamf"
        blank_row "$serial" "NOT FOUND" >> "$rows_file"
        continue
    fi

    inv_json=$(printf '%s' "$raw_json" | normalise_device_json)
    row=$(printf '%s' "$inv_json" | J_PATTERNS="$patterns" J_SERIAL="$serial" /usr/bin/python3 -c '
import csv, io, json, os, sys

patterns = [p for p in os.environ.get("J_PATTERNS", "").split("\n") if p]

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

# normalise_device_json shape: name, username, last_seen_display,
# apps[{name, id, version}]
name     = data.get("name") or ""
username = data.get("username") or ""
last     = data.get("last_seen_display") or "Never"
apps     = data.get("apps") or []

def display_name(n):
    return n[:-4] if n.lower().endswith(".app") else n

cells, matched_names, summary = [], [], []
for p in patterns:
    versions, names = [], []
    for a in apps:
        if p in a.get("name", "").lower() or p in a.get("id", "").lower():
            v = a.get("version", "")
            if v and v not in versions:
                versions.append(v)
            n = display_name(a.get("name", "")) or a.get("id", "")
            if n and n not in names:
                names.append(n)
    if names:
        cell = " / ".join(versions) or "Installed"
    else:
        cell = "Not Installed"
    cells.append(cell)
    matched_names.append(names)
    summary.append("%s: %s" % (" / ".join(names) or p, cell))

# Line 1: console summary. Line 2: CSV row. Line 3: matched app names per pattern.
print("%s (%s, user: %s, last seen %s)" % (" | ".join(summary), name, username or "unknown", last))
buf = io.StringIO()
csv.writer(buf, lineterminator="").writerow([os.environ.get("J_SERIAL", ""), name, username, last] + cells)
print(buf.getvalue())
print(json.dumps(matched_names))
' 2>/dev/null)

    if [[ -z "$row" ]]; then
        echo "PARSE ERROR"
        blank_row "$serial" "PARSE ERROR" >> "$rows_file"
        continue
    fi

    printf '%s\n' "${row%%$'\n'*}"
    row="${row#*$'\n'}"
    printf '%s\n' "${row%%$'\n'*}" >> "$rows_file"
    printf '%s\n' "${row#*$'\n'}" >> "$names_file"
done

# Header: each app column is named after the app(s) it matched (without
# ".app"), falling back to the typed pattern when nothing matched.
J_PATTERNS="$patterns" /usr/bin/python3 - "$names_file" "$name_col" "$seen_col" > "$csv_file" <<'PY'
import csv, json, os, sys

names_file, name_col, seen_col = sys.argv[1:4]
patterns = [p for p in os.environ.get("J_PATTERNS", "").split("\n") if p]
seen = [[] for _ in patterns]
with open(names_file) as fh:
    for line in fh:
        try:
            per_pattern = json.loads(line)
        except Exception:
            continue
        for i, names in enumerate(per_pattern[:len(patterns)]):
            for n in names:
                if n not in seen[i]:
                    seen[i].append(n)
headers = [" / ".join(s) if s else p for s, p in zip(seen, patterns)]
csv.writer(sys.stdout, lineterminator="\n").writerow(
    ["Serial", name_col, "Username", seen_col] + headers)
PY
/bin/cat "$rows_file" >> "$csv_file"

echo ""
echo "Done. CSV written to:"
echo "  $csv_file"
echo ""
