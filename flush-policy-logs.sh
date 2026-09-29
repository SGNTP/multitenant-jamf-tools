#!/bin/bash

# --------------------------------------------------------------------------------
# Flush the execution logs of one or more Jamf Pro policies, across one or more
# Jamf Pro instances.
#
# Two modes:
#   report (default) - read-only. Lists the policies that match the chosen scope on
#                      each instance, with a clickable URL, so you can preview what a
#                      flush would target. Writes nothing.
#   flush (--flush)  - flushes the execution logs for the matched policies via the
#                      Classic API logflush endpoint:
#                        DELETE /JSSResource/logflush/policy/id/{id}/interval/{interval}
#                      "Zero Days" flushes every log for the policy; the other intervals
#                      flush only logs older than that period.
#
# Policies are picked with jamf-cli (pro classic-policies list) using a short-lived
# per-instance token, the same pattern set-prestage-os-version.sh uses. The flush call
# itself is a Classic API DELETE made with that same token.
#
# Output (in /tmp or ~/Desktop - chosen at run time, or -o DIR):
#   report : policy-logflush-report.xlsx (URLs hyperlinked) / .csv fallback
#   flush  : policy-logflush-result.xlsx / .csv fallback
#
# PRIVILEGES
#   The API role needs Flush Policy Logs, plus Read on Policies (and Read on Categories
#   when using --category) for the pickers.
# --------------------------------------------------------------------------------

# set instance list type (Policies live on macOS instances)
instance_list_type="mac"

# defaults
mode="report"
mode_explicit=0
interval="Zero+Days"        # default: flush all logs
policy_id=""
policy_name=""
policy_keyword=""
policy_category=""
dry_run=0
output_dir=""

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

DIR=$(/usr/bin/dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Flush the execution logs of one or more Jamf Pro policies across one or more instances.

Run with no mode flag (and interactively) to get a guided menu that walks you through
report vs flush, scope, interval and preview/apply. Flags below skip the menu and are
intended for automation.

Mode (default is report):
--report                           - read-only; list matched policies + URLs (default)
--flush                            - flush the execution logs of the matched policies

Interval (flush mode - default flushes ALL logs):
--interval VAL                     - Zero+Days (all) | One+Day | One+Week | One+Month |
                                     Three+Months | Six+Months
                                     ("Zero Days" flushes every log; the others flush logs
                                     older than that period)

Scope (default is every policy on the instance):
--policy-id ID                     - only the policy with this id (per-instance)
--policy-name "NAME"               - only the policy exactly matching this display name
--policy-keyword "KW"              - every policy whose display name contains KW
                                     (case-insensitive)
--category "CAT"                   - every policy in this Jamf Pro category

Instances:
-il | --instance-list FILENAME     - instance-list filename (without .txt)
-i  | --instance JSS_URL           - a single instance (repeatable)
-a  | --all                        - all instances in the list
--user | --client-id CLIENT_ID     - client ID / username to use

Other:
-n  | --dry-run                    - (flush mode) preview what would be flushed; write nothing
-o  | --output-dir DIR             - where to save the report (prompts /tmp or ~/Desktop if omitted)
-x  | --nointeraction              - run without interaction
-v                                 - verbose jamf-cli output
-h  | --help                       - this help

Examples:
# Report every policy across a list (read-only, default)
./flush-policy-logs.sh -il my-mac-list --all

# Flush ALL logs for policies whose name contains "Recon" (preview first)
./flush-policy-logs.sh --flush --policy-keyword "Recon" -il my-mac-list --all --dry-run

# Flush logs older than one month for a whole category, on one instance
./flush-policy-logs.sh --flush --category "Maintenance" --interval One+Month -i https://your.jamfcloud.com
USAGE
}

# human label for an interval enum value (spaces instead of +)
label_for_interval() {
    printf '%s' "${1//+/ }"
}

