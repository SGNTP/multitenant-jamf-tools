#!/bin/bash

: <<DOC
Script for running various MDM commands

Actions:
- Checks if we already have a token
- Grabs a new token if required using basic auth
- Works out the Jamf Pro version, quits if less than 10.36
- Posts the MDM command request
DOC

# source the get-token.sh file
# shellcheck source-path=SCRIPTDIR source=get-token.sh
source "get-token.sh"


usage() {
    echo "
Usage: jamf-mdm-commands.sh --si JSS_URL --user USERNAME --pass PASSWORD --id ID
Options:
    --redeploy      Redeploy the MDM profile
    --recovery      Set the recovery lock password - supplied with:
                    --recovery-lock-password PASSWORD
    --id            Predefine an ID (from Jamf) to search for
    --serial        Predefine a computer's Serial Number to search for. Can be a csv list.

https:// is optional, it will be added if absent.

SERVERURL, ID, USERNAME, PASSWORD and the option will be asked for if not supplied.
Recovery lock password will be random unless set with --recovery-lock-password.
You can clear the recovery lock password with --clear-recovery-lock-password
"
}

are_you_sure() {
    echo
    read -r -p "Are you sure you want to perform the action? (Y/N) : " sure
    case "$sure" in
        Y|y)
            return
            ;;
        *)
            echo "Action cancelled, quitting"
            exit 
            ;;
    esac
    echo
}

generate_computer_list() {
    # The Jamf Pro API returns a list of all computers.

    jss_url="$chosen_instance"
    endpoint="api/preview/computers"
    url_filter="?page=0&page-size=1000&sort=id"
    curl_url="$jss_url/$endpoint/$url_filter"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # print out a list of ids and names
    results=$( ljt /results < "$curl_output_file" )
    # how big should the loop be?
    loopsize=$( grep -c '"id"' <<< "$results" )

    # now loop through
    i=0
    computer_ids=()
    computer_names=()
    management_ids=()
    serials=()
    computer_choice=()
    echo
    while [[ $i -lt $loopsize ]]; do
        id_in_list=$( ljt /$i/id <<< "$results" )
        computer_name_in_list=$( ljt /$i/name <<< "$results" )
        management_id_in_list=$( ljt /$i/managementId <<< "$results" )
        serial_in_list=$( ljt /$i/serialNumber <<< "$results" )
        computer_ids+=("$id_in_list")
        computer_names+=("$computer_name_in_list")
        management_ids+=("$management_id_in_list")
        serials+=("$serial_in_list")
        if [[ $id && $id_in_list -eq $id ]]; then
            computer_choice+=("$i")
        elif [[ $serial ]]; then
            # allow for CSV list of serials
            if [[ $serial =~ "," ]]; then
                count=$(grep -o "," <<< "$serial" | wc -l)
                serial_count=$(( count + 1 ))
                j=1
                while [[ $j -le $serial_count ]]; do
                    serial_in_csv=$( cut -d, -f$j <<< "$serial" )
                    if [[ "$serial_in_list" == "$serial_in_csv" ]]; then
                        computer_choice+=("$i")
                    fi
                    (( j++ ))
                done
            else
                if [[ "$serial_in_list" == "$serial" ]]; then
                    computer_choice+=("$i")
                fi
            fi
        else
            printf '%-5s %-16s %s\n' "($i)" "$serial_in_list" "$computer_name_in_list"
        fi
        i=$((i+1))
    done

    if [ ${#computer_choice[@]} -eq 0 ]; then
        echo
        read -r -p "Enter the number(s) of the computer(s) above : " computer_input
        # computers chosen
        for computer in $computer_input; do
            computer_choice+=("$computer")
        done
    fi

    if [ ${#computer_choice[@]} -eq 0 ]; then
        echo "No ID or serial supplied"
        exit 1
    fi

    # show list of chosen computers
    echo 
    echo "Computers chosen:"
    for computer in "${computer_choice[@]}"; do
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        computer_serial="${serials[$computer]}"
        printf '%-7s %-16s %s\n' "[id=$computer_id]" "$computer_serial" "$computer_name"
    done
}

redeploy_mdm() {
    # to redeploy the mdm, we need to find out the computer id
    generate_computer_list

    # are we sure?
    are_you_sure

    # now loop through the list and perform the action
    for computer in "${computer_choice[@]}"; do
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        echo
        echo "Processing Computer: id: $computer_id  name: $computer_name"
        echo

        # redeploy MDM profile
        endpoint="api/v1/jamf-management-framework/redeploy"
        curl_url="$jss_url/$endpoint/$computer_id"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request
    done
}

set_recovery_lock() {
    # to set the recovery lock, we need to find out the management id
    generate_computer_list

    # are we sure?
    are_you_sure

    # now loop through the list and perform the action
    for computer in "${computer_choice[@]}"; do
        management_id="${management_ids[$computer]}"
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        echo
        echo "Computer chosen: id: $computer_id  name: $computer_name  management id: $management_id"

        echo
        # get a random password ready
        uuid_string=$(/usr/bin/uuidgen)
        uuid_no_dashes="${uuid_string//-/}"
        random_b64=$(/usr/bin/base64 <<< "$uuid_no_dashes")
        random_alpha_only="${random_b64//[^[:alnum:]]}"
        random_20="${random_alpha_only:0:20}"

        # we need to set the recovery loack password if not already set
        if [[ "$cli_recovery_lock_password" == "RANDOM" ]]; then
            recovery_lock_password="$random_20"
        elif [[ "$cli_recovery_lock_password" == "NA" ]]; then
            recovery_lock_password="NA"
        elif [[ $cli_recovery_lock_password ]]; then
            recovery_lock_password="$cli_recovery_lock_password"
        else
            # random or set a specific password?
            echo "The following applies to all selected devices:"
            read -r -p "Select [R] for random password, [C] to clear the current password, or enter a specific password : " action_question
            case "$action_question" in
                C|c)
                    cli_recovery_lock_password="NA"
                    recovery_lock_password=""
                    ;;
                R|r)
                    cli_recovery_lock_password="RANDOM"
                    recovery_lock_password="$random_20"
                    ;;
                *)
                    cli_recovery_lock_password="$action_question"
                    recovery_lock_password="$action_question"
                    ;;
            esac
            echo
        fi

        if [[ ! $recovery_lock_password || "$recovery_lock_password" == "NA" ]]; then
            echo "Recovery lock will be removed..."
        else
            echo "Recovery password: $recovery_lock_password"
        fi

        # now issue the recovery lock
        endpoint="api/preview/mdm/commands"
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/json")
        curl_args+=("--data-raw")
        curl_args+=(
            '{
                "clientData": [
                    {
                        "managementId": "'"$management_id"'",
                        "clientType": "COMPUTER"
                    }
                ],
                "commandData": {
                    "commandType": "SET_RECOVERY_LOCK",
                    "newPassword": "'"$recovery_lock_password"'"
                }
            }'
        )
        send_curl_request
    done
}


