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
# Output (in /tmp):
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

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

if [[ ! -f "$jamf_cli_path" ]]; then
    jamf_cli_path=$(which jamf-cli)
fi
if [[ ! -f "$jamf_cli_path" ]]; then
    echo "ERROR: jamf-cli not found. Please ensure jamf-cli is installed and in your PATH."
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

# run jamf-cli for the current instance ($jss_url + token already set)
jc() {
    "$jamf_cli_path" "$@" --url "$jss_url" --token-file "$token_file_for_jamfcli"
}

# human label for an interval enum value (spaces instead of +)
label_for_interval() {
    printf '%s' "${1//+/ }"
}

# obtain a bearer token for the current $jss_instance (sets jss_url + token_file_for_jamfcli)
# returns 1 if a token could not be obtained
token_for_instance() {
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
    else
        set_credentials "$jss_instance"
    fi
    jss_url="${jss_instance}"
    check_token || return 1
    token_file_for_jamfcli=$(mktemp /tmp/jamfcli_token.XXXXXX)
    echo "$token" > "$token_file_for_jamfcli"
}

# emit "id <TAB> name" for every policy matching the chosen scope on the current instance.
# Uses jamf-cli for id/name/keyword/all; uses the Classic category endpoint for --category.
policies_for_instance() {
    if [[ -n "$policy_id" ]]; then
        # confirm it exists and grab its name
        local one
        one=$(jc pro classic-policies get "$policy_id" -o json 2>/dev/null \
            | jq -r '(.policy // .) | .general.name // .name // empty')
        [[ -n "$one" ]] && printf '%s\t%s\n' "$policy_id" "$one"
        return
    fi

    if [[ -n "$policy_category" ]]; then
        # Classic API: GET /JSSResource/policies/category/{category} (token already set)
        curl -s \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/json" \
            "${jss_url%/}/JSSResource/policies/category/$(encode_name "$policy_category")" \
            | jq -r '(.policies // [])[] | "\(.id)\t\(.name)"' 2>/dev/null
        return
    fi

    # all / name / keyword all start from the full policy list
    jc pro classic-policies list -o json 2>/dev/null \
        | jq -r --arg nm "$policy_name" --arg kw "$policy_keyword" '
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
    status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
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
    local sel
    echo
    echo "----------------------------------------"
    echo "  Policy Log Flusher"
    echo "----------------------------------------"
    echo "Reports on, and optionally flushes, Jamf Pro policy execution logs."
    echo
    echo "   [1] Report  - read-only list of the policies a flush would target"
    echo "   [2] Flush   - flush the execution logs"
    echo
    read -r -p "   Choose by number [1]: " sel
    case "$sel" in
        ""|1) mode="report" ;;
        2)    mode="flush" ;;
        *) echo "ERROR: invalid selection. Aborting."; exit 1 ;;
    esac
}

# choose which policies to target (only when no scope flag was given)
menu_choose_scope() {
    [[ -n "$policy_id$policy_name$policy_keyword$policy_category" ]] && return 0
    local sel kw cat
    echo
    echo "Which policies?"
    echo "   [1] All policies on each chosen instance"
    echo "   [2] Policies whose name contains a keyword"
    echo "   [3] Policies in a category"
    echo
    read -r -p "   Choose by number [1]: " sel
    case "$sel" in
        ""|1) : ;;
        2)    read -r -p "   Keyword: " kw; policy_keyword="$kw" ;;
        3)    read -r -p "   Category name: " cat; policy_category="$cat" ;;
        *) echo "ERROR: invalid selection. Aborting."; exit 1 ;;
    esac
}

# choose the flush interval (only when --interval was not given)
menu_choose_interval() {
    local intervals=(Zero+Days One+Day One+Week One+Month Three+Months Six+Months)
    local labels=("Zero days (all logs)" "One day" "One week" "One month" "Three months" "Six months")
    local i sel
    echo
    echo "Flush logs older than:"
    for i in "${!intervals[@]}"; do
        printf "   [%s] %s\n" "$i" "${labels[$i]}"
    done
    echo
    read -r -p "   Choose by number [0]: " sel
    [[ -z "$sel" ]] && sel=0
    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ -n "${intervals[$sel]:-}" ]]; then
        interval="${intervals[$sel]}"
        echo "   Selected: ${labels[$sel]}"
    else
        echo "ERROR: invalid selection. Aborting."
        exit 1
    fi
}

