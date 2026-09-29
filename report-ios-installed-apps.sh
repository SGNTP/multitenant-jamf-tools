#!/bin/bash

# --------------------------------------------------------------------------------
# Pull a CSV report of iOS devices that have a given app installed, including
# the app's short version and version, using jamf-cli with MJT keychain
# credentials and MJT instance selection (no jamf-cli profiles required).
#
# If no app name is given, the inventory is fetched first and you are presented
# with a numbered list of every app title actually installed in the fleet, so
# you can pick one by number.
#
# Data source: Jamf Pro API GET /v2/mobile-devices/detail
#   (jamf-cli pro mobile-devices list --section ...)
#
# Usage:
#   ./report-ios-installed-apps.sh
#   ./report-ios-installed-apps.sh "Relay Smart Agent"
#   ./report-ios-installed-apps.sh "Relay Smart Agent" -i https://myinstance.jamfcloud.com
#   ./report-ios-installed-apps.sh -ai --list-apps
#
# Output: one CSV per instance in the output folder
# --------------------------------------------------------------------------------

# include iOS-only instances in the picker ("mac" would exclude them)
instance_list_type="ios"

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

DIR=$(/usr/bin/dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

output_dir=""
inventory_cache_dir="${output_location}/ios-inventory"
match_mode="contains"
page_size=100
app_filter=""
app_identifier=""
reuse_json=0
list_apps_only=0

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'

# jamf-cli iOS installed app report

Reports every iOS device that has a named app installed, with the app's
short version and version in separate columns.

Run with no app name to be shown a numbered list of every app title found
in the fleet, and pick one by number.

# Requirements
- jamf-cli installed and in the path (or pass -j /path/to/jamf-cli)
- jq installed
- Keychain credentials set for each instance (./set-credentials.sh)

# Usage
"App Name"                         - app title to search for
                                     (if omitted, pick from a numbered list)
-i  | --instance JSS_URL           - run against a specific instance (repeatable)
-il | --instance-list FILENAME     - instance list filename (without .txt)
-ai | --all-instances              - run against ALL instances in the instance list
--user | --client-id CLIENT_ID     - use the specified client ID or username
-o  | --output-dir PATH            - output folder (prompts /tmp or ~/Desktop if omitted)
--filter STRING                    - skip the search prompt and narrow the numbered
                                     app list with STRING straight away
--bundle BUNDLE_ID                 - report on an exact bundle ID, no prompting
                                     (e.g. --bundle com.relayapp.smartagent)
--list-apps                        - just list the installed app titles and exit
--exact                            - require an exact (case-insensitive) match on an
                                     app name given on the command line
                                     (picking from the list always pins to the
                                     exact title AND bundle ID)
--reuse                            - reuse a previously downloaded inventory JSON
                                     instead of re-fetching (much faster re-runs)
--page-size N                      - API page size (default 100)
-j  | --jamf-cli-path PATH         - alternative path to jamf-cli
-v  | --verbose                    - verbose output
-h  | --help                       - show this help

# Searching
When no app name is given you are asked for a search term first, matched
against both the app title and the bundle ID. Multiple words match in any
order, so "relay agent", "agent relay" and "com.relayapp" all find
"Relay Smart Agent / com.relayapp.smartagent". Press enter to list everything.
From the numbered list you can type more text to re-search at any time.

# Examples
./report-ios-installed-apps.sh
./report-ios-installed-apps.sh --filter relay
./report-ios-installed-apps.sh --bundle com.relayapp.smartagent -ai
./report-ios-installed-apps.sh "Relay Smart Agent" -i https://myinstance.jamfcloud.com

USAGE
}

# --------------------------------------------------------------------------------
# fetch the mobile device inventory for $jss_instance into $inventory_json
# --------------------------------------------------------------------------------
fetch_inventory() {
    inventory_json="${inventory_cache_dir}/inventory-${instance_pretty}.json"

    if [[ $reuse_json -eq 1 && -s "$inventory_json" ]]; then
        echo "   [report] Reusing existing inventory: $inventory_json"
        return 0
    fi

    # credentials come from the Keychain via the common framework
    if ! token_for_instance "$jss_instance"; then
        echo "   [report] ERROR: could not obtain a token for $instance_pretty"
        return 1
    fi

    echo "   [report] Fetching mobile device inventory (this can take a minute)..."
    if ! jc pro mobile-devices list \
        --section GENERAL \
        --section HARDWARE \
        --section USER_AND_LOCATION \
        --section APPLICATIONS \
        --page-size "$page_size" \
        --output json \
        --out-file "$inventory_json" \
        --no-hints; then
        echo "   [report] ERROR: jamf-cli call failed for $instance_pretty"
        remove_jamfcli_token
        return 1
    fi
    remove_jamfcli_token

    if [[ ! -s "$inventory_json" ]]; then
        echo "   [report] ERROR: no JSON returned for $instance_pretty"
        return 1
    fi
}