# emit "id <TAB> name" for every policy matching the chosen scope on the current instance.
# Uses jamf-cli for id/name/keyword/all; uses the Classic category endpoint for --category.
policies_for_instance() {
    if [[ -n "$policy_id" ]]; then
        # confirm it exists and grab its name
        local one
        one=$(jc pro classic-policies get "$policy_id" -o json 2>/dev/null \
            | "$jq_bin" -r '(.policy // .) | .general.name // .name // empty')
        [[ -n "$one" ]] && printf '%s\t%s\n' "$policy_id" "$one"
        return
    fi

    if [[ -n "$policy_category" ]]; then
        # Classic API: GET /JSSResource/policies/category/{category} (token already set)
        /usr/bin/curl -s \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/json" \
            "${jss_url%/}/JSSResource/policies/category/$(encode_name "$policy_category")" \
            | "$jq_bin" -r '(.policies // [])[] | "\(.id)\t\(.name)"' 2>/dev/null
        return
    fi

    # all / name / keyword all start from the full policy list
    jc pro classic-policies list -o json 2>/dev/null \
        | "$jq_bin" -r --arg nm "$policy_name" --arg kw "$policy_keyword" '
            (if type=="object" then (.policies // .results // .) else . end)[]
            | {id: .id, name: (.name // "")}
            | select(
                ($nm == "" or .name == $nm) and
                ($kw == "" or ((.name | ascii_downcase) | contains($kw | ascii_downcase)))
              )
            | "\(.id)\t\(.name)"
          '
}

# flush one policy id on the current instance; logs one CSV row + a console line
flush_policy() {
    local pid="$1" pname="$2" status
    status=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: Bearer $token" \
        "${jss_url%/}/JSSResource/logflush/policy/id/${pid}/interval/${interval}")
    if [[ "$status" == "200" || "$status" == "201" ]]; then
        printf "   [%s] flushed \"%s\" (id %s)\n" "$jss_instance" "${pname:-policy}" "$pid"
        echo "$jss_instance,\"${pname:-policy}\",$pid,$(label_for_interval "$interval"),SUCCESS" >> "$output_csv"
        (( success_count++ ))
    else
        printf "   [%s] FAILED \"%s\" (id %s) - HTTP %s\n" "$jss_instance" "${pname:-policy}" "$pid" "$status"
        echo "$jss_instance,\"${pname:-policy}\",$pid,$(label_for_interval "$interval"),FAILED (HTTP $status)" >> "$output_csv"
        (( fail_count++ ))
    fi
}

# ---- interactive pickers -------------------------------------------------------

# top-level: report vs flush
menu_choose_mode() {
    echo
    echo "----------------------------------------"
    echo "  Policy Log Flusher"
    echo "----------------------------------------"
    echo "Reports on, and optionally flushes, Jamf Pro policy execution logs."
    choose_from_menu 1 "" \
        "Report  - read-only list of the policies a flush would target" \
        "Flush   - flush the execution logs" || exit 1
    case "$menu_choice" in
        1) mode="report" ;;
        2) mode="flush" ;;
    esac
}

# choose which policies to target (only when no scope flag was given)
menu_choose_scope() {
    [[ -n "$policy_id$policy_name$policy_keyword$policy_category" ]] && return 0
    choose_from_menu 1 "Which policies?" \
        "All policies on each chosen instance" \
        "Policies whose name contains a keyword" \
        "Policies in a category" || exit 1
    case "$menu_choice" in
        2) read -r -p "   Keyword: " policy_keyword ;;
        3) read -r -p "   Category name: " policy_category ;;
    esac
}

# choose the flush interval (only when --interval was not given)
menu_choose_interval() {
    local intervals=(Zero+Days One+Day One+Week One+Month Three+Months Six+Months)
    local labels=("Zero days (all logs)" "One day" "One week" "One month" "Three months" "Six months")
    choose_from_menu 1 "Flush logs older than:" "${labels[@]}" || exit 1
    interval="${intervals[$((menu_choice - 1))]}"
    echo "   Selected: ${labels[$((menu_choice - 1))]}"
}

# flush mode: preview vs apply
menu_choose_run_mode() {
    choose_from_menu 1 "Run mode:" \
        "Preview only (dry-run, flushes nothing)" \
        "Flush for real" || exit 1
    case "$menu_choice" in
        1) dry_run=1 ;;
        2) dry_run=0 ;;
    esac
}

interactive_menu() {
    menu_choose_mode
    menu_choose_scope
    [[ "$mode" == "report" ]] && return 0
    menu_choose_interval
    menu_choose_run_mode
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        --report)          mode="report"; mode_explicit=1 ;;
        --flush|--apply)   mode="flush"; mode_explicit=1 ;;
        --interval)        shift; interval="$1" ;;
        --policy-id)       shift; policy_id="$1" ;;
        --policy-name)     shift; policy_name="$1" ;;
        --policy-keyword)  shift; policy_keyword="$1" ;;
        --category)        shift; policy_category="$1" ;;
        -il|--instance-list) shift; chosen_instance_list_file="$1" ;;
        -i|--instance)     shift; chosen_instance="$1" ;;
        -a|-ai|--all|--all-instances) all_instances=1 ;;
        --id|--client-id|--user|--username) shift; chosen_id="$1" ;;
        -n|--dry-run)      dry_run=1 ;;
        -o|--output-dir)   shift; output_dir="$1" ;;
        -x|--nointeraction) no_interaction=1 ;;
        -v|--verbose)      verbose=1 ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done
echo

# openpyxl is optional (formatted .xlsx output, else .csv)
ensure_dependencies jamf-cli jq "openpyxl?" || exit 1

# reject conflicting scope flags
scope_flags=0
[[ -n "$policy_id" ]] && (( scope_flags++ ))
[[ -n "$policy_name" ]] && (( scope_flags++ ))
[[ -n "$policy_keyword" ]] && (( scope_flags++ ))
[[ -n "$policy_category" ]] && (( scope_flags++ ))
if [[ $scope_flags -gt 1 ]]; then
    echo "ERROR: use only one of --policy-id / --policy-name / --policy-keyword / --category."
    exit 1
fi

# if interactive and no mode was specified on the command line, run the menu
if [[ $no_interaction -ne 1 && $mode_explicit -ne 1 ]]; then
    interactive_menu
fi

