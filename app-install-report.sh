#!/bin/bash

# Report whether specific apps are installed on target computers.
# Uses mjt instance picker for auth. Outputs CSV to /tmp.
#
# Usage: ./app-install-report.sh [-il INSTANCE_LIST] [-i INSTANCE_URL]

# -------------------------------------------------------------------------
# CONFIGURATION
# -------------------------------------------------------------------------

target_computers=(
    "NOR-WZ-L30B"
    "NOR-WZ-L30J"
    "NOR-WZ-L30K"
    "NOR-WZ-L30L"
    "NOR-WZ-L30M"
    "NOR-WZ-L30N"
    "NOR-WZ-L30O"
    "NOR-WZ-L30A"
    "NOR-WZ-L30C"
    "NOR-WZ-L30D"
    "NOR-WZ-L30E"
    "G3WLVL9WJT"
    "NOR-WZ-L30G"
    "NOR-WZ-L30H"
    "NOR-WZ-L30I"
)

# Parallel arrays: display label and lowercase search pattern
app_labels=("MuseScore" "Sibelius" "Logic Pro")
app_patterns=("musescore" "sibelius" "logic pro")

# -------------------------------------------------------------------------
# ENVIRONMENT
# -------------------------------------------------------------------------

DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

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
        -h|--help)
            echo "Usage: $0 [-il INSTANCE_LIST] [-i INSTANCE_URL]"
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

# Prepare output CSV
timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
instance_short=$(echo "$jss_instance" | /usr/bin/sed 's|https\?://||; s|/.*||')
csv_file="/tmp/app-install-report_${instance_short}_${timestamp}.csv"

# Write header
{
    printf 'Computer Name'
    for label in "${app_labels[@]}"; do
        printf ',%s' "$label"
    done
    printf '\n'
} > "$csv_file"

echo
echo "Querying ${#target_computers[@]} computers on $jss_instance ..."
echo

for computer_name in "${target_computers[@]}"; do
    printf "  %-22s ... " "$computer_name"

    apps_json=$(jamf-cli pro computer-inventory get \
        --name "$computer_name" \
        --section APPLICATIONS \
        --url "$jss_instance" \
        --token-file "$token_file" \
        -o json --no-hints --no-update-check --quiet 2>/dev/null)

    if [[ -z "$apps_json" ]]; then
        echo "NOT FOUND in Jamf"
        printf '%s' "$computer_name" >> "$csv_file"
        for label in "${app_labels[@]}"; do
            printf ',NOT FOUND' >> "$csv_file"
        done
        printf '\n' >> "$csv_file"
        continue
    fi

    row_status=()
    for i in "${!app_patterns[@]}"; do
        pattern="${app_patterns[$i]}"
        if /usr/local/autopkg/python -c "
import sys, json
data = json.load(sys.stdin)
apps = data.get('applications', [])
found = any('${pattern}' in a.get('name', '').lower() for a in apps)
sys.exit(0 if found else 1)
" <<< "$apps_json" 2>/dev/null; then
            row_status+=("Installed")
        else
            row_status+=("Not Installed")
        fi
    done

    summary=""
    for s in "${row_status[@]}"; do
        [[ -n "$summary" ]] && summary+=" | "
        summary+="$s"
    done
    echo "$summary"

    printf '%s' "$computer_name" >> "$csv_file"
    for s in "${row_status[@]}"; do
        printf ',%s' "$s" >> "$csv_file"
    done
    printf '\n' >> "$csv_file"
done

/bin/rm -f "$token_file"

echo
echo "Done. CSV written to:"
echo "  $csv_file"
echo
