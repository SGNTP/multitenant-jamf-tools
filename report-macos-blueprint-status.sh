#!/bin/bash

# --------------------------------------------------------------------------------
# Reports Jamf Pro blueprint / Declarative Device Management (DDM) status across
# the Macs in a Jamf Pro computer group, for one or more Jamf Pro instances.
#
# Read-only: this script fetches inventory and per-device DDM state and writes a
# CSV; it does not change anything in Jamf Pro.
#
# This is the multitenant-jamf-tools port of the JamfCLIToolkit
# macos-blueprint-status.command. It sources _common-framework.sh for
# instance-list selection and Keychain-backed authentication, and bridges to
# jamf-cli by feeding it an MJT-minted bearer token (jc() below), the same
# pattern used by configure-macos-laps.sh and set-prestage-os-version.sh.
#
# Uses ONLY the standard Jamf Pro API via jamf-cli: no platform gateway auth
# required. The per-device DDM call
#   jamf-cli pro ddm-status status-items <managementId>
# is a normal Pro API call.
#
# Flow (per instance):
#   1. Resolve the group's member computers (classic-computer-groups get --name)
#   2. Map members to Management IDs         (computers-inventory GENERAL + OS)
#   3. Pull the per-device DDM status report (ddm-status status-items <mgmtId>)
#   4. Either:
#        - Per-blueprint pivot: one row per device, presence + likely cause,
#          Absent / Failed / Pending / Mixed / Deployed / DDM off; OR
#        - Per-declaration report: one row per declaration across all devices.
#
# Per-instance CSVs (multi-instance runs don't clobber each other) are written
# to <dir>/<host>-<yyyymmdd-HHMMSS>-<mode>.csv, where <dir> is /tmp or ~/Desktop
# (chosen at run time) or --output-dir DIR.
# --------------------------------------------------------------------------------

# set instance list type (Computers = mac)
instance_list_type="mac"

# defaults
group_name=""               # -classic-computer-groups get --name
blueprint_id=""             # when set, per-device pivot mode
include_all=0               # 1 = include non-blueprint declarations too
output_dir=""               # per-instance CSV goes under here
stale_days=3                # "stale" threshold for Likely Cause hint
dry_run=0
assume_yes=0
interactive_pick=1          # 1 = pick blueprint after status pull (default in TTY)

# workspace
workdir=""
returncode=0

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

DIR=$(/usr/bin/dirname "$0")
# shellcheck source=_common-framework.sh
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

resolve_jamf_cli || exit 1

if [[ ! -x /usr/bin/python3 ]]; then
    echo "ERROR: /usr/bin/python3 not found (install the Xcode Command Line Tools)."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    /bin/cat <<'USAGE'
Report Jamf Pro blueprint / DDM status across the Macs in a group, on one or
more Jamf Pro instances.

Run with no flags interactively for a guided walk-through. Flags below skip
the prompts and are intended for automation.

Report options:
--group "NAME"                 - Jamf Pro computer group (exact name, required)
--blueprint-id UUID            - Per-device view for ONE blueprint
--include-all-declarations     - Include non-blueprint declarations in the
                                 per-declaration report (ignored if
                                 --blueprint-id is set)
-o | --output-dir DIR          - Per-instance CSVs written here (prompts
                                 /tmp or ~/Desktop if omitted; /tmp with -x)
--stale-days N                 - Days without contact before we call a device
                                 "stale" in the Likely Cause hint (default 3)

Instances:
-il | --instance-list FILENAME - instance-list filename (without .txt)
-i  | --instance JSS_URL       - a single instance (repeatable)
-a  | --all                    - all instances in the list
--user | --client-id CLIENT_ID - client ID / username to use
-x  | --nointeraction          - run without interaction (implies --yes)

Other:
-n  | --dry-run                - resolve and pull, but write no CSV
-y  | --yes                    - assume yes to prompts (no interactive picker)
-v  | --verbose                - verbose jamf-cli output
-h  | --help                   - this help

Examples:
# Guided, interactive walk-through on one instance
./report-macos-blueprint-status.sh -i https://tenant.jamfcloud.com

# Per-declaration report on a specific group, unattended, single instance
./report-macos-blueprint-status.sh -i https://tenant.jamfcloud.com \
    --group "All Managed" --yes

# Per-device pivot for one blueprint across a whole list, no CSV
./report-macos-blueprint-status.sh -il my-mac-list --all \
    --group "All Managed" --blueprint-id abcdef01-2345-... --dry-run --yes