## Main Body
mdm_command=""
recovery_lock_password=""

# read inputs
while test $# -gt 0 ; do
    case "$1" in
        -sl|--server-list)
            shift
            server_list="$1"
        ;;
        -si|--instance)
            shift
            chosen_instance="$1"
        ;;
        -i|--id)
            shift
            id="$1"
            ;;
        -s|--serial)
            shift
            serial="$1"
            ;;
        --redeploy|--redeploy-mdm)
            mdm_command="redeploy"
            ;;
        --recovery|--recovery-lock)
            mdm_command="recovery"
            ;;
        --recovery-lock-password)
            shift
            cli_recovery_lock_password="$1"
            ;;
        --random|--random-lock-password)
            cli_recovery_lock_password="RANDOM"
            ;;
        --clear-recovery-lock-password)
            cli_recovery_lock_password="NA"
            ;;
        *)
            usage
            exit
            ;;
    esac
    shift
done

# Set default server
default_server_list="prd"

# set server list
if [[ ! $server_list ]]; then
    read -r -p "Enter the server type (prd/tst) (or enter for $default_server_list) : " server_list
    echo
fi
if [[ $server_list == *"tst"* ]]; then
    server_list="tst"
elif [[ $server_list == *"prd"* ]]; then
    server_list="prd"
else
    server_list="$default_server_list"
fi

# Set the source server
set_server "$server_list"
# get the instance list and print it out
get_instance_list "$server_list"
# set default template instance
default_template_instance="${instances_list_inc_ios_instances[0]}"

# print out the instance list
echo "Instance list:"
item=0
for instance in "${instances_list_inc_ios_instances[@]}"; do
    printf '   %-7s %-30s\n' "($item)" "$instance"
    ((item++))
done
echo

# Ask which instance we need to process, check if it exists and go from there

if [[ ! $chosen_instance ]]; then
    instance_number=""
    echo
    read -r -p  "Enter the number of the JSS instance : " instance_number
fi

echo "Instance number: $instance_number"  # TEST

# Check for the default or non-context
if [[ $instance_number -gt 0 ]]; then
    chosen_instance="${instances_list_inc_ios_instances[$instance_number]}"
elif  [[ $instance_number -eq 0 ]]; then
    chosen_instance="$default_template_instance"
else
    echo "ERROR: no instance chosen."
    echo
    exit 1
fi

echo
echo "   [main] Chosen instance: $chosen_instance"


if [[ ! $mdm_command ]]; then
    echo
    printf 'Select from [M] Redeploy MDM profile, or [R] Set Recovery Lock : '
    read -r action_question

    case "$action_question" in
        M|m)
            mdm_command="redeploy"
            ;;
        R|r)
            mdm_command="recovery"
            ;;
        *)
            echo
            echo "No valid action chosen!"
            exit 1
            ;;
    esac
fi

echo

set_credentials "${chosen_instance}"

# the following section depends on the chosen MDM command
case "$mdm_command" in
    redeploy)
        echo "   [main] Redeploying MDM profile"
        redeploy_mdm
        ;;
    recovery)
        echo "   [main] Setting recovery lock"
        set_recovery_lock
        ;;
esac

exit 0

