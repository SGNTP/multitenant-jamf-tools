#!/bin/bash

# Report on, or set, the "Minimum Required macOS Version" enforcement on
# Computer PreStage enrollments across one or more Jamf Pro instances.
#
# Flow: instance(s) -> mode -> prestages -> enforcement type -> version ->
#       preview/apply -> output folder.
#
# Modes (menu if omitted):
#   --report     Read-only. Lists prestages with their enforcement and a link.
#   --set        Changes the enforcement type/version, then re-reads each
#                prestage and logs the before and after values.
#
# PUT /v3/computer-prestages/{id} can return HTTP 500 (empty errors) even when
# the write succeeds, so --set ignores the update's exit code and confirms the
# stored value by re-reading.
#
# Usage:
#   ./set-prestage-os-version.sh -il my-list -a --set --version 15.7.7 --dry-run
#   ./set-prestage-os-version.sh --set --from-file targets.csv --use-file-values

# computer prestages live on macOS instances
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

mode=""
report_all=""
target_type=""
target_version=""
prestage_ids=()
prestage_name=""
prestage_keyword=""
only_enforced=0
dry_run=""
from_file=""
use_file_values=0
output_dir=""
enforcement_types=(NO_ENFORCEMENT MINIMUM_OS_LATEST_VERSION MINIMUM_OS_LATEST_MAJOR_VERSION
    MINIMUM_OS_LATEST_MINOR_VERSION MINIMUM_OS_SPECIFIC_VERSION)

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -il|--instance-list)  shift; chosen_instance_list_file="$1" ;;
        -i|--instance)        shift; chosen_instances+=("$1") ;;
        -a|--all-instances|--all) all_instances=1 ;;
        --id|--client-id)     shift; chosen_id="$1" ;;
        -x|--nointeraction)   no_interaction=1 ;;
        -v|--verbose)         verbose=1 ;;
        -j|--jamf-cli)        shift; jamf_cli_path="$1" ;;
        -o|--output-dir)      shift; output_dir="$1" ;;
        -y|--yes)             assume_yes=1 ;;
        --report)             mode="report" ;;
        --all-prestages)      report_all=1 ;;
        --set|--apply)        mode="set" ;;
        -n|--dry-run)         dry_run=1 ;;
        --type)               shift; target_type="$1" ;;
        --version)            shift; target_version="$1" ;;
        --only-enforced)      only_enforced=1 ;;
        --prestage-id)        shift; prestage_ids+=("$1") ;;
        --prestage-name)      shift; prestage_name="$1" ;;
        --prestage-keyword)   shift; prestage_keyword="$1" ;;
        --from-file)          shift; from_file="$1" ;;
        --use-file-values)    use_file_values=1 ;;
        -h|--help)
            echo "Usage: $0 [MJT flags] [--report|--set] [prestage flags] [value flags]"
            echo ""
            echo "Mode (menu if omitted):"
            echo "  --report                 Read-only list of prestage enforcement"
            echo "  --all-prestages          (report) include prestages with no enforcement"
            echo "  --set                    Change the enforcement type/version"
            echo ""
            echo "Value (--set; menu if omitted):"
            echo "  --type TYPE              NO_ENFORCEMENT | MINIMUM_OS_LATEST_VERSION |"
            echo "                           MINIMUM_OS_LATEST_MAJOR_VERSION |"
            echo "                           MINIMUM_OS_LATEST_MINOR_VERSION |"
            echo "                           MINIMUM_OS_SPECIFIC_VERSION (default with --version)"
            echo "  --version X.Y.Z          Specific macOS version, e.g. 15.7.7"
            echo ""
            echo "PreStages (--set; pick one, menu if omitted, default every prestage):"
            echo "  --prestage-id ID         PreStage ID (repeatable; single instance only)"
            echo "  --prestage-name \"NAME\"   Exact prestage name"
            echo "  --prestage-keyword \"KW\"  PreStages whose name contains KW (case-insensitive)"
            echo "  --only-enforced          Only prestages that already enforce a version"
            echo ""
            echo "Bulk from a file (--set):"
            echo "  --from-file FILE.csv     Targets from a CSV: instance in column 1, prestage ID"
            echo "                           from the computerPrestages.html?id=N link. A report"
            echo "                           saved as CSV works as-is."
            echo "  --use-file-values        Take the enforcement type and version from each row"
            echo ""
            echo "Run:"
            echo "  -n  | --dry-run          Preview changes; write nothing"
            echo "  -y  | --yes              Don't ask for confirmation before applying"
            echo "                           (non-interactive runs never ask)"
            echo ""
            echo "Output:"
            echo "  -o  | --output-dir DIR   Where to save the report (prompts /tmp or ~/Desktop if omitted)"
            echo ""
            echo "MJT flags:"
            echo "  -il | --instance-list FILENAME"
            echo "  -i  | --instance URL     (repeatable)"
            echo "  -a  | --all-instances"
            echo "  --id | --client-id CLIENT_ID"
            echo "  -x  | --nointeraction"
            echo "  -v  | --verbose"
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