USAGE
}

# section header
section() {
    echo
    echo "=================================================================="
    echo "  ${1}"
    echo "=================================================================="
}

# Extract the lowercase host from a URL (strip scheme, path, port).
url_host() {
    local u="${1#*://}"
    u="${u%%/*}"; u="${u%%:*}"
    printf '%s' "${u}" | /usr/bin/tr 'A-Z' 'a-z'
}

# y/N confirm honouring --yes. $1 = prompt. Returns 0 for yes.
confirm() {
    [[ $assume_yes -eq 1 ]] && return 0
    local ans
    read -r -p "${1} (Y/N) : " ans
    [[ "${ans}" =~ ^[Yy] ]]
}

# Build the default per-instance CSV path for this run.
default_output_path() {
    local host="$1" mode="$2" stamp
    stamp=$(/bin/date +%Y%m%d-%H%M%S)
    echo "${output_dir}/${host}-${stamp}-${mode}.csv"
}

# --------------------------------------------------------------------------------
# PYTHON HELPERS (dropped into $workdir per run)
# --------------------------------------------------------------------------------
write_python_helpers() {
    /bin/cat > "${workdir}/aggregate.py" << 'PYEOF'
"""
Per-declaration flatten (default mode). One row per declaration across devices.

argv[1] = targets TSV (mgmtId, name, ddm, computerId, lastContactTime, osVersion, machineRole)
argv[2] = directory of per-device status JSON files, named <mgmtId>.json
argv[3] = output CSV path ("" for dry-run)
argv[4] = "all" to include every declaration, else only Blueprint_* declarations
"""
import sys, json, os, re, csv
from collections import Counter

targets_path, status_dir, out_path, mode = sys.argv[1:5]
include_all = (mode == "all")

BLUEPRINT_RE = re.compile(r'Blueprint_([0-9a-fA-F]{8}-[0-9a-fA-F-]{27,})')
VALID_MAP = {"valid": "Installed", "unknown": "Pending", "failure": "Failed"}


def load_status_items(obj):
    if isinstance(obj, list):
        return [x for x in obj if isinstance(x, dict)]
    if isinstance(obj, dict):
        for k in ("results", "statusItems", "status_items", "items"):
            v = obj.get(k)
            if isinstance(v, list):
                return [x for x in v if isinstance(x, dict)]
        if "key" in obj or "value" in obj:
            return [obj]
    return []


def parse_kv_blob(s):
    out = []
    for chunk in re.findall(r'\{([^{}]*)\}', s):
        d = {}
        for pair in chunk.split(','):
            if '=' in pair:
                k, _, v = pair.partition('=')
                d[k.strip()] = v.strip()
        if d:
            out.append(d)
    return out


def declarations_from_item(item):
    key = str(item.get("key", ""))
    val = item.get("value")
    if "declaration" not in key.lower():
        return
    entries = []
    if isinstance(val, str):
        entries = parse_kv_blob(val)
    elif isinstance(val, list):
        entries = [e for e in val if isinstance(e, dict)]
    elif isinstance(val, dict):
        entries = [val]
    for e in entries:
        ident = str(e.get("identifier") or e.get("id") or "").strip()
        valid = str(e.get("valid") or e.get("status") or "").strip().lower()
        reasons = e.get("reasons") or e.get("reason") or ""
        if isinstance(reasons, (list, dict)):
            reasons = json.dumps(reasons, ensure_ascii=False)
        yield {"identifier": ident, "valid": valid, "reasons": str(reasons).strip()}


def blueprint_id_of(identifier):
    m = BLUEPRINT_RE.search(identifier or "")
    return m.group(1) if m else ""


targets = []
with open(targets_path) as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if not parts or not parts[0]:
            continue
        mgmt = parts[0]
        name = parts[1] if len(parts) > 1 else ""
        ddm = (parts[2] if len(parts) > 2 else "").strip().lower()
        osver = parts[5] if len(parts) > 5 else ""
        role = parts[6] if len(parts) > 6 else ""
        targets.append((mgmt, name, ddm, osver, role))

rows = []
status_counts = Counter()
devices_with_failures = set()
devices_total = len(targets)
devices_no_decl = 0

for mgmt, name, ddm, osver, role in targets:
    if ddm == "false":
        rows.append([name, mgmt, osver, role, "", "", "DDM not enabled", ""])
        status_counts["DDM not enabled"] += 1
        continue

    path = os.path.join(status_dir, f"{mgmt}.json")
    items = []
    if os.path.exists(path):
        try:
            with open(path) as f:
                items = load_status_items(json.load(f))
        except (OSError, ValueError):
            items = []

    decls = []
    for it in items:
        for d in declarations_from_item(it):
            if not d["identifier"]:
                continue
            bid = blueprint_id_of(d["identifier"])
            if not include_all and not bid:
                continue
            decls.append((bid, d))

    if not decls:
        rows.append([name, mgmt, osver, role, "", "", "No declarations", ""])
        status_counts["No declarations"] += 1
        devices_no_decl += 1
        continue

    for bid, d in sorted(decls, key=lambda x: (x[0], x[1]["identifier"])):
        status = VALID_MAP.get(d["valid"], d["valid"] or "(unknown)")
        rows.append([name, mgmt, osver, role, bid, d["identifier"], status, d["reasons"]])
        status_counts[status] += 1
        if status == "Failed":
            devices_with_failures.add(mgmt)

if out_path:
    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Device Name", "Management ID", "macOS Version", "Machine Role",
                    "Blueprint ID", "Declaration", "Status", "Reasons"])
        order = {"Failed": 0, "Pending": 1, "Installed": 2}
        for r in sorted(rows, key=lambda r: (order.get(r[6], 3), r[0].lower(), r[4])):
            w.writerow(r)

