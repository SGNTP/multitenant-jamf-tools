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
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -il|--instance-list) shift; chosen_instance_list_file="$1" ;;
        -i|--instance)       shift; chosen_instance="$1" ;;
        -a|--all-instances)  all_instances=1 ;;
        --id|--client-id)    shift; chosen_id="$1" ;;
        -x|--nointeraction)  no_interaction=1 ;;
        -h|--help)
            echo "Usage: $0 [-il INSTANCE_LIST] [-i INSTANCE_URL] [--sheets SLUGS] [python-args...]"
            echo ""
            echo "MJT instance-picker flags:"
            echo "  -il | --instance-list FILENAME   instance list (without .txt)"
            echo "  -i  | --instance URL             specific instance"
            echo "  -a  | --all-instances            all instances in the list"
            echo "  --id | --client-id CLIENT_ID     use specified client ID"
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

for jss_instance in "${instance_choice_array[@]}"; do
    echo ""
    echo "Running report-jamf-settings on $jss_instance ..."

    if [[ -n "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
    else
        set_credentials "$jss_instance"
    fi

    if ! check_token "$jss_instance"; then
        echo "ERROR: could not obtain token for $jss_instance"
        continue
    fi

    token_file_for_python=$(/usr/bin/mktemp /tmp/jamfcli_token.XXXXXX)
    echo "$token" > "$token_file_for_python"

    /usr/bin/python3 "$python_script" \
        --url "$jss_instance" \
        --token-file "$token_file_for_python" \
        "${forward_args[@]}"

    /bin/rm -f "$token_file_for_python"
done

echo ""
echo "Finished."
echo ""