scope_flags=0
[[ ${#prestage_ids[@]} -gt 0 ]] && (( scope_flags++ ))
[[ -n "$prestage_name" ]] && (( scope_flags++ ))
[[ -n "$prestage_keyword" ]] && (( scope_flags++ ))
[[ -n "$from_file" ]] && (( scope_flags++ ))
if [[ $scope_flags -gt 1 ]]; then
    echo "ERROR: use only one of --prestage-id / --prestage-name / --prestage-keyword / --from-file."
    exit 1
fi
if [[ $use_file_values -eq 1 && -z "$from_file" ]]; then
    echo "ERROR: --use-file-values requires --from-file."
    exit 1
fi
if [[ -n "$from_file" && ! -f "$from_file" ]]; then
    echo "ERROR: --from-file '$from_file' not found."
    exit 1
fi
if [[ -n "$target_type" ]]; then
    valid=0
    for t in "${enforcement_types[@]}"; do [[ "$t" == "$target_type" ]] && valid=1; done
    if [[ $valid -eq 0 ]]; then
        echo "ERROR: invalid --type '$target_type' (see --help)."
        exit 1
    fi
fi
# a version on its own implies a specific-version enforcement
[[ -z "$target_type" && -n "$target_version" ]] && target_type="MINIMUM_OS_SPECIFIC_VERSION"
[[ -n "$from_file" || ${#prestage_ids[@]} -gt 0 || -n "$prestage_name$prestage_keyword" ]] \
    && [[ -z "$mode" ]] && mode="set"
[[ -n "$target_type" && -z "$mode" ]] && mode="set"

interactive=1
[[ "${no_interaction:-0}" -eq 1 || ! -t 0 ]] && interactive=0
if [[ $interactive -eq 0 ]]; then
    mode="${mode:-report}"
    if [[ "$mode" == "set" && $use_file_values -eq 0 ]]; then
        if [[ -z "$target_type" ]]; then
            echo "ERROR: --set without interaction needs --type or --version."
            exit 1
        fi
        if [[ "$target_type" == "MINIMUM_OS_SPECIFIC_VERSION" && -z "$target_version" ]]; then
            echo "ERROR: --version is required with MINIMUM_OS_SPECIFIC_VERSION."
            exit 1
        fi
    fi
fi

# -------------------------------------------------------------------------
# FUNCTIONS
# -------------------------------------------------------------------------

label_for_type() {
    case "$1" in
        NO_ENFORCEMENT)                  echo "No enforcement" ;;
        MINIMUM_OS_LATEST_VERSION)       echo "Latest version" ;;
        MINIMUM_OS_LATEST_MAJOR_VERSION) echo "Latest major version" ;;
        MINIMUM_OS_LATEST_MINOR_VERSION) echo "Latest minor version" ;;
        MINIMUM_OS_SPECIFIC_VERSION)     echo "Specific version" ;;
        *)                               echo "$1" ;;
    esac
}

fmt_val() {
    local l
    l="$(label_for_type "$1")"
    if [[ -n "$2" ]]; then echo "$l $2"; else echo "$l"; fi
}

csv_field() {
    printf '"%s"' "${1//\"/\"\"}"
}

prestage_url() {
    printf '%s/computerPrestages.html?id=%s&o=r' "${jss_instance%/}" "$1"
}

prestages_json() {
    jc pro computer-prestages list -o json 2>/dev/null \
        | "$jq_bin" -c '(if type=="object" then .results else . end)
            | sort_by(.displayName | ascii_downcase)'
}