summary = {
    "devices_total": devices_total,
    "devices_no_declarations": devices_no_decl,
    "devices_with_failures": len(devices_with_failures),
    "declaration_rows": sum(v for k, v in status_counts.items()
                            if k not in ("No declarations", "DDM not enabled")),
    "status_breakdown": dict(status_counts.most_common()),
}
print(json.dumps(summary))
PYEOF

    /bin/cat > "${workdir}/pivot.py" << 'PYEOF'
"""
Per-device pivot for ONE blueprint. Two modes:

  mode=suspects : print computer IDs for devices Absent / Failed / Pending /
                  Mixed (so caller fetches command history only for those).
  mode=report   : write per-device CSV and print a JSON summary.

argv[1] = targets TSV
argv[2] = status dir (per-device DDM status <mgmtId>.json)
argv[3] = command-history dir (per-device classic-computer-history <computerId>.json)
argv[4] = output CSV path ("" for dry-run / suspects mode)
argv[5] = target blueprint ID (uuid)
argv[6] = mode: "suspects" | "report"
argv[7] = stale-days threshold (int) for the Likely Cause hint
"""
import sys, json, os, re, csv
from datetime import datetime, timezone
from collections import Counter

targets_path, status_dir, cmdhist_dir, out_path, bp_id, mode = sys.argv[1:7]
stale_days = int(sys.argv[7]) if len(sys.argv) > 7 and sys.argv[7].isdigit() else 3


def parse_kv_blob(s):
    out = []
    for chunk in re.findall(r'\{([^{}]*)\}', s):
        d = {}
        for pair in chunk.split(','):
            if '=' in pair:
                k, _, v = pair.partition('=')
                d[k.strip()] = v.strip()
        if d:
            out.append(d)
    return out


def load_status_items(obj):
    if isinstance(obj, list):
        return [x for x in obj if isinstance(x, dict)]
    if isinstance(obj, dict):
        for k in ("results", "statusItems", "status_items", "items"):
            if isinstance(obj.get(k), list):
                return [x for x in obj[k] if isinstance(x, dict)]
        if "key" in obj or "value" in obj:
            return [obj]
    return []


def blueprint_decls(items, bp_id):
    found = []
    for it in items:
        if "declaration" not in str(it.get("key", "")).lower():
            continue
        val = it.get("value")
        entries = (parse_kv_blob(val) if isinstance(val, str)
                   else val if isinstance(val, list)
                   else [val] if isinstance(val, dict) else [])
        for e in entries:
            if not isinstance(e, dict):
                continue
            ident = str(e.get("identifier") or e.get("id") or "")
            if bp_id and bp_id not in ident:
                continue
            valid = str(e.get("valid") or e.get("status") or "").strip().lower()
            found.append((ident, valid))
    return found


def device_status(items, bp_id):
    decls = blueprint_decls(items, bp_id)
    if not decls:
        return "Absent"
    states = {v for _, v in decls}
    if "failure" in states:
        return "Failed"
    if states == {"valid"}:
        return "Deployed"
    if "unknown" in states:
        return "Pending"
    return "Mixed"


