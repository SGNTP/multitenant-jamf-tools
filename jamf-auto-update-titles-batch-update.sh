#!/bin/bash

# -------------------------------------------------------------------------------
# Finds all Jamf Auto Update titles deployed in a Jamf Pro instance by examining
# policies whose names contain "Auto-Update" or "Jamf Auto Update", extracting
# the unique parameter4 values from their attached scripts, then optionally runs
# the AutoPkg profile update recipe for each title found.
# 
# NOTICE:
# The part of this script that updates profiles requires the Toolkit for MSP to be installed, as it relies on recipes and data included in the Toolkit recipe repo to function. If you want to use the profile update functionality, please ensure you have the Toolkit installed and configured properly.
# -------------------------------------------------------------------------------

# set the maximum number of curl requests to try until success
max_tries_override=2

# set instance list type
instance_list_type="mac"

# define autopkg prefs
autopkg_prefs="${HOME}/Library/Preferences/com.github.autopkg.plist"

# default temp directory for downloaded objects
output_dir="/tmp/mjt/auto-update-titles"

# default profile update recipe path (override with --recipe)
profiles_recipe="msp-toolkit-recipes.jamf.Policies-AU-ProfilesOnly"

# default titles cache path (override with --titles-cache)
titles_cache="$HOME/Library/AutoPkg/RecipeRepos/com.github.jamf.msp-toolkit-autopkg-recipes/JamfAutoUpdateTitles/jamf_auto_update_titles_cache.json"

# -------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# -------------------------------------------------------------------------------

DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# -------------------------------------------------------------------------------
# FUNCTIONS
# -------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
  ./get-jamf-auto-update-titles.sh [options]

Finds all Jamf Auto Update titles deployed in a Jamf Pro instance by examining
policies whose names contain "Auto-Update" or "Jamf Auto Update", extracting
the unique parameter4 values from their attached scripts, then optionally runs
an AutoPkg profile update recipe for each title found.

Options:
  -il | --instance-list FILENAME     Instance list filename (without .txt)
  -i  | --instance JSS_URL           Single Jamf Pro instance URL
  -a  | --all-instances              Run on all instances in the list
  -x  | --nointeraction              Skip interactive instance selection
  --user | --client-id CLIENT_ID     Use specified username or Client ID
  --recipe PATH                      Path to profile update recipe
                                     (default: Policies-AU-ProfilesOnly.jamf.recipe.yaml)
  --titles-cache PATH                Path to jamf_auto_update_titles_cache.json
  --output-dir PATH                  Temp directory for downloaded policy files
                                     (default: /tmp/mjt/auto-update-titles)
  --skip-download                    Skip downloading; use files already in --output-dir
  -v[vvv]                            Verbose AutoPkg output
  -h | --help                        Show this help
USAGE
}

get_instance_shortname() {
    local url="$1"
    local tmp="${url#*://}"  # strip protocol
    tmp="${tmp%%/*}"          # strip path
    tmp="${tmp%%:*}"          # strip port
    echo "${tmp%%.*}"         # first domain component only
}

download_policy_list() {
    local out_dir="$1"
    echo "   [download_policy_list] Fetching policy list from $jss_instance..."
    if ! "$this_script_dir/autopkg-run.sh" -r "${this_script_dir}/recipes/DownloadObjectList.jamf.recipe.yaml" \
        --instance "$jss_instance" \
        --nointeraction \
        --key "OBJECT_TYPE=policies" \
        --key "OUTPUT_DIR=$out_dir" \
        "$verbosity_mode"; then
        echo "ERROR: AutoPkg run failed for $jss_instance"
        return 1
    fi
}

download_policy_xml() {
    local policy_name="$1"
    local out_dir="$2"
    echo "   [download_policy_xml] Downloading: $policy_name"
    if ! "$this_script_dir/autopkg-run.sh" -r "${this_script_dir}/recipes/DownloadObject.jamf.recipe.yaml" \
        --instance "$jss_instance" \
        --nointeraction \
        --key "OBJECT_TYPE=policies" \
        --key "OBJECT_NAME=$policy_name" \
        --key "OUTPUT_DIR=$out_dir" \
        "$verbosity_mode"; then
        echo "WARNING: Failed to download policy '$policy_name' — skipping."
        return 1
    fi
}

