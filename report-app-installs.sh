#!/bin/bash

# Report which version (if any) of specific apps is installed on target macOS
# computers or iOS / iPadOS devices. Instance, platform, targets and apps are
# chosen at runtime — no hardcoded lists.
#
# Flow: instance -> platform -> targets -> apps -> output folder. Typed apps
# are looked up in the apps installed on the targets; you only choose when a
# name or bundle ID matches more than one app.
#
# Platform (menu if omitted; automatic for iOS-only instances):
#   --macos | --ios
#
# Target selection (pick one):
#   --serial S1 S2 ...       Explicit serial numbers
#   --name N1 N2 ...         Exact computer / device names
#   --name-match PATTERN     Case-insensitive partial name match (fetches all inventory)
#   --group GROUP_NAME       Smart or static computer / mobile device group
#   --all-devices            Every computer / mobile device on the instance
#
# Apps (repeatable; prompted if omitted):
#   --app PATTERN            Substring of app name or bundle ID
#   --bundle BUNDLE_ID       Exact bundle ID
#
# Usage:
#   ./report-app-installs.sh [-il LIST] [-i URL] [--macos|--ios] \
#       --app "musescore" --app "sibelius" --app "logic pro" \
#       --group "NOR Music Labs"

# include iOS-only instances in the picker; the platform is chosen afterwards
instance_list_type="ios"

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

target_mode=""
target_values=()
group_name=""
# each entry is "MODE<tab>VALUE[<tab>LABEL]", MODE = contains | exact | bundle;
# LABEL (apps picked from the list) is used as the column header
app_specs=()
exact_match=0
installed_only=""
list_apps_only=0
output_dir=""
debug=0
# above this many targets, fetch all inventory once rather than per device
bulk_fetch_threshold=20

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -il|--instance-list)  shift; chosen_instance_list_file="$1" ;;
        -i|--instance)        shift; chosen_instance="$1" ;;
        -a|--all-instances)   all_instances=1 ;;
        --id|--client-id)     shift; chosen_id="$1" ;;
        -x|--nointeraction)   no_interaction=1 ;;
        -v|--verbose)         verbose=1 ;;
        -j|--jamf-cli)        shift; jamf_cli_path="$1" ;;
        -o|--output-dir)      shift; output_dir="$1" ;;
        --app)                shift; app_specs+=("contains"$'\t'"$1") ;;
        --bundle|--bundle-id) shift; app_specs+=("bundle"$'\t'"$1") ;;
        --exact)              exact_match=1 ;;
        --installed-only)     installed_only=1 ;;
        --list-apps)          list_apps_only=1 ;;
        --debug)              debug=1 ;;
        --macos|--mac|--ios|--ipados|--mobile) parse_platform_arg "$1" ;;
        --serial|--name|--name-match|--group|--all-devices)
            parse_target_arg "$@" || exit 1
            shift "$target_args_used"
            continue
            ;;
        -h|--help)
            echo "Usage: $0 [MJT flags] [--macos|--ios] [target flags] [app flags]"
            echo ""
            print_platform_usage
            echo ""
            print_target_usage
            echo ""
            echo "Apps (repeat for multiple apps; prompted if omitted):"
            echo "  --app PATTERN            Substring of app name or bundle ID"
            echo "  --bundle BUNDLE_ID       Exact bundle ID, e.g. com.google.Chrome"
            echo "  --exact                  Make --app match a whole name or bundle ID only"
            echo "  --list-apps              List the apps installed on the targets, then exit"
            echo ""
            echo "Output:"
            echo "  --installed-only         Leave out devices that have none of the apps"
            echo "                           (asked when targeting all devices)"
            echo "  -o  | --output-dir DIR   Where to save the CSV (prompts /tmp or ~/Desktop if omitted)"
            echo "  --debug                  Keep the raw inventory JSON and print where it is"
            echo ""
            echo "MJT flags:"
            echo "  -il | --instance-list FILENAME"
            echo "  -i  | --instance URL"
            echo "  --id | --client-id CLIENT_ID"
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

if [[ $exact_match -eq 1 ]]; then
    for i in "${!app_specs[@]}"; do
        [[ "${app_specs[$i]}" == contains$'\t'* ]] && app_specs[$i]="exact${app_specs[$i]#contains}"
    done
fi