def count_commands(cid):
    path = os.path.join(cmdhist_dir, f"{cid}.json")
    if not cid or not os.path.exists(path):
        return None, None
    try:
        with open(path) as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return None, None
    node = raw.get('computer_history', raw) if isinstance(raw, dict) else raw
    cmds = node.get('commands') if isinstance(node, dict) else None
    if not isinstance(cmds, dict):
        return 0, 0
    def n(key):
        v = cmds.get(key)
        return len(v) if isinstance(v, list) else 0
    return n('pending'), n('failed')


def parse_dt(s):
    if not s:
        return None
    s = str(s).strip()
    if s.endswith('Z'):
        s = s[:-1] + '+00:00'
    s = re.sub(r'([+-]\d{2})(\d{2})$', r'\1:\2', s)
    try:
        dt = datetime.fromisoformat(s)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except Exception:
        if s.isdigit():
            try:
                return datetime.fromtimestamp(int(s) / 1000, tz=timezone.utc)
            except Exception:
                return None
    return None


def fmt_dt(s):
    if not s:
        return ""
    dt = parse_dt(s)
    if dt is None:
        return str(s).strip()
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M")


def days_since(s):
    dt = parse_dt(s)
    if dt is None:
        return None
    return (datetime.now(timezone.utc) - dt).total_seconds() / 86400.0


def likely_cause(status, last_contact, pending, failed):
    if status == "Deployed":
        return ""
    if status == "DDM off":
        return "Declarative management not enabled on this device"
    if status == "Failed":
        return "Declaration rejected on device - check reasons / conflicts"
    d = days_since(last_contact)
    if d is not None and d > stale_days:
        return f"Not checked in for ~{int(d)}d (stale) - force check-in"
    if failed and failed > 0:
        return f"{failed} failed command(s) blocking - clear command queue"
    if pending and pending > 0:
        return f"{pending} pending command(s) - awaiting device sync / Blank Push"
    return ("Checks in, no stuck commands - likely expired/invalid MDM profile "
            "blocking DDM; verify enrollment/MDM profile and re-enroll if needed")


targets = []
with open(targets_path) as f:
    for line in f:
        p = line.rstrip("\n").split("\t")
        if not p or not p[0]:
            continue
        targets.append({
            "mgmt": p[0],
            "name": p[1] if len(p) > 1 else "",
            "ddm":  (p[2] if len(p) > 2 else "").strip().lower(),
            "cid":  p[3] if len(p) > 3 else "",
            "last": p[4] if len(p) > 4 else "",
            "osver": p[5] if len(p) > 5 else "",
            "role": p[6] if len(p) > 6 else "",
        })

for t in targets:
    if t["ddm"] == "false":
        t["status"] = "DDM off"
        continue
    items = []
    sp = os.path.join(status_dir, f'{t["mgmt"]}.json')
    if os.path.exists(sp):
        try:
            with open(sp) as f:
                items = load_status_items(json.load(f))
        except (OSError, ValueError):
            items = []
    t["status"] = device_status(items, bp_id)

if mode == "suspects":
    for t in targets:
        if t["status"] in ("Absent", "Failed", "Pending", "Mixed"):
            if t["cid"]:
                print(t["cid"])
    sys.exit(0)

rows = []
counts = Counter()
for t in targets:
    counts[t["status"]] += 1
    pending, failed = count_commands(t["cid"])
    cause = likely_cause(t["status"], t["last"], pending, failed)
    rows.append([
        t["name"], t["mgmt"], t["osver"], t["role"], t["status"],
        fmt_dt(t["last"]),
        "" if pending is None else pending,
        "" if failed is None else failed,
        cause,
    ])

if out_path:
    order = {"Failed": 0, "Absent": 1, "Pending": 2, "Mixed": 3, "DDM off": 4, "Deployed": 5}
    def has_data(idx):
        return any(isinstance(r[idx], int) and r[idx] > 0 for r in rows)
    keep_pending = has_data(6)
    keep_failed = has_data(7)
    header = ["Device Name", "macOS Version", "Machine Role",
              "Blueprint ID", "Blueprint Status", "Last Check-In"]
    if keep_pending:
        header.append("Pending Commands")
    if keep_failed:
        header.append("Failed Commands")
    header.append("Likely Cause")

    def project(r):
        out = [r[0], r[2], r[3], bp_id, r[4], r[5]]
        if keep_pending:
            out.append(r[6])
        if keep_failed:
            out.append(r[7])
        out.append(r[8])
        return out

    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for r in sorted(rows, key=lambda r: (order.get(r[4], 9), r[0].lower())):
            w.writerow(project(r))

