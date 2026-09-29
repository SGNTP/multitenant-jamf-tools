#!/bin/bash

# --------------------------------------------------------------------------------
# MJT wrapper for report-jamf-settings.py
# Handles instance selection and Keychain auth, then invokes the Python script
# with --url and --token-file so it bypasses jamf-cli's profile picker.
# --------------------------------------------------------------------------------

instance_list_type="mac"

# --------------------------------------------------------------------------------
# ENVIRONMENT
# --------------------------------------------------------------------------------

DIR=$(/usr/bin/dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

python_script="$DIR/report-jamf-settings.py"
if [[ ! -f "$python_script" ]]; then
    echo "ERROR: report-jamf-settings.py not found alongside this script."
    exit 1
fi

# --------------------------------------------------------------------------------
# ARGS
# --------------------------------------------------------------------------------

forward_args=()
output_dir=""
ask_output_dir=1
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -il|--instance-list) shift; chosen_instance_list_file="$1" ;;
        -i|--instance)       shift; chosen_instance="$1" ;;
        -a|--all-instances)  all_instances=1 ;;
        --id|--client-id)    shift; chosen_id="$1" ;;
        -x|--nointeraction)  no_interaction=1 ;;
        -o|--output-dir)     shift; output_dir="$1" ;;
        --output-prefix)     ask_output_dir=0; forward_args+=("$1" "$2"); shift ;;
        --format)
            [[ "$2" == "terminal" ]] && ask_output_dir=0
            forward_args+=("$1" "$2"); shift
            ;;
        -h|--help)
            echo "Usage: $0 [-il INSTANCE_LIST] [-i INSTANCE_URL] [--sheets SLUGS] [python-args...]"
            echo ""
            echo "MJT instance-picker flags:"
            echo "  -il | --instance-list FILENAME   instance list (without .txt)"
            echo "  -i  | --instance URL             specific instance"
            echo "  -a  | --all-instances            all instances in the list"
            echo "  --id | --client-id CLIENT_ID     use specified client ID"
            echo "  -o  | --output-dir DIR           output folder (prompts /tmp or ~/Desktop if omitted)"
            echo ""
            echo "All other flags are forwarded to report-jamf-settings.py."
            echo "Run: python3 report-jamf-settings.py --help  for the full list."
            exit 0
            ;;
        *) forward_args+=("$1") ;;
    esac
    shift
done

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

choose_destination_instances

# ask once for the output folder; the Python script is run once per instance
output_args=()
if [[ $ask_output_dir -eq 1 ]]; then
    choose_output_dir || exit 1
    output_args=(--output-dir "$output_dir")
fi

trap remove_jamfcli_token EXIT

for jss_instance in "${instance_choice_array[@]}"; do
    echo ""
    echo "Running report-jamf-settings on $jss_instance ..."

    if ! token_for_instance "$jss_instance"; then
        echo "ERROR: could not obtain token for $jss_instance"
        continue
    fi

    /usr/bin/python3 "$python_script" \
        --url "$jss_instance" \
        --token-file "$token_file_for_jamfcli" \
        "${output_args[@]}" \
        "${forward_args[@]}"

    remove_jamfcli_token
done

echo ""
echo "Finished."
echo ""