# with no one to answer the menus, everything must come from flags
if [[ "${no_interaction:-0}" -eq 1 || ! -t 0 ]]; then
    require_device_target || exit 1
    if [[ ${#app_specs[@]} -eq 0 && $list_apps_only -eq 0 ]]; then
        echo "ERROR: specify at least one --app or --bundle (or use --list-apps)."
        exit 1
    fi
fi

# -------------------------------------------------------------------------
# FUNCTIONS
# -------------------------------------------------------------------------

# Fill $records_file with one normalised device record per line (see
# normalise_device_json) for the current targets. Targets that can't be
# fetched get {"serial": ..., "missing": true} or {"serial": ..., "error": true}.
fetch_target_records() {
    local raw serial norm n=0 raw_file
    local -a sections=(GENERAL HARDWARE USER_AND_LOCATION APPLICATIONS)
    is_mobile_platform || sections+=(OPERATING_SYSTEM)
    : > "$records_file"

    case "$target_mode" in
        all|name-match)
            # one inventory call instead of one per device
            echo "   Fetching $(device_noun) inventory (this can take a minute on large fleets)..."
            raw_file="${work_dir}/inventory.json"
            fetch_inventory_list "${sections[@]}" > "$raw_file"
            normalise_device_list < "$raw_file" \
                | J_MODE="$target_mode" J_PATTERN="${target_values[0]}" /usr/bin/python3 -c '
import json, os, sys
pattern = os.environ.get("J_PATTERN", "").lower()
for line in sys.stdin:
    r = json.loads(line)
    if os.environ["J_MODE"] == "all" or pattern in r.get("name", "").lower():
        print(line.rstrip("\n"))
' > "$records_file"
            echo "   $(/usr/bin/wc -l < "$records_file" | /usr/bin/tr -d ' ') target $(device_noun)(s)."
            ;;
        *)
            resolve_target_serials
            # past a handful of devices, one bulk inventory fetch filtered to
            # the targets beats a lookup per device by a wide margin
            if [[ ${#resolved_serials[@]} -gt $bulk_fetch_threshold ]]; then
                echo "   Fetching $(device_noun) inventory for ${#resolved_serials[@]} target(s)..."
                raw_file="${work_dir}/inventory.json"
                fetch_inventory_list "${sections[@]}" > "$raw_file"
                normalise_device_list < "$raw_file" \
                    | J_SERIALS=$(printf '%s\n' "${resolved_serials[@]}") /usr/bin/python3 -c '
import json, os, sys
wanted = [s for s in os.environ.get("J_SERIALS", "").split("\n") if s]
found = {}
for line in sys.stdin:
    r = json.loads(line)
    found.setdefault(r.get("serial", "").upper(), line.rstrip("\n"))
for s in wanted:
    print(found.get(s.upper()) or json.dumps({"serial": s, "missing": True}))
' > "$records_file"
                return
            fi
            for serial in "${resolved_serials[@]}"; do
                n=$((n + 1))
                printf '\r   Fetching inventory: %d of %d' "$n" "${#resolved_serials[@]}"
                raw=$(fetch_device_by_serial "$serial" "${sections[@]}")
                if [[ -z "$raw" ]]; then
                    printf '{"serial": "%s", "missing": true}\n' "$serial" >> "$records_file"
                    continue
                fi
                [[ $debug -eq 1 ]] && printf '%s\n' "$raw" >> "${work_dir}/inventory.json"
                norm=$(printf '%s' "$raw" | normalise_device_json)
                if [[ -z "$norm" ]]; then
                    printf '{"serial": "%s", "error": true}\n' "$serial" >> "$records_file"
                else
                    printf '%s\n' "$norm" >> "$records_file"
                fi
            done
            [[ $n -gt 0 ]] && echo
            ;;
    esac
}

# List distinct apps on the fetched records into the pick_names / pick_ids /
# pick_counts arrays, narrowed by $1 (every space-separated word must appear
# in "name bundle-id", any order). Apps are grouped on bundle ID, since a
# vendor can rename an app without changing it.
build_app_list() {
    local count name id
    pick_names=(); pick_ids=(); pick_counts=()
    while IFS=$'\t' read -r count name id; do
        [[ -z "$count" ]] && continue
        [[ "$id" == "-" ]] && id=""
        pick_counts+=("$count"); pick_names+=("$name"); pick_ids+=("$id")
    done < <(J_FILTER="$1" /usr/bin/python3 - "$records_file" <<'PY'
import collections, json, os, re, sys

terms = [t for t in os.environ.get("J_FILTER", "").lower().split() if t]
bundle_re = re.compile(r"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$")
devices = collections.defaultdict(set)
names = collections.defaultdict(collections.Counter)

with open(sys.argv[1]) as fh:
    for i, line in enumerate(fh):
        r = json.loads(line)
        for a in r.get("apps") or []:
            n, b = a.get("name", ""), a.get("id", "")
            if n.lower().endswith(".app"):
                n = n[:-4]
            # some mobile devices report no bundle ID and put it in the name
            key = b or (n if bundle_re.match(n) else "name:" + n)
            if not n and not b:
                continue
            devices[key].add(i)
            if n and n != key:
                names[key][n] += 1

rows = []
for key, devs in devices.items():
    bid = "" if key.startswith("name:") else key
    name = names[key].most_common(1)[0][0] if names[key] else key.replace("name:", "", 1)
    hay = (name + " " + bid).lower()
    if all(t in hay for t in terms):
        rows.append((len(devs), name, bid))
for count, name, bid in sorted(rows, key=lambda r: r[1].lower()):
    print("%d\t%s\t%s" % (count, name.replace("\t", " "), bid or "-"))
PY
    )
}

# Ask for apps, one per line (blank line to finish), then look each one up in
# the apps installed on the targets. One match is added pinned to its bundle
# ID; several matches are listed to choose from (Enter keeps them all); no
# match is kept as typed, so its column reads Not Installed.
choose_apps() {
    local p i n selection
    local -a terms=()
    echo
    echo "Enter apps to report on by name or bundle ID, one per line."
    echo "Leave a line blank to finish."
    while true; do
        read -r -p "   App: " p || break
        [[ -z "$p" ]] && break
        terms+=("$p")
    done

    for p in "${terms[@]}"; do
        build_app_list "$p"
        case ${#pick_names[@]} in
            0)
                echo "   '$p': not installed on any target $(device_noun). Reporting it as Not Installed."
                app_specs+=("contains"$'\t'"$p")
                ;;
            1)
                add_picked_app 0
                ;;
            *)
                echo
                echo "   '$p' matches ${#pick_names[@]} apps:"
                for i in "${!pick_names[@]}"; do
                    printf '   [%d] %s (%s), %s %s(s)\n' "$((i + 1))" "${pick_names[$i]}" \
                        "${pick_ids[$i]:-no bundle ID}" "${pick_counts[$i]}" "$(device_noun)"
                done
                while true; do
                    read -r -p "   Number(s), e.g. 1,3, or Enter for all of them: " selection || selection=""
                    if [[ -z "$selection" ]]; then
                        app_specs+=("contains"$'\t'"$p")
                        break
                    fi
                    if [[ "$selection" =~ ^[0-9,\ ]+$ ]]; then
                        for n in $(printf '%s' "$selection" | /usr/bin/tr ',' ' '); do
                            if (( n >= 1 && n <= ${#pick_names[@]} )); then
                                add_picked_app $((n - 1))
                            else
                                echo "   $n is not in the list."
                            fi
                        done
                        break
                    fi
                    echo "   Not a valid option."
                done
                ;;
        esac
    done
}

# Add entry $1 of the pick_* arrays to $app_specs, pinned to its exact bundle
# ID (or exact name when it has none), labelled with its name.
add_picked_app() {
    local i="$1"
    if [[ -n "${pick_ids[$i]}" ]]; then
        app_specs+=("bundle"$'\t'"${pick_ids[$i]}"$'\t'"${pick_names[$i]}")
    else
        app_specs+=("exact"$'\t'"${pick_names[$i]}"$'\t'"${pick_names[$i]}")
    fi
}

# -------------------------------------------------------------------------
# INSTANCE SELECTION
# -------------------------------------------------------------------------

resolve_jamf_cli || exit 1

work_dir=$(/usr/bin/mktemp -d "${output_location}/report-app-installs.XXXXXX")
records_file="${work_dir}/records.ndjson"
trap 'remove_jamfcli_token; [[ $debug -eq 1 ]] || /bin/rm -rf "$work_dir"' EXIT

announce_instances
choose_single_instance || exit 1

# -------------------------------------------------------------------------
# PLATFORM, TARGETS, APPS
# -------------------------------------------------------------------------

# an instance marked iOS in the instance list has no computers to report on
if [[ -z "$device_platform" && ${#instances_list[@]} -gt 0 ]]; then
    ios_only=1
    for instance in "${instances_list[@]}"; do
        [[ "$instance" == "$jss_instance" ]] && ios_only=0 && break
    done
    if [[ $ios_only -eq 1 ]]; then
        device_platform="mobile"
        echo "   $jss_instance is an iOS instance: reporting on mobile devices."
    fi
fi
choose_device_platform || exit 1

if [[ -z "$target_mode" ]]; then
    choose_device_targets || exit 1
fi
fetch_target_records
if [[ ! -s "$records_file" ]]; then
    echo "ERROR: no target $(device_noun)s found."
    exit 1
fi

if [[ $list_apps_only -eq 1 ]]; then
    build_app_list ""
    echo
    echo "Apps installed on the target $(device_noun)s on $jss_instance (${#pick_names[@]}):"
    for i in "${!pick_names[@]}"; do
        printf '   %-50s %-45s %s\n' "${pick_names[$i]}" "${pick_ids[$i]:--}" "${pick_counts[$i]}"
    done
    exit 0
fi

[[ ${#app_specs[@]} -eq 0 ]] && { choose_apps || exit 1; }
if [[ ${#app_specs[@]} -eq 0 ]]; then
    echo "ERROR: no apps chosen."
    exit 1
fi

# a whole-fleet report is mostly "Not Installed" rows unless filtered
if [[ -z "$installed_only" ]]; then
    installed_only=0
    if [[ "$target_mode" == "all" && -t 0 && "${no_interaction:-0}" -ne 1 ]]; then
        echo
        read -r -p "Only include $(device_noun)s that have at least one of the apps? (Y/n) : " ans
        [[ ! "$ans" =~ ^[Nn] ]] && installed_only=1
    fi
fi

# -------------------------------------------------------------------------
# OUTPUT
# -------------------------------------------------------------------------

choose_output_dir || exit 1
timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
csv_file="${output_dir}/report-app-installs_$(platform_slug)_$(url_host "$jss_instance")_${timestamp}.csv"

name_col="Computer Name"; seen_col="Last Check-in"
if is_mobile_platform; then
    name_col="Device Name"; seen_col="Last Inventory Update"
fi

echo ""

# Each app column is headed with the picked app's name, or else the app
# name(s) it matched (without ".app"), falling back to what was typed.
J_SPECS=$(printf '%s\n' "${app_specs[@]}") /usr/bin/python3 - \
    "$records_file" "$csv_file" "$name_col" "$seen_col" "$installed_only" <<'PY'
import csv, json, os, sys

records_file, csv_file, name_col, seen_col, installed_only = sys.argv[1:6]
specs = []
for line in os.environ.get("J_SPECS", "").split("\n"):
    if "\t" in line:
        mode, value, label = (line.split("\t", 2) + [""])[:3]
        specs.append((mode, value, value.lower(), label))

def display_name(n):
    return n[:-4] if n.lower().endswith(".app") else n

def matches(mode, q, a):
    n, b = a.get("name", "").lower(), a.get("id", "").lower()
    if mode == "bundle":
        # some mobile devices report no bundle ID and put it in the name
        return b == q or (b == "" and n == q)
    if mode == "exact":
        return q in (n, display_name(n), b)
    return q in n or q in b

rows = []
seen_names = [[] for _ in specs]
installed_counts = [0] * len(specs)
with open(records_file) as fh:
    for line in fh:
        r = json.loads(line)
        serial = r.get("serial", "")
        if r.get("missing") or r.get("error"):
            status = "NOT FOUND" if r.get("missing") else "PARSE ERROR"
            rows.append([serial, status, "", "", "", ""] + [""] * len(specs))
            continue
        cells, any_installed = [], False
        for i, (mode, value, q, label) in enumerate(specs):
            versions, names = [], []
            for a in r.get("apps") or []:
                if matches(mode, q, a):
                    v = a.get("version", "")
                    if v and v not in versions:
                        versions.append(v)
                    n = display_name(a.get("name", "")) or a.get("id", "")
                    if n and n not in names:
                        names.append(n)
            if names:
                cell = " / ".join(versions) or "Installed"
                any_installed = True
                installed_counts[i] += 1
                for n in names:
                    if n not in seen_names[i]:
                        seen_names[i].append(n)
            else:
                cell = "Not Installed"
            cells.append(cell)
        if installed_only == "1" and not any_installed:
            continue
        rows.append([serial, r.get("name", ""), r.get("username", ""), r.get("model", ""),
                     r.get("os_version", ""), r.get("last_seen_display", "")] + cells)

headers = [label or " / ".join(s) or v for s, (m, v, q, label) in zip(seen_names, specs)]
with open(csv_file, "w", newline="") as out:
    w = csv.writer(out, lineterminator="\n")
    w.writerow(["Serial", name_col, "Username", "Model", "OS Version", seen_col] + headers)
    w.writerows(rows)

for h, c in zip(headers, installed_counts):
    print("   %s: installed on %d" % (h, c))
missing = sum(1 for r in rows if r[1] in ("NOT FOUND", "PARSE ERROR"))
if missing:
    print("   %d target(s) not found in Jamf" % missing)
PY

echo ""
echo "CSV written to:"
echo "   $csv_file"
[[ $debug -eq 1 ]] && echo "  Raw inventory kept in: $work_dir"
echo ""