summary = {
    "blueprint_id": bp_id,
    "devices_total": len(targets),
    "status_breakdown": dict(counts.most_common()),
    "not_deployed": sum(v for k, v in counts.items() if k != "Deployed"),
}
print(json.dumps(summary))
PYEOF

    /bin/cat > "${workdir}/blueprint_menu.py" << 'PYEOF'
"""
Emit "count<TAB>blueprintId" lines mined from the DDM status JSON in status_dir,
sorted most-deployed first.
"""
import sys, os, json, re
from collections import Counter

status_dir = sys.argv[1]
BLUEPRINT_RE = re.compile(r'Blueprint_([0-9a-fA-F]{8}-[0-9a-fA-F-]{27,})')


def load_status_items(obj):
    if isinstance(obj, list):
        return [x for x in obj if isinstance(x, dict)]
    if isinstance(obj, dict):
        for k in ("results", "statusItems", "status_items", "items"):
            if isinstance(obj.get(k), list):
                return [x for x in obj[k] if isinstance(x, dict)]
        if "key" in obj or "value" in obj:
            return [obj]
    return []


counts = Counter()
for fn in os.listdir(status_dir) if os.path.isdir(status_dir) else []:
    if not fn.endswith(".json"):
        continue
    try:
        with open(os.path.join(status_dir, fn)) as f:
            items = load_status_items(json.load(f))
    except (OSError, ValueError):
        continue
    seen = set()
    for it in items:
        for field in (it.get("key"), it.get("value")):
            for m in BLUEPRINT_RE.finditer(str(field or "")):
                seen.add(m.group(1))
    for bid in seen:
        counts[bid] += 1

for bid, c in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
    print(f"{c}\t{bid}")
PYEOF
}

# --------------------------------------------------------------------------------
# INSTANCE PROCESSING
# --------------------------------------------------------------------------------

fetch_group_members() {
    local group_json="${inst_workdir}/group.json"
    echo "  [fetch_group_members] resolving group \"${group_name}\"..."
    if ! jc pro classic-computer-groups get --name "${group_name}" \
        --output json > "${group_json}" 2>"${inst_workdir}/group-stderr.log"; then
        :
    fi
    if [[ ! -s "${group_json}" ]]; then
        echo "  [fetch_group_members] ERROR: could not fetch group \"${group_name}\"."
        [[ -s "${inst_workdir}/group-stderr.log" ]] && /usr/bin/sed 's/^/    /' "${inst_workdir}/group-stderr.log"
        return 1
    fi

    /usr/bin/python3 -c "
import json, sys
raw = json.load(open(sys.argv[1]))
grp = raw.get('computer_group', raw) if isinstance(raw, dict) else raw
comps = grp.get('computers') if isinstance(grp, dict) else None
if not isinstance(comps, list):
    comps = []
for c in comps:
    if isinstance(c, dict) and c.get('id') not in (None, ''):
        print(c['id'])
" "${group_json}" > "${members_file}" 2>/dev/null

    local count; count=$(/usr/bin/grep -c . "${members_file}" 2>/dev/null || true); count=${count:-0}
    if [[ "${count}" -eq 0 ]]; then
        echo "  [fetch_group_members] ERROR: group resolved but has no member computers."
        return 1
    fi
    echo "  [fetch_group_members] ${count} member computer(s)."
}

