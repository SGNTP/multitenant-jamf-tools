#!/bin/bash

# Report whether specific apps are installed on target computers.
# Apps and target devices are specified at runtime — no hardcoded lists.
#
# Target selection (pick one):
#   --serial S1 S2 ...       Explicit serial numbers
#   --name N1 N2 ...         Exact computer names
#   --name-match PATTERN     Case-insensitive partial name match (fetches all inventory)
#   --group GROUP_NAME       Smart or static computer group
#
# Apps:
#   --app PATTERN            Substring to match (may be repeated for multiple apps)
#                            (interactive prompt if omitted)
#
# Usage:
#   ./report-app-installs.sh [-il LIST] [-i URL] \
#       --app "musescore" --app "sibelius" --app "logic pro" \
#       --group "NOR Music Labs"

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

target_serials=()
target_names=()
name_match_pattern=""
group_name=""
app_patterns=()

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -il|--instance-list)  shift; chosen_instance_list_file="$1" ;;
        -i|--instance)        shift; chosen_instance="$1" ;;
        -a|--all-instances)   all_instances=1 ;;
        --id|--client-id)     shift; chosen_id="$1" ;;
        -x|--nointeraction)   no_interaction=1 ;;
        -v|--verbose)         verbose=1 ;;
        --app)
            shift
            app_patterns+=("${1,,}")   # store lowercase
            ;;
        --serial)
            shift
            while [[ "$#" -gt 0 && "$1" != -* ]]; do
                target_serials+=("$1"); shift
            done
            continue
            ;;
        --name)
            shift
            while [[ "$#" -gt 0 && "$1" != -* ]]; do
                target_names+=("$1"); shift
            done
            continue
            ;;
        --name-match)  shift; name_match_pattern="$1" ;;
        --group)       shift; group_name="$1" ;;
        -h|--help)
            echo "Usage: $0 [MJT flags] --app PATTERN [--app PATTERN ...] [target flags]"
            echo ""
            echo "Target (pick one):"
            echo "  --serial S1 S2 ...       Explicit serial numbers"
            echo "  --name N1 N2 ...         Exact computer names"
            echo "  --name-match PATTERN     Partial name match"
            echo "  --group GROUP_NAME       Computer group (smart or static)"
            echo ""
            echo "Apps:"
            echo "  --app PATTERN            Substring match (repeat for multiple apps)"
            echo "                           (interactive prompt if omitted)"
            echo ""
            echo "MJT flags:"
            echo "  -il | --instance-list FILENAME"
            echo "  -i  | --instance URL"
            echo "  -a  | --all-instances"
            echo "  --id | --client-id CLIENT_ID"
            exit 0
            ;;
    esac
    shift
done