# Parse "1,3,5-7" into $picked (0-based indexes), bounded by $1 items.
parse_number_list() {
    local max="$1" input="$2" part a b n
    picked=()
    for part in $(printf '%s' "$input" | /usr/bin/tr ',' ' '); do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            a="$part"; b="$part"
        else
            return 1
        fi
        for (( n = a; n <= b; n++ )); do
            (( n >= 1 && n <= max )) || return 1
            picked+=($((n - 1)))
        done
    done
    [[ ${#picked[@]} -gt 0 ]]
}

# ---- menus ---------------------------------------------------------------

choose_mode() {
    [[ -n "$mode" ]] && return 0
    choose_from_menu 1 "What do you want to do?" \
        "Report - list current macOS version enforcement (read-only)" \
        "Set    - change the enforcement" || exit 1
    case "$menu_choice" in
        1) mode="report" ;;
        2) mode="set" ;;
    esac
}

choose_report_scope() {
    [[ -n "$report_all" ]] && return 0
    choose_from_menu 1 "Which prestages?" \
        "Only prestages that enforce a version" \
        "All prestages" || exit 1
    report_all=0
    [[ "$menu_choice" -eq 2 ]] && report_all=1
}

# pick individual prestages from the first instance, showing current values
choose_prestages() {
    local json i selection
    local -a ids=() labels=()
    json=$(prestages_json)
    while IFS=$'\t' read -r pid label; do
        [[ -z "$pid" ]] && continue
        ids+=("$pid"); labels+=("$label")
    done < <(printf '%s' "$json" | "$jq_bin" -r '.[]
        | "\(.id)\t\(.displayName) [\(.prestageMinimumOsTargetVersionType)\(if (.minimumOsSpecificVersion // "") != "" then " " + .minimumOsSpecificVersion else "" end)]"')
    if [[ ${#ids[@]} -eq 0 ]]; then
        echo "   No Computer PreStages on $jss_instance."
        exit 1
    fi
    echo
    for i in "${!ids[@]}"; do
        printf '   [%d] %s\n' "$((i + 1))" "${labels[$i]}"
    done
    while true; do
        read -r -p "   Number(s), e.g. 1,3,5-7: " selection || exit 1
        parse_number_list "${#ids[@]}" "$selection" && break
        echo "   Not a valid option."
    done
    for i in "${picked[@]}"; do
        prestage_ids+=("${ids[$i]}")
    done
}

choose_set_scope() {
    [[ $scope_flags -gt 0 || $only_enforced -eq 1 ]] && return 0
    local -a opts=(
        "All prestages"
        "Only prestages that already enforce a version"
        "PreStages whose name contains a keyword"
    )
    [[ ${#instance_choice_array[@]} -eq 1 ]] && opts+=("Pick individual prestages")
    choose_from_menu 1 "Which prestages should be changed?" "${opts[@]}" || exit 1
    case "$menu_choice" in
        2) only_enforced=1 ;;
        3) read -r -p "   Keyword (e.g. 'shar' matches '... - Shared'): " prestage_keyword ;;
        4) choose_prestages ;;
    esac
}

choose_enforcement_type() {
    [[ -n "$target_type" || $use_file_values -eq 1 ]] && return 0
    local -a labels=()
    local t
    for t in "${enforcement_types[@]}"; do labels+=("$(label_for_type "$t")"); done
    choose_from_menu 5 "Minimum required macOS version:" "${labels[@]}" || exit 1
    target_type="${enforcement_types[$((menu_choice - 1))]}"
}

# versions come from the first instance's available updates; fall back to typing
# one (that endpoint is off unless Managed Software Update Plans is enabled)
choose_macos_version() {
    [[ "$target_type" != "MINIMUM_OS_SPECIFIC_VERSION" ]] && return 0
    [[ -n "$target_version" || $use_file_values -eq 1 ]] && return 0
    local v
    local -a versions=()
    while IFS= read -r v; do
        [[ -n "$v" ]] && versions+=("$v")
    done < <(jc pro managed-software-updates available-updates -o json 2>/dev/null \
        | "$jq_bin" -r '.availableUpdates.macOS[]?' 2>/dev/null)
    if [[ ${#versions[@]} -gt 0 ]]; then
        choose_from_menu 1 "macOS versions available on $jss_instance:" "${versions[@]}" "Other (type a version)" || exit 1
        if [[ "$menu_choice" -le ${#versions[@]} ]]; then
            target_version="${versions[$((menu_choice - 1))]}"
            return 0
        fi
    else
        echo
        echo "   Couldn't list available macOS versions from $jss_instance"
        echo "   (needs Managed Software Update Plans turned on)."
    fi
    while true; do
        read -r -p "   macOS version, e.g. 15.7.7: " target_version || exit 1
        [[ "$target_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] && break
        echo "   Not a valid version."
    done
}

choose_run_mode() {
    [[ -n "$dry_run" ]] && return 0
    choose_from_menu 1 "Run mode:" \
        "Preview only (dry-run, writes nothing)" \
        "Apply changes" || exit 1
    dry_run=0
    [[ "$menu_choice" -eq 1 ]] && dry_run=1
}

# ---- report --------------------------------------------------------------

report_instance() {
    local json
    json=$(prestages_json)
    if [[ -z "$json" ]]; then
        echo "   Could not read Computer PreStages."
        return
    fi
    while IFS=$'\t' read -r pid name etype ever; do
        [[ -z "$pid" ]] && continue
        (( report_count++ ))
        [[ "$etype" != "NO_ENFORCEMENT" ]] && (( enforced_count++ ))
        printf '   %-40.40s  %s\n' "$name" "$(fmt_val "$etype" "$ever")"
        printf '%s,%s,%s,%s,%s,%s\n' "$jss_instance" "$(csv_field "$name")" "$pid" \
            "$etype" "$ever" "$(prestage_url "$pid")" >> "$csv_file"
    done < <(printf '%s' "$json" | "$jq_bin" -r --arg all "$report_all" '.[]
        | select($all == "1" or .prestageMinimumOsTargetVersionType != "NO_ENFORCEMENT")
        | [.id, .displayName, .prestageMinimumOsTargetVersionType, (.minimumOsSpecificVersion // "")]
        | @tsv')
    [[ $report_count -eq $instance_start_count ]] && echo "   No prestages with macOS version enforcement."
}

# ---- set -----------------------------------------------------------------

write_set_row() {
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$jss_instance" "$(csv_field "$2")" "$1" \
        "$(csv_field "$3")" "$(csv_field "$4")" "$5" "$(prestage_url "$1")" >> "$csv_file"
    printf '   %-40.40s  %-30.30s -> %-30.30s %s\n' "$2" "$3" "$4" "$5"
}

process_prestage() {
    local pid="$1" current label cur_type before_val updated want_ver after after_type after_ver after_val

    current=$(jc pro computer-prestages get "$pid" -o json 2>/dev/null)
    if [[ -z "$current" ]] || ! printf '%s' "$current" | "$jq_bin" -e '.id' >/dev/null 2>&1; then
        write_set_row "$pid" "ID $pid" "-" "-" "Read error"
        (( fail_count++ ))
        return
    fi

    label=$(printf '%s' "$current" | "$jq_bin" -r '.displayName // .id')
    cur_type=$(printf '%s' "$current" | "$jq_bin" -r '.prestageMinimumOsTargetVersionType // ""')
    before_val=$(fmt_val "$cur_type" "$(printf '%s' "$current" | "$jq_bin" -r '.minimumOsSpecificVersion // ""')")

    if [[ $only_enforced -eq 1 && "$cur_type" == "NO_ENFORCEMENT" ]]; then
        write_set_row "$pid" "$label" "$before_val" "$before_val" "Skipped"
        (( skip_count++ ))
        return
    fi

    want_ver=""
    [[ "$target_type" == "MINIMUM_OS_SPECIFIC_VERSION" ]] && want_ver="$target_version"

    if [[ "$dry_run" -eq 1 ]]; then
        write_set_row "$pid" "$label" "$before_val" "$(fmt_val "$target_type" "$want_ver")" "Dry-run"
        (( dryrun_count++ ))
        return
    fi

    updated=$(printf '%s' "$current" | "$jq_bin" --arg t "$target_type" --arg v "$want_ver" '
        .prestageMinimumOsTargetVersionType = $t | .minimumOsSpecificVersion = $v')
    printf '%s' "$updated" | jc pro computer-prestages update "$pid" >/dev/null 2>&1 || true

    after=$(jc pro computer-prestages get "$pid" -o json 2>/dev/null)
    after_type=$(printf '%s' "$after" | "$jq_bin" -r '.prestageMinimumOsTargetVersionType // ""')
    after_ver=$(printf '%s' "$after" | "$jq_bin" -r '.minimumOsSpecificVersion // ""')
    after_val=$(fmt_val "$after_type" "$after_ver")

    if [[ "$after_type" == "$target_type" && "$after_ver" == "$want_ver" ]]; then
        write_set_row "$pid" "$label" "$before_val" "$after_val" "Success"
        (( success_count++ ))
    else
        write_set_row "$pid" "$label" "$before_val" "$after_val" "Failed"
        (( fail_count++ ))
    fi
}

# prestage IDs on the current instance matching the chosen scope
prestage_ids_for_instance() {
    if [[ ${#prestage_ids[@]} -gt 0 ]]; then
        printf '%s\n' "${prestage_ids[@]}"
        return
    fi
    prestages_json | "$jq_bin" -r --arg nm "$prestage_name" --arg kw "$prestage_keyword" '.[]
        | select(
            ($nm == "" or .displayName == $nm) and
            ($kw == "" or ((.displayName // "" | ascii_downcase) | contains($kw | ascii_downcase)))
          )
        | .id'
}

# CSV rows -> "instance<US>id<US>type<US>version", one per target. Instance is
# column 1; the ID comes from the computerPrestages.html?id=N link.
file_targets() {
    /usr/bin/awk -F',' -v s=$'\x1f' 'NR>1 && $1!="" {
        line=$0
        idv=""; if (match(line, /id=[0-9]+/)) idv=substr(line, RSTART+3, RLENGTH-3)
        typ=""; ver=""
        for (i=1;i<=NF;i++){
            f=$i; gsub(/[\r"]/,"",f)
            if (f=="NO_ENFORCEMENT"||f=="MINIMUM_OS_LATEST_VERSION"||f=="MINIMUM_OS_LATEST_MAJOR_VERSION"||f=="MINIMUM_OS_LATEST_MINOR_VERSION"||f=="MINIMUM_OS_SPECIFIC_VERSION") typ=f
            else if (f ~ /^[0-9]+\.[0-9.]+$/) ver=f
        }
        if (idv!="") print $1 s idv s typ s ver
    }' "$from_file" | /usr/bin/sort -u
}

# -------------------------------------------------------------------------
# INSTANCE SELECTION
# -------------------------------------------------------------------------

ensure_dependencies jamf-cli jq "openpyxl?" || exit 1

trap remove_jamfcli_token EXIT

if [[ -n "$from_file" ]]; then
    # instances come from the file
    file_rows=()
    while IFS= read -r row; do
        [[ -n "$row" ]] && file_rows+=("$row")
    done < <(file_targets)
    if [[ ${#file_rows[@]} -eq 0 ]]; then
        echo "ERROR: no instance/prestage targets found in $from_file."
        exit 1
    fi
    instance_choice_array=()
    for row in "${file_rows[@]}"; do
        inst="${row%%$'\x1f'*}"
        [[ " ${instance_choice_array[*]} " == *" $inst "* ]] || instance_choice_array+=("$inst")
    done
    echo "Loaded ${#file_rows[@]} prestage target(s) on ${#instance_choice_array[@]} instance(s) from $from_file"
else
    announce_instances
    choose_destination_instances
fi
if [[ ${#instance_choice_array[@]} -eq 0 ]]; then
    echo "ERROR: no instance selected."
    exit 1
fi
if [[ ${#prestage_ids[@]} -gt 0 && ${#instance_choice_array[@]} -gt 1 ]]; then
    echo "ERROR: prestage IDs differ between instances; use --prestage-id with a single instance."
    exit 1
fi

# -------------------------------------------------------------------------
# MODE, PRESTAGES, VALUE
# -------------------------------------------------------------------------

if [[ $interactive -eq 1 ]]; then
    choose_mode
    if [[ "$mode" == "report" ]]; then
        choose_report_scope
    else
        # the prestage and version pickers read from the first instance
        token_for_instance "${instance_choice_array[0]}" || exit 1
        choose_set_scope
        choose_enforcement_type
        choose_macos_version
        choose_run_mode
    fi
fi
report_all="${report_all:-0}"
dry_run="${dry_run:-0}"

if [[ "$mode" == "set" ]]; then
    scope_desc="All prestages"
    [[ ${#prestage_ids[@]} -gt 0 ]] && scope_desc="PreStage ID(s) ${prestage_ids[*]}"
    [[ -n "$prestage_name" ]] && scope_desc="PreStage named '$prestage_name'"
    [[ -n "$prestage_keyword" ]] && scope_desc="PreStages whose name contains '$prestage_keyword'"
    [[ -n "$from_file" ]] && scope_desc="Targets in $from_file"
    [[ $only_enforced -eq 1 ]] && scope_desc="$scope_desc (only those already enforcing)"
    new_value="$(fmt_val "$target_type" "$target_version")"
    [[ $use_file_values -eq 1 ]] && new_value="Per row, from the file"

    echo
    echo "   Mode:      set"
    echo "   PreStages: $scope_desc"
    echo "   Instances: ${#instance_choice_array[@]}"
    echo "   New value: $new_value"
    [[ "$dry_run" -eq 1 ]] && echo "   Dry-run:   nothing will be written"

    if [[ "$dry_run" -ne 1 && $interactive -eq 1 ]]; then
        echo
        confirm "Apply these changes?" || { echo "Cancelled."; exit 0; }
    fi
fi

# -------------------------------------------------------------------------
# OUTPUT
# -------------------------------------------------------------------------

choose_output_dir || exit 1
timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
if [[ ${#instance_choice_array[@]} -eq 1 ]]; then
    output_label=$(url_host "${instance_choice_array[0]}")
elif [[ -n "$from_file" ]]; then
    output_label="$(/usr/bin/basename "${from_file%.*}")-${#instance_choice_array[@]}-instances"
else
    output_label="$(/usr/bin/basename "${instance_list_file%.txt}")-${#instance_choice_array[@]}-instances"
fi
output_mode="$mode"
[[ "$mode" == "set" && "$dry_run" -eq 1 ]] && output_mode="set-preview"
csv_file="${output_dir}/set-prestage-os-version_${output_mode}_${output_label}_${timestamp}.csv"
xlsx_file="${csv_file%.csv}.xlsx"

success_count=0
fail_count=0
skip_count=0
dryrun_count=0
report_count=0
enforced_count=0

if [[ "$mode" == "report" ]]; then
    echo "Instance,PreStage,ID,EnforcementType,SpecificVersion,URL" > "$csv_file"
    for jss_instance in "${instance_choice_array[@]}"; do
        echo
        echo "$jss_instance"
        if ! token_for_instance "$jss_instance"; then
            echo "   Could not get a token. Skipping."
            continue
        fi
        instance_start_count=$report_count
        report_instance
        remove_jamfcli_token
    done
    final_output=$(csv_to_xlsx "$csv_file" "$xlsx_file" "PreStage Min OS" 6)
    echo
    if [[ "$report_all" -eq 1 ]]; then
        echo "   $report_count prestage(s), $enforced_count enforcing a minimum macOS version."
    else
        echo "   $enforced_count prestage(s) enforcing a minimum macOS version."
    fi
else
    echo "Instance,PreStage,ID,Before,After,Result,URL" > "$csv_file"
    for jss_instance in "${instance_choice_array[@]}"; do
        echo
        echo "$jss_instance"
        if ! token_for_instance "$jss_instance"; then
            echo "   Could not get a token. Skipping."
            (( fail_count++ ))
            continue
        fi

        if [[ -n "$from_file" ]]; then
            for row in "${file_rows[@]}"; do
                IFS=$'\x1f' read -r inst pid rtype rversion <<< "$row"
                [[ "$inst" == "$jss_instance" ]] || continue
                if [[ $use_file_values -eq 1 ]]; then
                    if [[ -z "$rtype" || ( "$rtype" == "MINIMUM_OS_SPECIFIC_VERSION" && -z "$rversion" ) ]]; then
                        write_set_row "$pid" "ID $pid" "-" "-" "No type/version in file"
                        (( fail_count++ ))
                        continue
                    fi
                    target_type="$rtype"
                    target_version="$rversion"
                fi
                process_prestage "$pid"
            done
        else
            ids=()
            while IFS= read -r pid; do
                [[ -n "$pid" ]] && ids+=("$pid")
            done < <(prestage_ids_for_instance)
            if [[ ${#ids[@]} -eq 0 ]]; then
                echo "   No matching prestages."
            fi
            for pid in "${ids[@]}"; do
                process_prestage "$pid"
            done
        fi
        remove_jamfcli_token
    done
    final_output=$(csv_to_xlsx "$csv_file" "$xlsx_file" "PreStage Min OS Update" 7)
    echo
    if [[ "$dry_run" -eq 1 ]]; then
        echo "   Dry-run: $dryrun_count would change   Skipped: $skip_count   Errors: $fail_count"
    else
        echo "   Success: $success_count   Failed: $fail_count   Skipped: $skip_count"
    fi
fi

echo
echo "Report written to:"
echo "   $final_output"
echo