fetch_inventory() {
    echo "  [fetch_inventory] fetching computer inventory (management IDs)..."
    if ! jc pro computers-inventory list \
        --all --section GENERAL --section OPERATING_SYSTEM \
        --output json > "${inventory_json}" 2>"${inst_workdir}/inv-stderr.log"; then
        :
    fi
    if [[ ! -s "${inventory_json}" ]]; then
        echo "  [fetch_inventory] ERROR: could not retrieve computer inventory."
        [[ -s "${inst_workdir}/inv-stderr.log" ]] && /usr/bin/sed 's/^/    /' "${inst_workdir}/inv-stderr.log"
        return 1
    fi

    /usr/bin/python3 -c "
import json, sys
inv = json.load(open(sys.argv[1]))
members = {line.strip() for line in open(sys.argv[2]) if line.strip()}
recs = inv.get('results') if isinstance(inv, dict) else inv
if not isinstance(recs, list):
    recs = []
def g(d, *ks):
    for k in ks:
        if isinstance(d, dict): d = d.get(k)
        else: return None
    return d
def ea_val(r, ea_name):
    name_l = ea_name.strip().lower()
    for section in ('general', 'hardware', 'operatingSystem', 'userAndLocation'):
        obj = r.get(section) if isinstance(r, dict) else None
        if not isinstance(obj, dict):
            continue
        for ea in (obj.get('extensionAttributes') or []):
            if isinstance(ea, dict) and str(ea.get('name') or '').strip().lower() == name_l:
                vals = [v for v in (ea.get('values') or []) if v not in (None, '', [])]
                if vals:
                    return str(vals[0])
    return ''
def clean(s):
    return str(s).replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')
out = []
for r in recs:
    if not isinstance(r, dict):
        continue
    cid = str(r.get('id') or '')
    if cid not in members:
        continue
    name = g(r, 'general', 'name') or r.get('name') or ''
    mgmt = g(r, 'general', 'managementId') or ''
    ddm  = g(r, 'general', 'declarativeDeviceManagementEnabled')
    ddm  = 'true' if ddm is True else ('false' if ddm is False else '')
    last = g(r, 'general', 'lastContactTime') or ''
    osver = g(r, 'operatingSystem', 'version') or ''
    role  = ea_val(r, 'Machine Role')
    out.append('\t'.join([clean(mgmt), clean(name), ddm, cid, clean(last),
                          clean(osver), clean(role)]))
sys.stdout.write('\n'.join(out) + ('\n' if out else ''))
" "${inventory_json}" "${members_file}" > "${targets_file}" 2>/dev/null

    local n; n=$(/usr/bin/grep -c . "${targets_file}" 2>/dev/null || true); n=${n:-0}
    if [[ "${n}" -eq 0 ]]; then
        echo "  [fetch_inventory] ERROR: none of the group members were found in computer inventory."
        return 1
    fi
    echo "  [fetch_inventory] matched ${n} device(s) to inventory."
}

fetch_statuses() {
    local total; total=$(/usr/bin/grep -c . "${targets_file}" 2>/dev/null || true); total=${total:-0}
    echo "  [fetch_statuses] pulling DDM status per device (${total} device(s))..."
    local n=0 mgmt name ddm compId lastContact osver role
    while IFS=$'\t' read -r mgmt name ddm compId lastContact osver role; do
        [[ -z "${mgmt}" ]] && continue
        n=$((n + 1))
        if [[ "${ddm}" == "false" ]]; then
            printf '\r\033[K    %d/%d (skipped, DDM off)' "${n}" "${total}"
            continue
        fi
        jc pro ddm-status status-items "${mgmt}" \
            --output json > "${status_dir}/${mgmt}.json" 2>/dev/null
        if (( n % 10 == 0 )); then
            printf '\r\033[K    %d/%d...' "${n}" "${total}"
        fi
    done < "${targets_file}"
    printf '\r\033[K    %d/%d done.\n' "${n}" "${total}"
}

pick_blueprint_from_statuses() {
    # Interactive picker; sets $blueprint_id (or leaves empty -> full report).
    local menu_file="${inst_workdir}/blueprint-menu.tsv"
    /usr/bin/python3 "${workdir}/blueprint_menu.py" "${status_dir}" > "${menu_file}" 2>/dev/null

    local -a ids=() cnts=()
    if [[ -s "${menu_file}" ]]; then
        local c b
        while IFS=$'\t' read -r c b; do
            [[ -z "${b}" ]] && continue
            cnts+=("${c}")
            ids+=("${b}")
        done < "${menu_file}"
    fi

    echo
    echo "  Select a blueprint (${jss_instance}):"
    echo "    Jamf Pro > Blueprints > open one; its ID is in the URL"
    echo

    local n="${#ids[@]}"
    local manual_opt=$((n + 1))
    local full_opt=$((n + 2))

    if (( n > 0 )); then
        local i
        for i in "${!ids[@]}"; do
            printf "     [%d] %s   (%s device(s))\n" \
                "$((i + 1))" "${ids[$i]}" "${cnts[$i]}"
        done
    else
        echo "     (No deployed blueprints detected on this group's devices.)"
    fi
    printf "     [%d] Type a blueprint ID by hand\n" "${manual_opt}"
    printf "     [%d] Full per-declaration report (all blueprints)\n" "${full_opt}"
    echo

    local choice
    while true; do
        read -r -p "     Choose by number: " choice
        choice="$(printf '%s' "${choice}" | /usr/bin/tr -d '[:space:]')"

        if ! [[ "${choice}" =~ ^[0-9]+$ ]]; then
            echo "     Please enter a number."
            continue
        fi

        if (( n > 0 && choice >= 1 && choice <= n )); then
            blueprint_id="${ids[$((choice - 1))]}"
            echo "     Mode: per-device view for blueprint ${blueprint_id}."
            break
        elif (( choice == manual_opt )); then
            read -r -p "     Blueprint ID: " blueprint_id
            blueprint_id="$(printf '%s' "${blueprint_id}" | /usr/bin/tr -d '[:space:]')"
            [[ -z "${blueprint_id}" ]] && { echo "     (empty - falling back to full report)"; blueprint_id=""; }
            break
        elif (( choice == full_opt )); then
            blueprint_id=""
            confirm "     Include non-blueprint declarations too?" && include_all=1
            echo "     Mode: full per-declaration report."
            break
        else
            echo "     Not a valid option."
        fi
    done
    echo
}