success_count=0
fail_count=0
match_count=0

scope_desc="ALL policies"
[[ -n "$policy_id" ]] && scope_desc="policy id $policy_id"
[[ -n "$policy_name" ]] && scope_desc="policy named '$policy_name'"
[[ -n "$policy_keyword" ]] && scope_desc="policies whose name contains '$policy_keyword'"
[[ -n "$policy_category" ]] && scope_desc="policies in category '$policy_category'"

announce_instances

# select the instances to operate on
choose_destination_instances

choose_output_dir || exit 1
trap remove_jamfcli_token EXIT

# ================================ REPORT MODE ===================================
if [[ "$mode" == "report" ]]; then
    output_csv="${output_dir}/policy-logflush-report.csv"
    output_xlsx="${output_dir}/policy-logflush-report.xlsx"
    echo "Instance,Policy,ID,Interval,URL" > "$output_csv"

    echo "Scope: $scope_desc"

    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo
        echo "Checking policies on $jss_instance..."
        if ! token_for_instance; then
            echo "   [$jss_instance] could not obtain a token. Skipping." >&2
            continue
        fi

        r_names=(); r_ids=(); r_links=()
        while IFS=$'\t' read -r pid pname; do
            [[ -z "$pid" ]] && continue
            (( match_count++ ))
            local_url="${jss_instance%/}/policies.html?id=${pid}&o=r"
            echo "$jss_instance,\"$pname\",$pid,-,$local_url" >> "$output_csv"
            r_ids+=("$pid"); r_names+=("$pname"); r_links+=("$local_url")
        done < <(policies_for_instance)

        remove_jamfcli_token

        if [[ ${#r_ids[@]} -eq 0 ]]; then
            echo "   (no policies match)"
            continue
        fi

        nw=8
        for i2 in "${!r_names[@]}"; do
            [[ ${#r_names[$i2]} -gt $nw ]] && nw=${#r_names[$i2]}
        done
        [[ $nw -gt 44 ]] && nw=44

        echo
        printf "   %-6s  %-*s  %s\n" "ID" "$nw" "Policy" "Link"
        printf "   %-6s  %-*s  %s\n" "------" "$nw" \
            "$(printf '%.0s-' $(/usr/bin/seq 1 "$nw"))" "------------------------------"
        for i2 in "${!r_names[@]}"; do
            printf "   %-6s  %-*.*s  %s\n" "${r_ids[$i2]}" "$nw" "$nw" "${r_names[$i2]}" "${r_links[$i2]}"
        done
    done

    final_output=$(csv_to_xlsx "$output_csv" "$output_xlsx" "Policy Log Flush" 5)

    echo
    echo "Found $match_count matching policy(ies)."
    echo "Saved to: $final_output"
    echo
    echo "Finished"
    echo
    exit 0
fi

# ================================= FLUSH MODE ===================================
output_csv="${output_dir}/policy-logflush-result.csv"
output_xlsx="${output_dir}/policy-logflush-result.xlsx"
echo "Instance,Policy,ID,Interval,Result" > "$output_csv"

echo "Mode: flush"
echo "Scope: $scope_desc"
echo "Interval: $(label_for_interval "$interval")"
[[ $dry_run -eq 1 ]] && echo "(dry-run: no logs will be flushed)"

for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    echo
    echo "Processing $jss_instance..."
    if ! token_for_instance; then
        echo "   [$jss_instance] could not obtain a token. Skipping." >&2
        echo "$jss_instance,\"-\",-,$(label_for_interval "$interval"),NO_TOKEN" >> "$output_csv"
        (( fail_count++ ))
        continue
    fi

    ids=(); names=()
    while IFS=$'\t' read -r pid pname; do
        [[ -z "$pid" ]] && continue
        ids+=("$pid"); names+=("$pname")
    done < <(policies_for_instance)

    if [[ ${#ids[@]} -eq 0 ]]; then
        echo "   [$jss_instance] no policies match."
        remove_jamfcli_token
        continue
    fi

    echo "   [$jss_instance] ${#ids[@]} policy(ies) match."
    (( match_count += ${#ids[@]} ))

    for i in "${!ids[@]}"; do
        if [[ $dry_run -eq 1 ]]; then
            printf "   [%s] (dry-run) would flush \"%s\" (id %s)\n" "$jss_instance" "${names[$i]:-policy}" "${ids[$i]}"
            echo "$jss_instance,\"${names[$i]:-policy}\",${ids[$i]},$(label_for_interval "$interval"),DRY-RUN" >> "$output_csv"
        else
            flush_policy "${ids[$i]}" "${names[$i]}"
        fi
    done

    remove_jamfcli_token
done

final_output=$(csv_to_xlsx "$output_csv" "$output_xlsx" "Policy Log Flush" 0)

echo
if [[ $dry_run -eq 1 ]]; then
    echo "Done (dry-run). $match_count policy(ies) would be flushed at interval '$(label_for_interval "$interval")'."
else
    echo "Done.   Flushed: $success_count   Failed: $fail_count"
fi
echo "Log saved to: $final_output"
echo
echo "Finished"
echo
