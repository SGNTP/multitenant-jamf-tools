#!/bin/bash

# --------------------------------------------------------------------------------
# Report macOS device attribution across one or more Jamf Pro instances.
#
# For each matched Mac, derives the most likely owner from signals already in the
# Jamf Pro inventory record - MDM-capable accounts, FileVault-enabled accounts,
# and the largest real home directory - and scores confidence High / Medium / Low
# / None. Flags devices where the assigned user disagrees with what is actually
# on the disk (Conflict = YES); those are the rows worth chasing first in a
# missing-hardware audit.
#
# Output per instance:
#   /tmp/mjt/macOS-Attribution-<instance>-<YYYY-MM-DD-HHMM>.xlsx
#   /tmp/mjt/macOS-Attribution-<instance>-<YYYY-MM-DD-HHMM>_devices.csv
#
# What this tool explicitly does NOT produce (see the "Not Obtainable" sheet):
#   - Login timestamps or login history  (Jamf Pro does not retain them)
#   - IP address history                 (only the current IP is stored)
#
# PRIVILEGES: the Keychain account needs read on Computers (inventory + history).
# GET requests only - nothing is written to any Jamf Pro instance.
# --------------------------------------------------------------------------------
#
# CHANGE LOG
# 1.0 - Initial release. Inventory pull via Jamf Pro API v1 computers-inventory
#       (6 sections). Attribution scoring: MDM-capable (S2), FileVault (S3),
#       largest home directory (S4), assigned user (S1). Classic API UserLocation
#       history per matched device (--history). Excel + CSV output.
# --------------------------------------------------------------------------------

# set instance list type
instance_list_type="mac"

# defaults
filter_model=""
filter_chip=""
enrolled_from=""
enrolled_to=""
date_basis="enrollment"    # enrollment | initial-entry
do_history=1
output_dir=""
probe=0
dry_run=0
assume_yes=0
no_interaction=0

workdir=""
returncode=0

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

DIR=$(/usr/bin/dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

if ! /usr/bin/python3 --version &>/dev/null; then
    echo "ERROR: python3 not found."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    /bin/cat <<'USAGE'

report-macos-attribution.sh - macOS device attribution report

Fetches Jamf Pro inventory and scores each Mac with an inferred owner (High /
Medium / Low / None confidence) based on MDM-capable accounts, FileVault users,
and home directory size. Flags devices where the Jamf-assigned user disagrees
with what is on the disk.

Filters (prompt interactively when omitted):
  --model STRING          Model substring to match, e.g. "MacBook Air"
  --chip STRING           Processor substring, e.g. "Apple" or "M3"
  --enrolled-from DATE    ISO date lower bound, e.g. 2025-04-01
  --enrolled-to DATE      ISO date upper bound, e.g. 2025-04-30
  --date-basis BASIS      enrollment (default) | initial-entry

History:
  --history               Fetch Classic API user-location history (default)
  --no-history            Skip history (faster; User History sheet will be empty)

Output:
  -o | --output-dir DIR   Directory for output files (prompts /tmp or ~/Desktop
                          if omitted; /tmp with -x). --out is an alias.

Instances:
  -il | --instance-list FILENAME
  -i  | --instance JSS_URL
  -a  | --all
  --user | --client-id CLIENT_ID

Probe / debug:
  --probe                 Fetch one device with all sections and dump JSON; exit

Other:
  -n | --dry-run          Show what would run; write nothing
  -v | --verbose          Verbose curl output
  -h | --help             This help

USAGE
}

# Interactive prompt with a default. $1=prompt $2=outvar $3=default
ask() {
    local prompt="$1" outvar="$2" default="$3" ans
    [[ "$assume_yes" -eq 1 ]] && { printf -v "$outvar" '%s' "$default"; return; }
    [[ ! -t 0 ]] && { printf -v "$outvar" '%s' "$default"; return; }
    if [[ -n "$default" ]]; then
        read -r -p "  ${prompt} [${default}]: " ans
        printf -v "$outvar" '%s' "${ans:-$default}"
    else
        read -r -p "  ${prompt}: " ans
        printf -v "$outvar" '%s' "${ans}"
    fi
}