fetch_command_history() {
    # Pivot mode only: fetch classic-computer-history for the suspect devices.
    local suspects
    suspects=$(/usr/bin/python3 "${workdir}/pivot.py" \
        "${targets_file}" "${status_dir}" "${cmdhist_dir}" "" \
        "${blueprint_id}" "suspects" "${stale_days}" 2>/dev/null)

    local total; total=$(printf '%s\n' "${suspects}" | /usr/bin/grep -c . 2>/dev/null || true); total=${total:-0}
    if [[ "${total}" -eq 0 ]]; then
        echo "  [fetch_command_history] all devices have the blueprint deployed - skipping."
        return
    fi

    echo "  [fetch_command_history] reading command history for ${total} device(s) not fully deployed..."
    local n=0 cid
    while IFS= read -r cid; do
        [[ -z "${cid}" ]] && continue
        n=$((n + 1))
        jc pro classic-computer-history get "${cid}" \
            --output json > "${cmdhist_dir}/${cid}.json" 2>/dev/null
        printf '\r\033[K    %d/%d...' "${n}" "${total}"
    done < <(printf '%s\n' "${suspects}")
    printf '\r\033[K    %d/%d done.\n' "${n}" "${total}"
}

aggregate_and_report() {
    local out_arg=""
    [[ $dry_run -eq 0 ]] && out_arg="${output_path}"

    local summary_json
    if [[ -n "${blueprint_id}" ]]; then
        summary_json=$(/usr/bin/python3 "${workdir}/pivot.py" \
            "${targets_file}" "${status_dir}" "${cmdhist_dir}" \
            "${out_arg}" "${blueprint_id}" "report" "${stale_days}" \
            2>"${inst_workdir}/aggregate-stderr.log")
    else
        local mode_arg="blueprint"
        [[ $include_all -eq 1 ]] && mode_arg="all"
        summary_json=$(/usr/bin/python3 "${workdir}/aggregate.py" \
            "${targets_file}" "${status_dir}" "${out_arg}" "${mode_arg}" \
            2>"${inst_workdir}/aggregate-stderr.log")
    fi

    if [[ -z "${summary_json}" ]]; then
        echo "  [aggregate_and_report] ERROR: aggregator returned no summary."
        [[ -s "${inst_workdir}/aggregate-stderr.log" ]] && /usr/bin/sed 's/^/    /' "${inst_workdir}/aggregate-stderr.log"
        return 1
    fi

    echo
    if [[ -n "${blueprint_id}" ]]; then
        /usr/bin/python3 -c "
import json, sys
s = json.loads(sys.argv[1])
print(f'  Blueprint:              {s[\"blueprint_id\"]}')
print(f'  Devices in group:       {s[\"devices_total\"]}')
print(f'  Not fully deployed:     {s[\"not_deployed\"]}')
print('')
print('  Per-device status:')
bd = s.get('status_breakdown', {})
if not bd:
    print('    (none)')
else:
    for status, count in bd.items():
        print(f'    {status:20s} {count}')
" "${summary_json}"
    else
        /usr/bin/python3 -c "
import json, sys
s = json.loads(sys.argv[1])
print(f'  Devices in group:       {s[\"devices_total\"]}')
print(f'  Devices with failures:  {s[\"devices_with_failures\"]}')
print(f'  Devices, no declarations:{s[\"devices_no_declarations\"]}')
print(f'  Declaration rows:       {s[\"declaration_rows\"]}')
print('')
print('  Status breakdown:')
bd = s.get('status_breakdown', {})
if not bd:
    print('    (none)')
else:
    for status, count in bd.items():
        print(f'    {status:20s} {count}')
" "${summary_json}"
    fi

    if [[ $dry_run -eq 1 ]]; then
        echo
        echo "  (dry run - no CSV written)"
    else
        echo
        echo "  Output CSV: ${output_path}"
    fi
}