# --------------------------------------------------------------------------------
# list distinct app titles (with bundle IDs and device counts) from
# $inventory_json into the app_names / app_ids / app_counts arrays.
#
# Narrowed by $app_filter, which is matched against BOTH the app title and the
# bundle ID. The filter is split on spaces and every word must appear somewhere
# in "title bundleid", in any order, so "relay agent" and "agent relay" and
# "com.relayapp" all find "Relay Smart Agent / com.relayapp.smartagent".
# --------------------------------------------------------------------------------
build_app_list() {
    app_names=()
    app_ids=()
    app_counts=()
    app_titles=()

    # NOTE: tab is an IFS whitespace character, so bash collapses runs of tabs
    # and an empty field would be silently swallowed, shifting every field
    # after it. jq therefore emits "-" for a missing bundle ID.
    while IFS=$'\t' read -r count name identifier titles; do
        [[ -z "$name" && -z "$identifier" ]] && continue
        [[ "$identifier" == "-" ]] && identifier=""
        app_counts+=("$count")
        app_names+=("$name")
        app_ids+=("$identifier")
        app_titles+=("$titles")
    done < <("$jq_bin" -r --arg filter "$app_filter" '
        ($filter | ascii_downcase | split(" ") | map(select(length > 0))) as $terms
        | (if type == "object" then (.results // []) else . end)
        | [ .[]
            | (.applications // [])[]
            | { n: (.name // ""), i: (.identifier // "") }
            | select(.n != "" or .i != "")
            # The bundle ID is the stable identity: a vendor can rename the app
            # without changing it, so the same app can report different titles
            # on different devices. Group on the bundle ID, treat the title as
            # a label. Some devices report no identifier at all and put the
            # bundle ID in the name instead, so fall back to that.
            | .k = ( if .i != "" then .i
                     elif (.n | test("^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)+$")) then .n
                     else "name:" + .n end ) ]
        | group_by(.k)
        | map( . as $g
               | ($g[0].k) as $key
               | ( [ $g[] | .n | select(. != "" and . != $key) ] ) as $real
               | { id: (if ($key | startswith("name:")) then "" else $key end),
                   # display the most commonly reported real title
                   name: ( if ($real | length) > 0
                           then ($real | group_by(.) | max_by(length) | .[0])
                           else ($key | sub("^name:"; "")) end ),
                   titles: ($real | unique | length),
                   count: ($g | length) } )
        | map( ((.name + " " + .id) | ascii_downcase) as $hay
               | select( ($terms | length) == 0
                         or all($terms[]; . as $t | $hay | contains($t)) ) )
        | sort_by(.name | ascii_downcase)
        | .[]
        | "\(.count)\t\(.name)\t\(if .id == "" then "-" else .id end)\t\(.titles)"
    ' "$inventory_json")
}

# --------------------------------------------------------------------------------
# show the numbered list and let the user pick an app, or type a search term
# to narrow it. Sets $app_name (and forces exact matching).
# --------------------------------------------------------------------------------
choose_app() {
    local selection

    # offer a search before dumping the whole list, which can run to hundreds
    # of titles on a real fleet
    if [[ -z "$app_filter" ]]; then
        echo
        echo "Search for an app by title or bundle ID.  Partial words are fine."
        echo "Press Enter to list every app instead."
        if ! read -r -p "   Search : " app_filter; then
            echo
            echo "   No input available. Exiting."
            exit 1
        fi
    fi

    while true; do
        build_app_list

        if [[ ${#app_names[@]} -eq 0 ]]; then
            if [[ -n "$app_filter" ]]; then
                echo
                echo "   No app titles matching '$app_filter'. Showing all apps."
                app_filter=""
                continue
            fi
            echo "   [report] ERROR: no apps found in the inventory for $instance_pretty."
            echo "   Does this instance have iOS devices with app inventory collected?"
            return 1
        fi

        echo
        if [[ -n "$app_filter" ]]; then
            echo "Installed app titles matching '$app_filter' (${#app_names[@]}):"
        else
            echo "Installed app titles (${#app_names[@]}):"
        fi
        echo

        local i
        for i in "${!app_names[@]}"; do
            printf '   [%d] %s (%s devices)\n' "$i" "${app_names[$i]}" "${app_counts[$i]}"
            if [[ -n "${app_ids[$i]}" ]]; then
                printf '       %s\n' "${app_ids[$i]}"
            else
                printf '       (no bundle ID reported)\n'
            fi
            if [[ "${app_titles[$i]}" -gt 1 ]]; then
                printf '       (also reported under %d other title(s))\n' \
                    "$(( ${app_titles[$i]} - 1 ))"
            fi
        done

        echo
        if [[ ${#app_names[@]} -gt 40 ]]; then
            echo "   That is a long list. Type part of a title or bundle ID to narrow it."
        fi
        if ! read -r -p "Enter the number of the app, or text to search, or 'q' to quit : " selection; then
            echo
            echo "   No input available. Exiting."
            exit 1
        fi
        echo

        if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
            echo "Nothing chosen. Exiting."
            exit 0
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            if [[ $selection -ge 0 && $selection -lt ${#app_names[@]} ]]; then
                app_name="${app_names[$selection]}"
                app_identifier="${app_ids[$selection]}"
                if [[ -n "$app_identifier" ]]; then
                    # match on bundle ID, so devices reporting a different
                    # title for the same app are still included
                    match_mode="bundle"
                    echo "   Selected: $app_name ($app_identifier)"
                else
                    match_mode="exact"
                    echo "   Selected: $app_name (no bundle ID)"
                fi
                return 0
            fi
            echo "   '$selection' is not in range 0-$(( ${#app_names[@]} - 1 )). Try again."
            continue
        fi

        if [[ -z "$selection" ]]; then
            echo "   Nothing entered. Enter a number, or text to search."
            continue
        fi

        # treat anything else as a new search term
        app_filter="$selection"
    done
}

# --------------------------------------------------------------------------------
# write the CSV of devices with $app_name installed
# --------------------------------------------------------------------------------
write_csv() {
    # name the file after the app title, falling back to the bundle ID
    local app_name_safe
    app_name_safe=$(echo "${app_name:-$app_identifier}" \
        | /usr/bin/tr ' ' '-' | /usr/bin/tr -cd '[:alnum:]-_.')
    [[ -z "$app_name_safe" ]] && app_name_safe="app-report"
    local output_csv="${output_dir}/${app_name_safe}-${instance_pretty}.csv"

    if [[ -n "$app_identifier" ]]; then
        echo "   [report] App: $app_name ($app_identifier)  (match: $match_mode)"
    else
        echo "   [report] App: $app_name  (match: $match_mode)"
    fi

    # jq 1.6+ has strflocaltime for local-time output; fall back to UTC without it
    local date_fn="strflocaltime"
    if ! echo 'null' | "$jq_bin" -e '0 | strflocaltime("%Y")' >/dev/null 2>&1; then
        date_fn="strftime"
        echo "   [report] NOTE: this jq has no strflocaltime, so times stay in UTC."
    fi

    "$jq_bin" -r --arg app "$app_name" --arg bundle "$app_identifier" --arg mode "$match_mode" '
        # Jamf returns ISO 8601 UTC ("2026-08-11T08:16:25.445Z"). Strip the
        # fractional seconds and the zone, then read it as UTC epoch seconds.
        # Returns null for missing or unparseable values so the CSV cell is blank.
        def to_epoch:
            ( . // "" )
            | if . == "" then null
              else ( sub("\\.[0-9]+"; "")
                     | sub("(Z|[+-][0-9][0-9]:?[0-9][0-9])$"; "") )
                   | ( try ( strptime("%Y-%m-%dT%H:%M:%S") | mktime ) catch null )
              end;

        (if type == "object" then (.results // []) else . end) as $devices
        | ["Device Name","Serial Number","Username","Model","OS Version",
           "Last Inventory Update","Days Since Inventory",
           "App Name","Short Version","Version","Bundle ID","Device ID"],
          ( $devices[] as $d
            | ($d.applications // [])[]
            | select(
                ((.name // "") | ascii_downcase) as $n
                | ((.identifier // "") | ascii_downcase) as $b
                | ($app | ascii_downcase) as $q
                | ($bundle | ascii_downcase) as $qb
                # bundle mode also catches devices that reported no identifier
                # and put the bundle ID in the name field instead
                | if $mode == "bundle" then ($b == $qb or ($b == "" and $n == $qb))
                  elif $mode == "exact" then $n == $q
                  else ($n | contains($q)) end
              )
            | ($d.general.lastInventoryUpdateDate | to_epoch) as $inv
            | [ ($d.general.displayName // ""),
                ($d.hardware.serialNumber // ""),
                ($d.userAndLocation.username // ""),
                ($d.hardware.model // ""),
                ($d.general.osVersion // ""),
                (if $inv == null then "" else ($inv | '"$date_fn"'("%Y-%m-%d %H:%M")) end),
                (if $inv == null then "" else (((now - $inv) / 86400) | floor) end),
                (.name // ""),
                (.shortVersion // ""),
                (.version // ""),
                (.identifier // ""),
                ($d.mobileDeviceId // "") ]
          )
        | @csv
    ' "$inventory_json" > "$output_csv"

    local device_total match_count
    device_total=$("$jq_bin" -r '(if type == "object" then (.results // []) else . end) | length' "$inventory_json")
    match_count=$(( $(/usr/bin/wc -l < "$output_csv") - 1 ))

    echo "   [report] Scanned $device_total device(s); $match_count match(es)."

    if [[ $verbose -gt 0 ]]; then
        echo
        /usr/bin/head -20 "$output_csv"
        echo
    fi

    echo "   [report] CSV: $output_csv"
}

do_the_report() {
    instance_pretty=$(echo "$jss_instance" | /usr/bin/sed -e 's|^https*://||' -e 's|/.*$||')

    echo
    echo "   [report] Instance: $instance_pretty"

    fetch_inventory || return 1

    # --list-apps just prints the titles and stops, no prompting
    if [[ $list_apps_only -eq 1 ]]; then
        build_app_list
        echo
        echo "Installed app titles on $instance_pretty (${#app_names[@]}):"
        echo
        local i
        for i in "${!app_names[@]}"; do
            printf '   [%d] %s (%s devices)\n' "$i" "${app_names[$i]}" "${app_counts[$i]}"
        done
        echo
        return 0
    fi

    # if we still have nothing to search for, offer the numbered list
    if [[ -z "$app_name" && "$match_mode" != "bundle" ]]; then
        choose_app || return 1
    fi

    write_csv
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

while [[ "$#" -gt 0 ]]; do
    case "$1" in
    -il | --instance-list)
        shift
        chosen_instance_list_file="$1"
        ;;
    -i | --instance)
        shift
        chosen_instances+=("$1")
        ;;
    -ai | -a | --all | --all-instances)
        all_instances=1
        ;;
    --id | --client-id | --user | --username)
        shift
        chosen_id="$1"
        ;;
    -o | --output-dir | --output)
        shift
        output_dir="$1"
        ;;
    --filter)
        shift
        app_filter="$1"
        ;;
    --bundle | --bundle-id)
        shift
        app_identifier="$1"
        match_mode="bundle"
        ;;
    --list-apps)
        list_apps_only=1
        ;;
    --exact)
        match_mode="exact"
        ;;
    --reuse)
        reuse_json=1
        ;;
    --page-size)
        shift
        page_size="$1"
        ;;
    -j | --jamf-cli | --jamf-cli-path)
        shift
        jamf_cli_path="$1"
        ;;
    -x | --nointeraction)
        no_interaction=1
        ;;
    -v | --verbose)
        verbose=1
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        app_name="$1"
        ;;
    esac
    shift
done
echo

ensure_dependencies jamf-cli jq || exit 1

# --list-apps never needs an app name
if [[ $list_apps_only -eq 1 ]]; then
    app_name=""
fi

/bin/mkdir -p "$inventory_cache_dir"
if [[ $list_apps_only -eq 0 ]]; then
    choose_output_dir || exit 1
fi
trap remove_jamfcli_token EXIT

# MJT instance selection (prompts unless -i / -ai given)
choose_destination_instances

for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    do_the_report
done

echo
echo "Finished."
echo