# Probe: fetch one device record with all sections and dump JSON, then exit.
run_probe() {
    section "Probe - raw inventory record (1 device)"
    jss_url="$jss_instance"
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
    else
        set_credentials "$jss_instance"
    fi
    check_token

    local sections="section=GENERAL&section=HARDWARE&section=USER_AND_LOCATION"
    sections="${sections}&section=LOCAL_USER_ACCOUNTS&section=DISK_ENCRYPTION"
    sections="${sections}&section=OPERATING_SYSTEM"
    curl_url="${jss_url}/api/v1/computers-inventory?${sections}&page=0&page-size=1&sort=id:asc"
    curl_args=("--request" "GET" "--header" "Accept: application/json")
    send_curl_request

    echo
    echo "  Raw response (one device, all sections):"
    echo
    /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    results = d.get('results', d) if isinstance(d, dict) else d
    sample = results[0] if isinstance(results, list) and results else d
    print(json.dumps(sample, indent=2))
except Exception as e:
    print('Could not parse:', e)
    import pathlib
    print(pathlib.Path(sys.argv[1]).read_text()[:2000])
" "$curl_output_file"

    echo
    echo "  Classic API UserLocation for device id above:"
    local dev_id
    dev_id=$(/usr/bin/python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    results = d.get('results', []) if isinstance(d, dict) else []
    print(results[0].get('id','') if results else '')
except: print('')
" "$curl_output_file" 2>/dev/null)

    if [[ -n "$dev_id" ]]; then
        curl_url="${jss_url}/JSSResource/computerhistory/id/${dev_id}/subset/UserLocation"
        curl_args=("--request" "GET" "--header" "Accept: application/json")
        send_curl_request
        /usr/bin/python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(json.dumps(d, indent=2))
except Exception as e:
    import pathlib
    print(pathlib.Path(sys.argv[1]).read_text()[:2000])
" "$curl_output_file"
    fi
    echo
}

# Fetch all inventory pages for the current $jss_instance.
# Writes results as a JSON array to $workdir/inventory.json.
fetch_inventory() {
    local inst_slug="$1"
    local sections="section=GENERAL&section=HARDWARE&section=USER_AND_LOCATION"
    sections="${sections}&section=LOCAL_USER_ACCOUNTS&section=DISK_ENCRYPTION"
    sections="${sections}&section=OPERATING_SYSTEM"
    local inv_file="$workdir/inventory.json"
    local jsonl_file="$workdir/inventory.jsonl"
    : > "$jsonl_file"

    jss_url="$jss_instance"
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
    else
        set_credentials "$jss_instance"
    fi
    check_token

    # First page - also gets totalCount
    curl_url="${jss_url}/api/v1/computers-inventory?${sections}&page=0&page-size=200&sort=id:asc"
    curl_args=("--request" "GET" "--header" "Accept: application/json")
    send_curl_request

    local total_count
    total_count=$(/usr/bin/python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    results = d.get('results', [])
    for r in results:
        print(__import__('json').dumps(r))
    print(d.get('totalCount', len(results)), file=__import__('sys').stderr)
except Exception as e:
    print(0, file=__import__('sys').stderr)
" "$curl_output_file" >> "$jsonl_file" 2>"$workdir/tc.txt")
    total_count=$(/bin/cat "$workdir/tc.txt" 2>/dev/null || echo 0)
    echo "  Total devices in instance: ${total_count}"

    local fetched=200
    local page=1
    while [[ $fetched -lt $total_count ]]; do
        curl_url="${jss_url}/api/v1/computers-inventory?${sections}&page=${page}&page-size=200&sort=id:asc"
        curl_args=("--request" "GET" "--header" "Accept: application/json")
        send_curl_request

        local count_this
        count_this=$(/usr/bin/python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    results = d.get('results', [])
    for r in results:
        print(__import__('json').dumps(r))
    print(len(results), file=__import__('sys').stderr)
except: print(0, file=__import__('sys').stderr)
" "$curl_output_file" >> "$jsonl_file" 2>"$workdir/ct.txt")
        count_this=$(/bin/cat "$workdir/ct.txt" 2>/dev/null || echo 0)
        fetched=$(( fetched + count_this ))
        page=$(( page + 1 ))
        printf '\r  Fetched %d / %d...' "$fetched" "$total_count"
    done
    printf '\r  Fetched %d devices.          \n' "$total_count"

    # Consolidate JSONL -> JSON array
    /usr/bin/python3 -c "
import sys, json
records = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            try: records.append(json.loads(line))
            except: pass
with open(sys.argv[2], 'w') as out:
    json.dump({'results': records}, out)
" "$jsonl_file" "$inv_file"
    echo "  Inventory written to: ${inv_file}"
}

# Fetch Classic API UserLocation history for each device in matched_ids.
# Writes a JSON object {device_id: [entries,...]} to $workdir/history.json.
fetch_history() {
    local hist_file="$workdir/history.json"
    local matched_ids_file="$1"
    local total
    total=$(/usr/bin/wc -l < "$matched_ids_file" | /usr/bin/tr -d ' ')

    echo "  Fetching user-location history for ${total} matched device(s)..."

    local hist_tmp="$workdir/hist_tmp.txt"
    echo "{" > "$hist_tmp"
    local first=1
    local n=0
    while IFS= read -r dev_id; do
        [[ -z "$dev_id" ]] && continue
        n=$(( n + 1 ))
        curl_url="${jss_url}/JSSResource/computerhistory/id/${dev_id}/subset/UserLocation"
        curl_args=("--request" "GET" "--header" "Accept: application/json")
        send_curl_request

        local entries
        entries=$(/usr/bin/python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    # Classic API: computer_history.user_location[]
    ch = d.get('computer_history', d) if isinstance(d, dict) else {}
    ul = ch.get('user_location', []) if isinstance(ch, dict) else []
    if not isinstance(ul, list): ul = []
    print(json.dumps(ul))
except Exception as e:
    print('[]')
" "$curl_output_file" 2>/dev/null)

        if [[ $first -eq 1 ]]; then
            printf '"%s": %s' "$dev_id" "${entries:-[]}" >> "$hist_tmp"
            first=0
        else
            printf ', "%s": %s' "$dev_id" "${entries:-[]}" >> "$hist_tmp"
        fi
        printf '\r  History: %d / %d...' "$n" "$total"
        # gentle rate limit
        [[ $(( n % 10 )) -eq 0 ]] && /bin/sleep 0.2
    done < "$matched_ids_file"
    echo "}" >> "$hist_tmp"
    mv "$hist_tmp" "$hist_file"
    printf '\r  History fetched (%d devices).       \n' "$n"
}

# Write the Python scorer/reporter script to $workdir/score.py
write_scorer() {
    /bin/cat > "$workdir/score.py" << 'PYEOF'
"""
macOS Attribution Report scorer and Excel/CSV writer.

argv[1] = inventory JSON file   {"results": [...]}
argv[2] = history JSON file     {device_id_str: [user_location_entries]}  (or {})
argv[3] = output XLSX path
argv[4] = output CSV path
argv[5] = filter/run-info JSON  {model_filter, chip_filter, enrolled_from,
                                  enrolled_to, date_basis, instance, operator,
                                  run_ts, requested_by}
"""
import sys, os, json, csv, re
from datetime import datetime, timezone
from collections import Counter

inv_file, hist_file, xlsx_path, csv_path, run_info_json = sys.argv[1:6]

try:
    inventory_raw = json.load(open(inv_file))
except Exception as e:
    sys.exit(f"ERROR reading inventory: {e}")

records = inventory_raw.get("results", []) if isinstance(inventory_raw, dict) else inventory_raw

try:
    history_map = json.load(open(hist_file))
except Exception:
    history_map = {}

try:
    run_info = json.loads(run_info_json)
except Exception:
    run_info = {}

# ── exclusion list ────────────────────────────────────────────────────────────
EXCLUDED = {
    "root", "daemon", "nobody", "admin", "administrator", "localadmin",
    "jamfadmin", "jamfmanage", "macadmin", "itadmin", "test", "guest",
    "lapsadmin", "_mbsetupuser",
}
HOME_FLOOR_MB = 1000


def is_system(username, uid=None):
    if not username:
        return True
    if username.startswith("_"):
        return True
    if username.lower() in EXCLUDED:
        return True
    if uid is not None:
        try:
            if int(uid) < 500:
                return True
        except (TypeError, ValueError):
            pass
    return False


# ── date helpers ─────────────────────────────────────────────────────────────
def parse_iso(s):
    if not s:
        return None
    try:
        s2 = re.sub(r"\.\d+", "", str(s)).replace("Z", "+00:00")
        return datetime.fromisoformat(s2)
    except Exception:
        return None


def tz(dt):
    if dt and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def in_range(dt, lo_str, hi_str):
    if dt is None:
        return True
    dt = tz(dt)
    if lo_str:
        lo = tz(parse_iso(lo_str))
        if lo and dt < lo:
            return False
    if hi_str:
        hi = tz(parse_iso(hi_str))
        if hi and dt > hi:
            return False
    return True


def fmt_date(s):
    if not s:
        return ""
    s = str(s).strip().replace("T", " ")
    s = re.sub(r"\.\d+", "", s)
    s = re.sub(r"Z$", "", s)
    s = re.sub(r"[+-]\d{2}:?\d{2}$", "", s)
    return s[:16].strip() if len(s) >= 16 else s.strip()


# ── filter ───────────────────────────────────────────────────────────────────
model_f  = (run_info.get("model_filter") or "").lower()
chip_f   = (run_info.get("chip_filter") or "").lower()
enr_from = run_info.get("enrolled_from") or ""
enr_to   = run_info.get("enrolled_to") or ""
basis    = run_info.get("date_basis") or "enrollment"

APPLE_SILICON_KEYWORDS = {"apple", "silicon", "m1", "m2", "m3", "m4", "m5"}


def passes(rec):
    hw = rec.get("hardware") or {}
    g  = rec.get("general") or {}
    if model_f:
        m = (hw.get("model") or hw.get("modelIdentifier") or "").lower()
        if model_f not in m:
            return False
    if chip_f:
        proc = (hw.get("processorType") or "").lower()
        if chip_f not in proc:
            if chip_f in APPLE_SILICON_KEYWORDS:
                if not hw.get("appleSilicon", False):
                    return False
            else:
                return False
    raw_date = (g.get("enrollmentDate") or g.get("initialEntryDate") or "") \
               if basis == "enrollment" \
               else (g.get("initialEntryDate") or g.get("enrollmentDate") or "")
    if not in_range(parse_iso(raw_date), enr_from, enr_to):
        return False
    return True


# ── scorer ───────────────────────────────────────────────────────────────────
def score(rec):
    g  = rec.get("general") or {}
    ul = rec.get("userAndLocation") or {}
    la = rec.get("localUserAccounts") or []
    de = rec.get("diskEncryption") or {}

    s1 = (ul.get("username") or "").strip().lower()

    # S2 - MDM-capable accounts (secure token holders)
    s2 = []
    for u in ((g.get("mdmCapable") or {}).get("capableUsers") or []):
        u = (u or "").strip().lower()
        if u and not is_system(u):
            s2.append(u)

    # S3 - FileVault-enabled accounts
    s3 = []
    for u in (de.get("fileVault2EnabledUserNames") or []):
        u = (u or "").strip().lower()
        if u and not is_system(u):
            s3.append(u)

    # S4 - largest real home directory
    s4_candidates = []
    for acct in la:
        uname = (acct.get("username") or "").strip().lower()
        uid   = acct.get("uid")
        home  = acct.get("homeDirectorySizeMb") or 0
        if is_system(uname, uid):
            continue
        try:
            home = float(home)
        except (TypeError, ValueError):
            home = 0
        if home < HOME_FLOOR_MB:
            continue
        s4_candidates.append((uname, home))
    s4_candidates.sort(key=lambda x: x[1], reverse=True)
    s4 = s4_candidates[0][0] if s4_candidates else None

    # S5 - last logged-in user recorded by the Jamf binary at recon time
    s5_raw = (g.get("lastLoggedInUsernameBinary") or "").strip().lower()
    s5_ts  = fmt_date(g.get("lastLoggedInUsernameBinaryTimestamp") or "")
    s5 = s5_raw if (s5_raw and not is_system(s5_raw)) else None

    # votes
    votes = Counter()
    for u in s2: votes[u] += 1
    for u in s3: votes[u] += 1
    if s4: votes[s4] += 1
    if s5: votes[s5] += 1

    inferred = None
    if votes:
        top_n = max(votes.values())
        top   = [u for u, c in votes.items() if c == top_n]
        if len(top) == 1:
            inferred = top[0]
        elif s2:
            inferred = s2[0]
        else:
            inferred = top[0]

    # confidence
    if inferred:
        agree_count = sum(1 for u in [
            s2[0] if s2 else None,
            s3[0] if s3 else None,
            s4,
            s5,
        ] if u == inferred)
        s1_ok = (not s1) or (s1 == inferred)
        if agree_count >= 2 and s1_ok:
            conf = "High"
        elif agree_count >= 2 and not s1_ok:
            conf = "Medium"
        elif s4 == inferred and not s2 and not s3 and not s5 and s4_candidates:
            conf = "Medium"
        else:
            conf = "Low"
    else:
        conf = "None"

    conflict = bool(s1 and inferred and s1 != inferred)

    signals = []
    if s1: signals.append("S1(assigned)")
    if s2: signals.append("S2(MDM-capable)")
    if s3: signals.append("S3(FileVault)")
    if s4: signals.append("S4(home-dir)")
    if s5: signals.append("S5(last-logged-in)")

    return {
        "inferred": inferred or "",
        "confidence": conf,
        "conflict": conflict,
        "evidence": ", ".join(signals),
        "s1": s1,
        "s2_str": ", ".join(s2),
        "s3_str": ", ".join(s3),
        "s4": s4 or "",
        "s5": s5 or "",
        "s5_ts": s5_ts,
        "local_accounts": la,
    }


# ── build matched list ────────────────────────────────────────────────────────
matched = []
for rec in records:
    if not passes(rec):
        continue
    g  = rec.get("general") or {}
    dev_id = str(g.get("id") or rec.get("id") or "")
    hist = history_map.get(dev_id, [])
    matched.append((rec, score(rec), hist))

conf_dist     = Counter(s["confidence"] for _, s, _ in matched)
conflict_count = sum(1 for _, s, _ in matched if s["conflict"])

run_info["device_count"] = len(matched)

# ── CSV ───────────────────────────────────────────────────────────────────────
CSV_COLS = [
    "id", "name", "serial", "model", "processor", "os_version",
    "enrolled_date", "initial_entry_date", "last_contact", "last_ip",
    "device_record_user", "last_logged_in_user", "last_logged_in_timestamp",
    "attributed_user", "confidence", "conflict", "evidence",
]

with open(csv_path, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(CSV_COLS)
    for rec, s, _ in matched:
        g  = rec.get("general") or {}
        hw = rec.get("hardware") or {}
        os_= rec.get("operatingSystem") or {}
        w.writerow([
            str(g.get("id") or rec.get("id") or ""),
            g.get("name") or "",
            hw.get("serialNumber") or "",
            hw.get("model") or "",
            hw.get("processorType") or "",
            os_.get("version") or "",
            fmt_date(g.get("enrollmentDate") or g.get("initialEntryDate") or ""),
            fmt_date(g.get("initialEntryDate") or ""),
            fmt_date(g.get("lastContactTime") or ""),
            g.get("lastReportedIp") or g.get("lastIpAddress") or "",
            s["s1"], s["s5"], s["s5_ts"],
            s["inferred"], s["confidence"],
            "YES" if s["conflict"] else "",
            s["evidence"],
        ])

print(f"  CSV: {csv_path}")

# ── Excel ─────────────────────────────────────────────────────────────────────
try:
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.utils import get_column_letter
except ImportError:
    print("  XLSX skipped (openpyxl not installed). CSV written.")
    print(f"  Matched: {len(matched)}  Conflicts: {conflict_count}")
    sys.exit(0)

BLUE   = "1E88E5"; WHITE = "FFFFFF"; GREY = "F5F5F5"
YELLOW = "FFF9C4"; RED   = "FFEBEE"; PINK = "FCE4EC"
DARK_BLUE = "1565C0"


def fill(c):
    return PatternFill("solid", fgColor=c)


def font(bold=False, colour="000000", size=10):
    return Font(bold=bold, color=colour, size=size, name="Arial")


def thin(c="D0D0D0"):
    return Side(style="thin", color=c)


def border(c="D0D0D0"):
    s = thin(c)
    return Border(left=s, right=s, top=s, bottom=s)


def hdr_row(ws, cols, row=1):
    for ci, label in enumerate(cols, 1):
        cell = ws.cell(row=row, column=ci, value=label)
        cell.font = font(bold=True, colour=WHITE)
        cell.fill = fill(BLUE)
        cell.border = border(DARK_BLUE)
        cell.alignment = Alignment(wrap_text=True, vertical="center")
    ws.row_dimensions[row].height = 28


def autofit(ws, mn=8, mx=50):
    for col in ws.columns:
        w = max((len(str(c.value or "")) for c in col), default=mn)
        ws.column_dimensions[get_column_letter(col[0].column)].width = min(max(w + 2, mn), mx)


wb = openpyxl.Workbook()

# ── Summary ──────────────────────────────────────────────────────────────────
ws = wb.active
ws.title = "Summary"
ws.column_dimensions["A"].width = 38
ws.column_dimensions["B"].width = 55


def srow(ws, label, value, r):
    ws.cell(row=r, column=1, value=label).font = font(bold=True)
    ws.cell(row=r, column=2, value=str(value) if value is not None else "")
    ws.row_dimensions[r].height = 18


r = 1
for col in (1, 2):
    ws.cell(row=r, column=col).fill = fill(BLUE)
ws.cell(row=r, column=1, value="macOS Attribution Report").font = font(bold=True, colour=WHITE, size=14)
ws.row_dimensions[r].height = 28
r += 1

srow(ws, "Instance", run_info.get("instance", ""), r); r += 1
srow(ws, "Run timestamp", run_info.get("run_ts", ""), r); r += 1
srow(ws, "Operator", run_info.get("operator", ""), r); r += 1
srow(ws, "Model filter", run_info.get("model_filter", "(none)"), r); r += 1
srow(ws, "Chip filter", run_info.get("chip_filter", "(none)"), r); r += 1
srow(ws, "Date basis", run_info.get("date_basis", "enrollment"), r); r += 1
srow(ws, "Enrolled from", run_info.get("enrolled_from", "(none)"), r); r += 1
srow(ws, "Enrolled to", run_info.get("enrolled_to", "(none)"), r); r += 1
srow(ws, "Devices matched", run_info.get("device_count", 0), r); r += 1
r += 1
srow(ws, "High confidence", conf_dist.get("High", 0), r); r += 1
srow(ws, "Medium confidence", conf_dist.get("Medium", 0), r); r += 1
srow(ws, "Low confidence", conf_dist.get("Low", 0), r); r += 1
srow(ws, "No attributable signal", conf_dist.get("None", 0), r); r += 1
srow(ws, "Conflicts (assigned user vs disk)", conflict_count, r); r += 1
r += 1

# data handling banner
for col in (1, 2):
    ws.cell(row=r, column=col).fill = fill(PINK)
ws.cell(row=r, column=1, value="DATA HANDLING").font = font(bold=True, size=11)
ws.cell(row=r, column=2, value="Personal data - handle per UK GDPR / GDPR").font = font(size=11)
ws.row_dimensions[r].height = 22; r += 1
srow(ws, "Contains", "Usernames, real names, email, department, IP addresses", r); r += 1
srow(ws, "Requested by", run_info.get("requested_by", ""), r); r += 1
srow(ws, "Advice", "If this is a customer tenant, the customer is data controller. "
     "Ensure a documented lawful basis exists before sharing.", r); r += 1

# ── Devices ──────────────────────────────────────────────────────────────────
ws2 = wb.create_sheet("Devices")
DEV_COLS = [
    "ID", "Name", "Serial", "Model", "Processor",
    "OS Version", "Enrolled", "Initial Entry",
    "Last Contact", "Last Reported IP",
    "Device Record User", "Last Logged-in User", "Last Login Timestamp",
    "Attributed User", "Confidence", "Conflict", "Evidence",
]
hdr_row(ws2, DEV_COLS)
CONF_FILL = {"High": WHITE, "Medium": YELLOW, "Low": YELLOW, "None": RED}

for ri, (rec, s, _) in enumerate(matched, 2):
    g  = rec.get("general") or {}
    hw = rec.get("hardware") or {}
    os_= rec.get("operatingSystem") or {}
    row_fill = RED if s["conflict"] else CONF_FILL.get(s["confidence"], WHITE)
    vals = [
        str(g.get("id") or rec.get("id") or ""),
        g.get("name") or "",
        hw.get("serialNumber") or "",
        hw.get("model") or "",
        hw.get("processorType") or "",
        os_.get("version") or "",
        fmt_date(g.get("enrollmentDate") or g.get("initialEntryDate") or ""),
        fmt_date(g.get("initialEntryDate") or ""),
        fmt_date(g.get("lastContactTime") or ""),
        g.get("lastReportedIp") or g.get("lastIpAddress") or "",
        s["s1"], s["s5"], s["s5_ts"],
        s["inferred"], s["confidence"],
        "YES" if s["conflict"] else "",
        s["evidence"],
    ]
    for ci, v in enumerate(vals, 1):
        cell = ws2.cell(row=ri, column=ci, value=v)
        cell.fill = fill(row_fill)
        cell.border = border()
        cell.alignment = Alignment(vertical="center")
autofit(ws2)
ws2.freeze_panes = "A2"

# ── Local Accounts ────────────────────────────────────────────────────────────
ws3 = wb.create_sheet("Local Accounts")
ACCT_COLS = [
    "Device ID", "Device Name", "Serial",
    "Username", "Full Name", "Admin", "Type",
    "Home Dir (MB)", "FileVault Enabled", "Azure AD ID",
]
hdr_row(ws3, ACCT_COLS)
ar = 2
for rec, s, _ in matched:
    g  = rec.get("general") or {}
    hw = rec.get("hardware") or {}
    dev_id   = str(g.get("id") or rec.get("id") or "")
    dev_name = g.get("name") or ""
    serial   = hw.get("serialNumber") or ""
    for acct in (rec.get("localUserAccounts") or []):
        vals = [
            dev_id, dev_name, serial,
            acct.get("username") or "",
            acct.get("fullName") or "",
            "Yes" if acct.get("admin") else "No",
            acct.get("userAccountType") or "",
            acct.get("homeDirectorySizeMb") or "",
            "Yes" if acct.get("fileVault2Enabled") else "No",
            acct.get("azureActiveDirectoryId") or "",
        ]
        for ci, v in enumerate(vals, 1):
            cell = ws3.cell(row=ar, column=ci, value=v)
            cell.border = border()
            cell.alignment = Alignment(vertical="center")
        ar += 1
autofit(ws3)
ws3.freeze_panes = "A2"

# ── User History ─────────────────────────────────────────────────────────────
ws4 = wb.create_sheet("User History")
HIST_COLS = [
    "Device ID", "Device Name", "Serial",
    "Date", "Username", "Full Name",
    "Email", "Department", "Building", "Position",
]
hdr_row(ws4, HIST_COLS)
hr = 2
for rec, _, hist_entries in matched:
    g  = rec.get("general") or {}
    hw = rec.get("hardware") or {}
    dev_id   = str(g.get("id") or rec.get("id") or "")
    dev_name = g.get("name") or ""
    serial   = hw.get("serialNumber") or ""
    for entry in hist_entries:
        vals = [
            dev_id, dev_name, serial,
            entry.get("date_time_entered") or entry.get("dateEntered") or "",
            entry.get("username") or "",
            entry.get("full_name") or entry.get("fullName") or "",
            entry.get("email_address") or entry.get("email") or "",
            entry.get("department") or "",
            entry.get("building") or "",
            entry.get("position") or "",
        ]
        for ci, v in enumerate(vals, 1):
            cell = ws4.cell(row=hr, column=ci, value=v)
            cell.border = border()
            cell.alignment = Alignment(vertical="center")
        hr += 1
if hr == 2:
    c = ws4.cell(row=2, column=1, value="(no history entries - use --history flag or none collected)")
    c.font = font(colour="888888")
autofit(ws4)
ws4.freeze_panes = "A2"

# ── Not Obtainable ────────────────────────────────────────────────────────────
ws5 = wb.create_sheet("Not Obtainable")
ws5.column_dimensions["A"].width = 32
ws5.column_dimensions["B"].width = 72
for col, label in ((1, "Data point"), (2, "Why it does not exist in Jamf Pro")):
    c = ws5.cell(row=1, column=col, value=label)
    c.font = font(bold=True, colour=WHITE); c.fill = fill(BLUE)
    c.border = border(DARK_BLUE); c.alignment = Alignment(vertical="center")
ws5.row_dimensions[1].height = 28

NOT_OBTAINABLE = [
    ("Login timestamps",
     "Jamf Pro does not record macOS login or logout events. The Computer History "
     "'Usage Logs' subset depended on login/logout hooks, which are unsupported on "
     "modern macOS. Expect this data to be absent for all devices. To capture login "
     "events going forward, deploy Jamf Protect telemetry."),
    ("Login history (who logged in, when)",
     "No retroactive login history is available. This report uses device state "
     "(local accounts, FileVault users, MDM-capable accounts) to attribute "
     "ownership, which is the best available substitute from inventory data alone."),
    ("IP address history",
     "Jamf Pro stores only the most recent reported IP (lastReportedIp / "
     "lastIpAddress). No historical record of past addresses is retained. The "
     "current IP is included in the Devices sheet for reference."),
    ("Application usage history",
     "Application usage data is only available if the 'Application Usage' "
     "collection setting was enabled before the period of interest "
     "(Settings > Computer Management > Inventory Collection > Application Usage). "
     "It is not retroactive and is not included in this report."),
    ("Real-time location / network path",
     "Jamf Pro holds no current or historical network location data beyond the "
     "last-reported IP. Physical location must be inferred from assigned user, "
     "department, and building fields - all editable manually and not verified."),
]
for ri, (point, reason) in enumerate(NOT_OBTAINABLE, 2):
    ws5.cell(row=ri, column=1, value=point).font = font(bold=True)
    c = ws5.cell(row=ri, column=2, value=reason)
    c.alignment = Alignment(wrap_text=True, vertical="top")
    ws5.row_dimensions[ri].height = 70
    for col in (1, 2):
        ws5.cell(row=ri, column=col).border = border()

wb.save(xlsx_path)

print(f"  XLSX: {xlsx_path}")
print(f"  Matched: {len(matched)}  "
      f"High={conf_dist.get('High',0)}  "
      f"Medium={conf_dist.get('Medium',0)}  "
      f"Low={conf_dist.get('Low',0)}  "
      f"None={conf_dist.get('None',0)}  "
      f"Conflicts={conflict_count}")
PYEOF
}

# Run the scorer against the current instance's inventory + history files.
run_scorer() {
    local inst_slug="$1"
    local inv_file="$workdir/inventory.json"
    local hist_file="$workdir/history.json"

    # Get matched device IDs for history fetch
    local ids_file="$workdir/matched_ids.txt"
    local filter_json
    filter_json=$(/usr/bin/python3 -c "
import json, sys
print(json.dumps({
    'model_filter':  sys.argv[1],
    'chip_filter':   sys.argv[2],
    'enrolled_from': sys.argv[3],
    'enrolled_to':   sys.argv[4],
    'date_basis':    sys.argv[5],
    'instance':      sys.argv[6],
    'operator':      sys.argv[7],
    'run_ts':        sys.argv[8],
    'requested_by':  '',
}))
" "$filter_model" "$filter_chip" "$enrolled_from" "$enrolled_to" \
  "$date_basis" "$jss_instance" "${USER:-unknown}" \
  "$(/bin/date '+%Y-%m-%d %H:%M')" 2>/dev/null)

    # Extract matched IDs (for history fetch)
    /usr/bin/python3 -c "
import json, sys, re
from datetime import datetime, timezone

inv = json.load(open(sys.argv[1])).get('results', [])
filt = json.loads(sys.argv[2])
model_f = (filt.get('model_filter') or '').lower()
chip_f  = (filt.get('chip_filter') or '').lower()
enr_from = filt.get('enrolled_from') or ''
enr_to   = filt.get('enrolled_to') or ''
basis    = filt.get('date_basis') or 'enrollment'
APPLE_KW = {'apple','silicon','m1','m2','m3','m4','m5'}

def tz(dt):
    return dt.replace(tzinfo=timezone.utc) if dt and not dt.tzinfo else dt

def parse(s):
    if not s: return None
    try:
        return datetime.fromisoformat(re.sub(r'\.\d+','',str(s)).replace('Z','+00:00'))
    except: return None

def in_range(dt, lo, hi):
    if not dt: return True
    dt = tz(dt)
    if lo:
        lo = tz(parse(lo))
        if lo and dt < lo: return False
    if hi:
        hi = tz(parse(hi))
        if hi and dt > hi: return False
    return True

for rec in inv:
    hw = rec.get('hardware') or {}
    g  = rec.get('general') or {}
    if model_f and model_f not in (hw.get('model','') or hw.get('modelIdentifier','')).lower():
        continue
    if chip_f:
        proc = (hw.get('processorType') or '').lower()
        if chip_f not in proc:
            if chip_f in APPLE_KW and hw.get('appleSilicon'): pass
            else: continue
    raw = (g.get('enrollmentDate') or g.get('initialEntryDate') or '') if basis == 'enrollment' \
          else (g.get('initialEntryDate') or g.get('enrollmentDate') or '')
    if not in_range(parse(raw), enr_from, enr_to):
        continue
    print(str(g.get('id') or rec.get('id') or ''))
" "$inv_file" "$filter_json" > "$ids_file" 2>/dev/null

    local matched_count
    matched_count=$(/usr/bin/wc -l < "$ids_file" | /usr/bin/tr -d ' ')
    echo "  Devices matching filters: ${matched_count}"

    if [[ $matched_count -eq 0 ]]; then
        echo "  No devices matched the specified filters."
        return
    fi

    # History
    if [[ $do_history -eq 1 ]]; then
        fetch_history "$ids_file"
    else
        echo "{}" > "$workdir/history.json"
    fi

    # Output paths
    local ts
    ts=$(/bin/date '+%Y-%m-%d-%H%M')
    local base="${output_dir}/macOS-Attribution-${inst_slug}-${ts}"
    local xlsx_path="${base}.xlsx"
    local csv_path="${base}_devices.csv"

    if [[ $dry_run -eq 1 ]]; then
        echo "  (dry run) would write:"
        echo "    ${xlsx_path}"
        echo "    ${csv_path}"
        return
    fi

    "$mjt_python" "$workdir/score.py" \
        "$inv_file" \
        "$workdir/history.json" \
        "$xlsx_path" \
        "$csv_path" \
        "$filter_json"
}

# Interactive filter collection (only prompts for values not supplied by flags)
collect_filters() {
    [[ $assume_yes -eq 1 || ! -t 0 ]] && return

    section "Filters"
    echo "  Press Enter to skip any filter (no filter = all macOS devices)"
    echo

    [[ -z "$filter_model" ]]  && ask "Model substring (e.g. MacBook Air)" filter_model ""
    [[ -z "$filter_chip" ]]   && ask "Chip/processor substring (e.g. Apple, M3)" filter_chip ""
    [[ -z "$enrolled_from" ]] && ask "Enrolled from (YYYY-MM-DD, or blank)" enrolled_from ""
    [[ -z "$enrolled_to" ]]   && ask "Enrolled to   (YYYY-MM-DD, or blank)" enrolled_to ""

    if [[ -z "$enrolled_from$enrolled_to" ]]; then
        date_basis="enrollment"
    elif [[ "$date_basis" == "enrollment" || "$date_basis" == "initial-entry" ]]; then
        : # already set
    else
        ask "Date basis: enrollment or initial-entry" date_basis "enrollment"
    fi
    echo
}

# Process one instance: fetch, score, output
process_instance() {
    local inst_slug
    inst_slug=$(instance_slug "$jss_instance")

    if [[ $probe -eq 1 ]]; then
        run_probe
        return
    fi

    section "Fetching inventory: ${jss_instance}"
    fetch_inventory "$inst_slug"

    section "Scoring: ${jss_instance}"
    run_scorer "$inst_slug"

    echo
    echo "  Done: ${jss_instance}"
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        --model)             shift; filter_model="$1" ;;
        --chip)              shift; filter_chip="$1" ;;
        --enrolled-from)     shift; enrolled_from="$1" ;;
        --enrolled-to)       shift; enrolled_to="$1" ;;
        --date-basis)        shift; date_basis="$1" ;;
        --history)           do_history=1 ;;
        --no-history)        do_history=0 ;;
        -o|--output-dir|--out) shift; output_dir="$1" ;;
        --probe)             probe=1 ;;
        -il|--instance-list) shift; chosen_instance_list_file="$1" ;;
        -i|--instance)       shift; chosen_instances+=("$1") ;;
        -a|--all)            all_instances=1 ;;
        --id|--client-id|--user|--username) shift; chosen_id="$1" ;;
        -x|--nointeraction)  no_interaction=1; assume_yes=1 ;;
        -n|--dry-run)        dry_run=1 ;;
        -y|--yes)            assume_yes=1 ;;
        -v|--verbose)        verbose=1 ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

# openpyxl is optional (formatted .xlsx report, else the CSV only)
ensure_dependencies "openpyxl?"

# Working directory
workdir=$(/usr/bin/mktemp -d /tmp/report-macos-attribution-XXXXXX)
trap '/bin/rm -rf "${workdir}"' EXIT

echo
echo "macOS Attribution Report"
[[ $dry_run -eq 1 ]] && echo "(dry run - no output files will be written)"
[[ $do_history -eq 1 ]] && echo "History: on (use --no-history to skip)" || echo "History: off"
echo

announce_instances

choose_destination_instances
collect_filters
if [[ $dry_run -eq 0 && $probe -eq 0 ]]; then
    choose_output_dir || exit 1
fi
write_scorer

for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
    else
        set_credentials "$jss_instance"
    fi
    check_token || { echo "  Could not obtain token for ${jss_instance}. Skipping."; returncode=1; continue; }
    process_instance
done

echo
[[ -n "$output_dir" ]] && echo "Output directory: ${output_dir}"
echo "Finished"
echo
exit "${returncode:-0}"