# Parse a list file (XML or plain text) to stdout, one policy name per line
get_policy_names_from_file() {
    local list_file="$1"
    local extension="${list_file##*.}"

    if [[ "$extension" == "xml" ]]; then
        sed -n 's|.*<name>\([^<]*\)</name>.*|\1|p' "$list_file"
    elif [[ "$extension" == "json" ]]; then
        jq -r '.[].name' "$list_file"
    else
        cat "$list_file"
    fi
}

run_profile_update() {
    local title="$1"
    local run_args=(-i "$jss_instance" -x)
    [[ -n "$verbosity_mode" ]] && run_args+=("$verbosity_mode")
    run_args+=(
        -r "$profiles_recipe"
        --key "NAME=$title"
        --key "AUTOUPDATE_LABEL=$title"
        --key "LOCAL_TITLES_CACHE=$titles_cache"
        --key "REPLACE_PROFILE=True"
    )

    echo
    echo "   [run_profile_update] Updating profile for: $title"
    "${this_script_dir}/autopkg-run.sh" "${run_args[@]}"
}

# -------------------------------------------------------------------------------
# ARGUMENT PARSING
# -------------------------------------------------------------------------------

chosen_instances=()

while [[ "$#" -gt 0 ]]; do
    case "$1" in
    -il | --instance-list)
        shift; chosen_instance_list_file="$1" ;;
    -i | --instance)
        shift; chosen_instances+=("$1") ;;
    -a | -ai | --all | --all-instances)
        all_instances=1 ;;
    --id | --client-id | --user | --username)
        shift; chosen_id="$1" ;;
    -x | --nointeraction)
        no_interaction=1 ;;
    --recipe)
        shift; profiles_recipe="$1" ;;
    --titles-cache)
        shift; titles_cache="$1" ;;
    --output-dir)
        shift; output_dir="$1" ;;
    --skip-download)
        skip_download=1 ;;
    -v*)
        verbosity_mode="$1" ;;
    -h | --help)
        usage; exit 0 ;;
    *)
        echo "ERROR: Unknown argument: $1"
        usage; exit 1 ;;
    esac
    shift
done

if [[ ! $verbosity_mode ]]; then
    verbosity_mode="-v"
fi

# -------------------------------------------------------------------------------
# MAIN
# -------------------------------------------------------------------------------

echo
echo "This script will find Jamf Auto Update titles deployed on the selected instance(s)."
echo

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

choose_destination_instances

returncode=0