# flush mode: preview vs apply
menu_choose_run_mode() {
    local sel
    echo
    echo "Run mode:"
    echo "   [1] Preview only (dry-run, flushes nothing)"
    echo "   [2] Flush for real"
    echo
    read -r -p "   Choose by number [1]: " sel
    case "$sel" in
        ""|1) dry_run=1 ;;
        2)    dry_run=0 ;;
        *) echo "ERROR: invalid selection. Aborting."; exit 1 ;;
    esac
}

interactive_menu() {
    menu_choose_mode
    menu_choose_scope
    [[ "$mode" == "report" ]] && return 0
    menu_choose_interval
    menu_choose_run_mode
}

# convert the CSV to a formatted xlsx (hyperlinked URL col) if openpyxl is present.
# $1 = sheet title, $2 = 1-based column number holding a URL (0 = none)
csv_to_xlsx() {
    local title="$1" url_col="$2"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c "import openpyxl" >/dev/null 2>&1 || return 1
    python3 - "$output_csv" "$output_xlsx" "$title" "$url_col" <<'PY'
import csv, sys
from openpyxl import Workbook
from openpyxl.styles import Font
csv_path, xlsx_path, title, url_col = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
wb = Workbook(); ws = wb.active; ws.title = title[:31]
link_font = Font(color="0563C1", underline="single")
header_font = Font(bold=True)
with open(csv_path, newline="") as f:
    rows = list(csv.reader(f))
for r_idx, row in enumerate(rows, start=1):
    ws.append(row)
    if r_idx == 1:
        for c_idx in range(1, len(row) + 1):
            ws.cell(row=1, column=c_idx).font = header_font
        continue
    if url_col and len(row) >= url_col and str(row[url_col - 1]).startswith("http"):
        cell = ws.cell(row=r_idx, column=url_col)
        cell.hyperlink = row[url_col - 1]
        cell.font = link_font
widths = [40, 40, 8, 16, 66]
for i, w in enumerate(widths, start=1):
    ws.column_dimensions[chr(64 + i)].width = w
ws.freeze_panes = "A2"
wb.save(xlsx_path)
PY
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
        -x|--nointeraction) no_interaction=1 ;;
        -v|--verbose)      verbose=1 ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done
echo

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

if [[ -n "$chosen_instance" ]]; then
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances to operate on
choose_destination_instances

# ================================ REPORT MODE ===================================
if [[ "$mode" == "report" ]]; then
    output_csv="/tmp/policy-logflush-report.csv"
    output_xlsx="/tmp/policy-logflush-report.xlsx"
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

        rm -f "$token_file_for_jamfcli"

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
            "$(printf '%.0s-' $(seq 1 "$nw"))" "------------------------------"
        for i2 in "${!r_names[@]}"; do
            printf "   %-6s  %-*.*s  %s\n" "${r_ids[$i2]}" "$nw" "$nw" "${r_names[$i2]}" "${r_links[$i2]}"
        done
    done

    final_output="$output_csv"
    if csv_to_xlsx "Policy Log Flush" 5; then
        rm -f "$output_csv"
        final_output="$output_xlsx"
    fi

    echo
    echo "Found $match_count matching policy(ies)."
    echo "Saved to: $final_output"
    echo
    echo "Finished"
    echo
    exit 0
fi

# ================================= FLUSH MODE ===================================
output_csv="/tmp/policy-logflush-result.csv"
output_xlsx="/tmp/policy-logflush-result.xlsx"
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
        rm -f "$token_file_for_jamfcli"
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

    rm -f "$token_file_for_jamfcli"
done

final_output="$output_csv"
if csv_to_xlsx "Policy Log Flush" 0; then
    rm -f "$output_csv"
    final_output="$output_xlsx"
fi

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
