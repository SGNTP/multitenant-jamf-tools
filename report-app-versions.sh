#!/bin/bash

# Report the inventoried version(s) of any app across target computers.
# App and target devices are specified at runtime — no hardcoded lists.
#
# Target selection (pick one):
#   --serial S1 S2 ...       Explicit serial numbers
#   --name N1 N2 ...         Exact computer names
#   --name-match PATTERN     Case-insensitive partial name match (fetches all inventory)
#   --group GROUP_NAME       Smart or static computer group
#
# Usage:
#   ./report-app-versions.sh [-il LIST] [-i URL] \
#       --app "google chrome" \
#       --group "All Managed"

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
app_pattern=""
app_label=""
debug=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -il|--instance-list)  shift; chosen_instance_list_file="$1" ;;
        -i|--instance)        shift; chosen_instance="$1" ;;
        -a|--all-instances)   all_instances=1 ;;
        --id|--client-id)     shift; chosen_id="$1" ;;
        -x|--nointeraction)   no_interaction=1 ;;
        -v|--verbose)         verbose=1 ;;
        --debug)              debug=1 ;;
        --app)
            shift
            app_pattern="${1,,}"   # lowercase
            app_label="$1"
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
            echo "Usage: $0 [MJT flags] --app PATTERN [target flags]"
            echo ""
            echo "Target (pick one):"
            echo "  --serial S1 S2 ...       Explicit serial numbers"
            echo "  --name N1 N2 ...         Exact computer names"
            echo "  --name-match PATTERN     Partial name match"
            echo "  --group GROUP_NAME       Computer group (smart or static)"
            echo ""
            echo "App:"
            echo "  --app PATTERN            Substring to match against app names (case-insensitive)"
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

# Prompt for app if not supplied
if [[ -z "$app_pattern" ]]; then
    printf 'App to report on (substring match, e.g. "google chrome"): '
    read -r app_label
    app_pattern="${app_label,,}"
fi
[[ -z "$app_label" ]] && app_label="$app_pattern"

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
    # Look up serial for each exact name
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
    # Fetch all inventory and filter by partial name
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
except Exception as e:
    import traceback; traceback.print_exc()
" "$list_json" 2>/dev/null)
    echo "  Found ${#resolved_serials[@]} computer(s) matching \"$name_match_pattern\"."

elif [[ -n "$group_name" ]]; then
    # Resolve group membership via Classic API
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
csv_file="/tmp/report-app-versions_${instance_short}_${timestamp}.csv"

printf 'Serial,Computer Name,Username,%s Version,Last Check-in,Days Since Check-in\n' "$app_label" > "$csv_file"

# -------------------------------------------------------------------------
# FETCH AND PARSE
# -------------------------------------------------------------------------

# Fetch full inventory for one serial. Returns JSON or empty string.
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
echo "Querying ${#resolved_serials[@]} computer(s) on $jss_instance for \"$app_label\"..."
echo ""

for serial in "${resolved_serials[@]}"; do
    printf "  %-14s ... " "$serial"

    inv_json=$(fetch_inventory "$serial")

    if [[ -z "$inv_json" ]]; then
        echo "NOT FOUND in Jamf"
        printf '%s,NOT FOUND,,,\n' "$serial" >> "$csv_file"
        continue
    fi

    if [[ $debug -eq 1 ]]; then
        printf '%s' "$inv_json" | /usr/bin/head -c 2000
        echo
    fi

    row=$( printf '%s' "$inv_json" | J_PATTERN="$app_pattern" /usr/local/autopkg/python -c '
import sys, json, os, datetime, re

pattern = os.environ.get("J_PATTERN", "").lower()

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

general = data.get("general") or {}
name    = general.get("name") or ""

ul       = data.get("userAndLocation") or {}
username = (ul.get("username") or ul.get("realname") or "").strip()

apps     = data.get("applications") or []
versions = []
for a in apps:
    if not isinstance(a, dict):
        continue
    if pattern in str(a.get("name") or "").lower():
        v = str(a.get("version") or "").strip()
        if v and v not in versions:
            versions.append(v)
version = " / ".join(versions) if versions else "Not Installed"

last = ""
for key in ("lastContact", "lastCheckIn", "lastContactTime"):
    v = general.get(key)
    if v:
        last = str(v)
        break
last_fmt = ""
days = ""
if last:
    iso = last.replace("Z", "+00:00")
    iso = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), iso)
    try:
        dt = datetime.datetime.fromisoformat(iso)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        last_fmt = dt.strftime("%Y-%m-%d %H:%M")
        days = str((datetime.datetime.now(datetime.timezone.utc) - dt).days)
    except Exception:
        last_fmt = last
else:
    last_fmt = "Never"

def esc(s):
    s = str(s)
    if "," in s or "\"" in s or "\n" in s:
        return "\"" + s.replace("\"", "\"\"") + "\""
    return s

print("\t".join([esc(name), esc(username), esc(version), esc(last_fmt), esc(days)]))
' 2>/dev/null)

    if [[ -z "$row" ]]; then
        echo "PARSE ERROR"
        printf '%s,PARSE ERROR,,,,\n' "$serial" >> "$csv_file"
        continue
    fi

    IFS=$'\t' read -r c_name c_user c_version c_last c_days <<< "$row"

    printf '%s (%s, user: %s, last seen %s)\n' "$c_version" "$c_name" "${c_user:-unknown}" "$c_last"
    printf '%s,%s,%s,%s,%s,%s\n' "$serial" "$c_name" "$c_user" "$c_version" "$c_last" "$c_days" >> "$csv_file"
done

echo ""
echo "Done. CSV written to:"
echo "  $csv_file"
echo ""