for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"

    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [main] Using provided Client ID for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [main] Using stored credentials for $jss_instance ($jss_api_user)"
    fi

    echo
    echo "============================================"
    echo "Processing: $jss_instance"
    echo "============================================"

    shortname=$(get_instance_shortname "$jss_instance")
    instance_output_dir="${output_dir}/${shortname}"

    if [[ $skip_download -eq 1 ]]; then
        echo "   [main] --skip-download set; using existing files in $instance_output_dir"
        mkdir -p "$instance_output_dir"
    else
        rm -rf "$instance_output_dir"
        mkdir -p "$instance_output_dir"

        # Step 1: Download the full policy list
        if ! download_policy_list "$instance_output_dir"; then
            echo "ERROR: Skipping $jss_instance — policy list download failed."
            returncode=1
            continue
        fi
    fi

    # Step 2: Locate the list file produced by DownloadObjectList.
    # JamfObjectReader names list-only output as "policies-list.(xml|json)".
    list_file=$(find "$instance_output_dir" -maxdepth 1 -name "policies-list.*" -print 2>/dev/null | head -1)

    # Fallback: pick the smallest XML/JSON file (the list is much smaller than individual policies)
    if [[ -z "$list_file" ]]; then
        list_file=$(find "$instance_output_dir" -maxdepth 1 \( -name "*.json" -o -name "*.xml" \) -print 2>/dev/null \
            | xargs ls -S 2>/dev/null | tail -1)
    fi

    if [[ -z "$list_file" ]]; then
        echo "ERROR: No list file found in $instance_output_dir. Skipping."
        returncode=1
        continue
    fi

    echo "   Policy list: $list_file"

    # Step 3: Filter for Auto-Update policies
    matching_policies=()
    while IFS= read -r policy_name; do
        [[ -z "$policy_name" ]] && continue
        if echo "$policy_name" | grep -iE "(Auto-Update - |Jamf Auto Update - )" | grep -v "Uninstall" > /dev/null 2>&1; then
            matching_policies+=("$policy_name")
        fi
    done < <(get_policy_names_from_file "$list_file")

    if [[ ${#matching_policies[@]} -eq 0 ]]; then
        echo "No Auto-Update policies found on $jss_instance."
        continue
    fi

    echo
    echo "Found ${#matching_policies[@]} matching policy/policies:"
    for p in "${matching_policies[@]}"; do
        echo "  - $p"
    done
    echo

    # Step 4: Download XML for each matching policy (unless --skip-download)
    if [[ $skip_download -eq 1 ]]; then
        echo "Skipping download — using files already in $instance_output_dir"
    else
        echo "Downloading policy XML..."
        for policy_name in "${matching_policies[@]}"; do
            download_policy_xml "$policy_name" "$instance_output_dir"
        done
    fi

    # Step 5: Extract unique parameter4 values from all downloaded XML files,
    # excluding the list file. Use a temp file to deduplicate (Bash 3 compatible).
    au_titles_raw=$(
        find "$instance_output_dir" -maxdepth 1 -name "*.xml" -print0 2>/dev/null \
        | while IFS= read -r -d '' xml_file; do
            [[ "$xml_file" == "$list_file" ]] && continue
            sed -n 's|.*<parameter4>\([^<]*\)</parameter4>.*|\1|p' "$xml_file" 2>/dev/null
        done \
        | sort -u
    )

    au_titles=()
    while IFS= read -r param4; do
        [[ -z "$param4" ]] && continue
        au_titles+=("$param4")
    done <<< "$au_titles_raw"

    if [[ ${#au_titles[@]} -eq 0 ]]; then
        echo "No Jamf Auto Update titles found in parameter4 of matching policies."
        continue
    fi

    # (au_titles is already sorted by sort -u above)

    echo
    echo "Found ${#au_titles[@]} unique Jamf Auto Update title(s) on $jss_instance:"
    for title in "${au_titles[@]}"; do
        echo "  - $title"
    done
    echo

    # Step 6: Print numbered list and ask which titles to update
    echo "Titles found:"
    echo
    for ((i = 0; i < ${#au_titles[@]}; i++)); do
        printf '   %-7s %s\n' "($i)" "${au_titles[$i]}"
    done
    echo
    read -r -p "Enter title number(s) to update profiles for, 'ALL' to select all, or blank to skip : " title_choice_list

    if [[ -z "$title_choice_list" ]]; then
        echo
        echo "   [main] Skipped."
        continue
    fi

    # expand ALL
    if [[ "$title_choice_list" == "ALL" ]]; then
        title_choice_list=""
        for ((i = 0; i < ${#au_titles[@]}; i++)); do
            title_choice_list="$title_choice_list $i"
        done
    fi

    # expand ranges (e.g. "0-5 11 13") into an index array
    title_choice_array=()
    for sel in $title_choice_list; do
        if [[ "$sel" == *"-"* ]]; then
            list_first=$(echo "$sel" | cut -d'-' -f1)
            list_last=$(echo "$sel" | cut -d'-' -f2)
            for ((i = list_first; i <= list_last; i++)); do
                title_choice_array+=("$i")
            done
        else
            title_choice_array+=("$sel")
        fi
    done

    echo
    echo "   [main] Titles chosen:"
    for idx in "${title_choice_array[@]}"; do
        echo "   '${au_titles[$idx]}'"
    done
    echo

    # Step 7: Run profile update recipe for each chosen title
    for idx in "${title_choice_array[@]}"; do
        run_profile_update "${au_titles[$idx]}"
    done

done

echo
echo "Done."
echo
exit $returncode