# Prompt for apps if none supplied
if [[ ${#app_patterns[@]} -eq 0 ]]; then
    echo "Enter app names to check (one per line, blank line to finish):"
    while true; do
        printf '  App pattern: '
        read -r p
        [[ -z "$p" ]] && break
        app_patterns+=("${p,,}")
    done
fi

if [[ ${#app_patterns[@]} -eq 0 ]]; then
    echo "ERROR: at least one --app pattern is required."
    exit 1
fi

# Validate: exactly one target mode must be set
target_mode_count=0
[[ ${#target_serials[@]} -gt 0 ]] && (( target_mode_count++ ))
[[ ${#target_names[@]} -gt 0 ]]   && (( target_mode_count++ ))
[[ -n "$name_match_pattern" ]]     && (( target_mode_count++ ))
[[ -n "$group_name" ]]             && (( target_mode_count++ ))

if [[ $target_mode_count -eq 0 ]]; then
    echo "ERROR: specify a target via --serial, --name, --name-match, or --group."
    exit 1
fi
if [[ $target_mode_count -gt 1 ]]; then
    echo "ERROR: only one of --serial, --name, --name-match, --group may be used at a time."
    exit 1
fi

# -------------------------------------------------------------------------
# INSTANCE SELECTION
# -------------------------------------------------------------------------

choose_destination_instances

jss_instance="${instance_choice_array[0]:-$chosen_instance}"
if [[ -z "$jss_instance" ]]; then
    echo "ERROR: no instance selected."
    exit 1
fi
if [[ ${#instance_choice_array[@]} -gt 1 ]]; then
    echo "NOTE: this report runs against one instance at a time. Using: $jss_instance"
fi

if [[ -n "$chosen_id" ]]; then
    set_credentials "$jss_instance" "$chosen_id"
else
    set_credentials "$jss_instance"
fi
check_token "$jss_instance"

token_file=$(/usr/bin/mktemp /tmp/jamfcli_token.XXXXXX)
echo "$token" > "$token_file"
trap '/bin/rm -f "$token_file"' EXIT

# -------------------------------------------------------------------------
# RESOLVE TARGET SERIALS
# -------------------------------------------------------------------------

resolved_serials=()

if [[ ${#target_serials[@]} -gt 0 ]]; then
    resolved_serials=("${target_serials[@]}")

elif [[ ${#target_names[@]} -gt 0 ]]; then
    echo "Resolving serials for ${#target_names[@]} computer name(s)..."
    for cname in "${target_names[@]}"; do
        serial=$(jamf-cli pro computer-inventory get \
            --name "$cname" \
            --section GENERAL \
            --url "$jss_instance" \
            --token-file "$token_file" \
            -o json --no-hints --no-update-check --quiet 2>/dev/null \
            | /usr/local/autopkg/python -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if isinstance(d, dict) and "results" in d:
        d = d["results"][0] if d["results"] else {}
    if isinstance(d, list):
        d = d[0] if d else {}
    print(d.get("general", {}).get("serialNumber") or "")
except Exception:
    pass
' 2>/dev/null)
        if [[ -n "$serial" ]]; then
            resolved_serials+=("$serial")
        else
            echo "  WARNING: no serial found for computer name '$cname'"
        fi
    done

elif [[ -n "$name_match_pattern" ]]; then
    echo "Fetching inventory to match names containing \"$name_match_pattern\"..."
    list_json=$(jamf-cli pro computers-inventory list \
        --all \
        --section GENERAL \
        --url "$jss_instance" \
        --token-file "$token_file" \
        -o json --no-hints --no-update-check --quiet 2>/dev/null)
    if [[ -z "$list_json" ]]; then
        echo "ERROR: failed to fetch computer inventory."
        exit 1
    fi
    mapfile -t resolved_serials < <(/usr/local/autopkg/python -c "
import sys, json
pattern = '${name_match_pattern}'.lower()
try:
    data = json.loads(sys.argv[1])
    recs = data.get('results', data) if isinstance(data, dict) else data
    if not isinstance(recs, list):
        recs = []
    for r in recs:
        if not isinstance(r, dict):
            continue
        name = (r.get('general') or {}).get('name') or ''
        if pattern in name.lower():
            serial = (r.get('general') or {}).get('serialNumber') or ''
            if serial:
                print(serial)
except Exception:
    pass
" "$list_json" 2>/dev/null)
    echo "  Found ${#resolved_serials[@]} computer(s) matching \"$name_match_pattern\"."

elif [[ -n "$group_name" ]]; then
    echo "Resolving members of group \"$group_name\"..."
    group_json=$(jamf-cli pro classic-computer-groups get \
        --name "$group_name" \
        --output json \
        --url "$jss_instance" \
        --token-file "$token_file" \
        --no-hints --no-update-check --quiet 2>/dev/null)
    if [[ -z "$group_json" ]]; then
        echo "ERROR: could not fetch group \"$group_name\"."
        exit 1
    fi
    mapfile -t resolved_serials < <(/usr/local/autopkg/python -c "
import sys, json
try:
    raw = json.loads(sys.argv[1])
    grp = raw.get('computer_group', raw) if isinstance(raw, dict) else raw
    comps = grp.get('computers', []) if isinstance(grp, dict) else []
    for c in comps:
        if isinstance(c, dict):
            s = c.get('serial_number') or ''
            if s:
                print(s)
except Exception:
    pass
" "$group_json" 2>/dev/null)
    echo "  Group has ${#resolved_serials[@]} member computer(s)."
fi

if [[ ${#resolved_serials[@]} -eq 0 ]]; then
    echo "ERROR: no target computers resolved."
    exit 1
fi

# -------------------------------------------------------------------------
# OUTPUT
# -------------------------------------------------------------------------

timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
instance_short="${jss_instance#*://}"
instance_short="${instance_short%%/*}"
csv_file="/tmp/report-app-installs_${instance_short}_${timestamp}.csv"

# Header: Serial, Computer Name, Username, one column per app
{
    printf 'Serial,Computer Name,Username'
    for p in "${app_patterns[@]}"; do
        printf ',%s' "$p"
    done
    printf '\n'
} > "$csv_file"

# -------------------------------------------------------------------------
# FETCH AND PARSE
# -------------------------------------------------------------------------

fetch_inventory() {
    local serial="$1" upper out variant
    upper=$(printf '%s' "$serial" | /usr/bin/tr 'a-z' 'A-Z')
    for variant in "$upper" "$serial"; do
        out=$(jamf-cli pro computer-inventory get \
            --serial "$variant" \
            --section GENERAL \
            --section APPLICATIONS \
            --section USER_AND_LOCATION \
            --url "$jss_instance" \
            --token-file "$token_file" \
            -o json --no-hints --no-update-check --quiet 2>/dev/null)
        if [[ -n "$out" && "$out" != "null" ]] \
            && ! printf '%s' "$out" | /usr/bin/grep -q '"exitCode"'; then
            printf '%s' "$out"
            return 0
        fi
        [[ "$upper" == "$serial" ]] && break
    done
    return 1
}

echo ""
echo "Querying ${#resolved_serials[@]} computer(s) on $jss_instance..."
echo ""

for serial in "${resolved_serials[@]}"; do
    printf "  %-14s ... " "$serial"

    inv_json=$(fetch_inventory "$serial")

    if [[ -z "$inv_json" ]]; then
        echo "NOT FOUND in Jamf"
        printf '%s,NOT FOUND,' "$serial" >> "$csv_file"
        for p in "${app_patterns[@]}"; do
            printf ',NOT FOUND' >> "$csv_file"
        done
        printf '\n' >> "$csv_file"
        continue
    fi

    # Build a JSON array of patterns and pass to Python in one call
    patterns_json=$(printf '%s\n' "${app_patterns[@]}" | /usr/local/autopkg/python -c '
import sys, json
lines = [l.rstrip() for l in sys.stdin]
print(json.dumps(lines))
')

    row=$(printf '%s' "$inv_json" | PATTERNS="$patterns_json" /usr/local/autopkg/python -c '
import sys, json, os

patterns = json.loads(os.environ.get("PATTERNS", "[]"))

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

if isinstance(data, dict) and isinstance(data.get("results"), list):
    data = data["results"][0] if data["results"] else {}
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    sys.exit(1)

general  = data.get("general") or {}
name     = general.get("name") or ""
ul       = data.get("userAndLocation") or {}
username = (ul.get("username") or ul.get("realname") or "").strip()
apps     = data.get("applications") or []
app_names_lower = [str(a.get("name") or "").lower() for a in apps if isinstance(a, dict)]

results = []
for p in patterns:
    installed = any(p in n for n in app_names_lower)
    results.append("Installed" if installed else "Not Installed")

def esc(s):
    s = str(s)
    if "," in s or "\"" in s or "\n" in s:
        return "\"" + s.replace("\"", "\"\"") + "\""
    return s

parts = [esc(name), esc(username)] + [esc(r) for r in results]
print("\t".join(parts))
' 2>/dev/null)

    if [[ -z "$row" ]]; then
        echo "PARSE ERROR"
        printf '%s,PARSE ERROR,' "$serial" >> "$csv_file"
        for p in "${app_patterns[@]}"; do
            printf ',' >> "$csv_file"
        done
        printf '\n' >> "$csv_file"
        continue
    fi

    IFS=$'\t' read -r -a fields <<< "$row"
    c_name="${fields[0]}"
    c_user="${fields[1]}"
    statuses=("${fields[@]:2}")

    summary=""
    for s in "${statuses[@]}"; do
        [[ -n "$summary" ]] && summary+=" | "
        summary+="$s"
    done
    printf '%s (%s, user: %s)\n' "$summary" "$c_name" "${c_user:-unknown}"

    printf '%s,%s,%s' "$serial" "$c_name" "$c_user" >> "$csv_file"
    for s in "${statuses[@]}"; do
        printf ',%s' "$s" >> "$csv_file"
    done
    printf '\n' >> "$csv_file"
done

echo ""
echo "Done. CSV written to:"
echo "  $csv_file"
echo ""