# run the full report against the current $jss_instance (token already staged)
process_instance() {
    local host; host=$(url_host "${jss_instance}")

    inst_workdir="${workdir}/${host}"
    /bin/mkdir -p "${inst_workdir}"
    inventory_json="${inst_workdir}/inventory.json"
    members_file="${inst_workdir}/members.txt"
    targets_file="${inst_workdir}/targets.tsv"
    status_dir="${inst_workdir}/status"
    cmdhist_dir="${inst_workdir}/cmdhist"
    /bin/mkdir -p "${status_dir}" "${cmdhist_dir}"

    # Reset per-instance mode state; the picker sets these when interactive.
    if [[ ${interactive_pick} -eq 1 ]]; then
        blueprint_id=""
        include_all=0
        # If --group wasn't supplied on the CLI, ask the user to pick one on
        # this instance (groups differ per tenant, so pick per-instance).
        if [[ -z "${group_name}" ]]; then
            choose_computer_group || { returncode=1; return; }
        fi
    fi

    fetch_group_members || { returncode=1; return; }
    fetch_inventory     || { returncode=1; return; }
    fetch_statuses

    if [[ ${interactive_pick} -eq 1 ]]; then
        pick_blueprint_from_statuses
    fi

    # decide output path + mode label for the filename
    local mode_label="per-declaration"
    [[ -n "${blueprint_id}" ]] && mode_label="pivot"
    output_path="$(default_output_path "${host}" "${mode_label}")"

    [[ -n "${blueprint_id}" ]] && fetch_command_history

    aggregate_and_report || { returncode=1; return; }
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        --group)                    shift; group_name="$1" ;;
        --blueprint-id)             shift; blueprint_id="$1" ;;
        --include-all-declarations) include_all=1 ;;
        -o|--output-dir)            shift; output_dir="$1" ;;
        --stale-days)               shift; stale_days="$1" ;;
        -il|--instance-list)        shift; chosen_instance_list_file="$1" ;;
        -i|--instance)              shift; chosen_instances+=("$1") ;;
        -a|-ai|--all|--all-instances) all_instances=1 ;;
        --id|--client-id|--user|--username) shift; chosen_id="$1" ;;
        -x|--nointeraction)         no_interaction=1; assume_yes=1 ;;
        -n|--dry-run)               dry_run=1 ;;
        -y|--yes)                   assume_yes=1 ;;
        -v|--verbose)               verbose=1 ;;
        -h|--help)                  usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done
echo

# non-interactive OR blueprint pre-set OR --yes -> don't pop the picker
if [[ -n "${blueprint_id}" || $assume_yes -eq 1 || $no_interaction -eq 1 || ! -t 0 ]]; then
    interactive_pick=0
fi

if [[ $dry_run -eq 0 ]]; then
    choose_output_dir || exit 1
fi

# temp working directory for per-run scratch files
workdir=$(/usr/bin/mktemp -d /tmp/report-macos-blueprint-status-XXXXXX)
trap 'remove_jamfcli_token; /bin/rm -rf "${workdir}"' EXIT

write_python_helpers

echo "This tool reports blueprint / DDM status across the instance(s) you choose."
[[ $dry_run -eq 1 ]] && echo "(dry-run: no CSV will be written)"

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be reported on
choose_destination_instances

# require --group in non-interactive mode; otherwise choose_computer_group
# will fire per-instance after the token is minted (groups are per-tenant).
if [[ -z "${group_name}" && ${interactive_pick} -eq 0 ]]; then
    echo "ERROR: --group NAME is required in non-interactive mode."
    exit 1
fi

# loop through the chosen instances
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    section "Instance: ${jss_instance}"
    if ! token_for_instance "$jss_instance"; then
        echo "  Could not obtain a token for ${jss_instance}. Skipping."
        returncode=1
        continue
    fi
    process_instance
    remove_jamfcli_token
done

echo
echo "Finished"
echo
exit "${returncode:-0}"
