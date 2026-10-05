#!/bin/bash

# Report blueprint / Declarative Device Management (DDM) status on target Macs,
# on one or more Jamf Pro instances. Read-only.
#
# Flow: instance(s) -> targets -> output folder -> per instance: fetch DDM
#       status -> blueprint -> report.
#
# Two reports:
#   Per-blueprint (pick a blueprint, or --blueprint-id): one row per device,
#     Deployed / Pending / Failed / Absent / Mixed / Inactive / DDM off, plus a likely
#     cause drawn from last check-in and the MDM command queue.
#   Per-declaration (default with no blueprint): one row per declaration per
#     device, across every blueprint.
#
# Uses only the Jamf Pro API (declarative-device-management status-items), so
# no Platform API credentials are needed. Blueprint names live in the Platform
# API, so blueprints are shown by ID (Jamf Pro > Blueprints > open one; the
# ID is in the URL).
#
# Usage:
#   ./report-macos-blueprint-status.sh -i https://tenant.jamfcloud.com \
#       --group "All Managed" --blueprint-id abcdef01-2345-...

# computers live on macOS instances
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

target_mode=""
target_values=()
group_name=""
blueprint_id=""
blueprint_id_arg=""
include_all=""
output_dir=""
stale_days=3
dry_run=0
returncode=0
device_platform="computer"

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
        -n|--dry-run)         dry_run=1 ;;
        --blueprint-id)       shift; blueprint_id_arg="$1" ;;
        --per-declaration)    blueprint_id_arg="-" ;;
        --include-all-declarations) include_all=1 ;;
        --stale-days)         shift; stale_days="$1" ;;
        --serial|--name|--name-match|--group|--all-devices)
            parse_target_arg "$@" || exit 1
            shift "$target_args_used"
            continue
            ;;
        -h|--help)
            echo "Usage: $0 [MJT flags] [target flags] [--blueprint-id UUID | --per-declaration]"
            echo ""
            print_target_usage
            echo ""
            echo "Report (menu if omitted):"
            echo "  --blueprint-id UUID      Per-device status for one blueprint"
            echo "  --per-declaration        One row per declaration, every blueprint"
            echo "  --include-all-declarations"
            echo "                           (per-declaration) include non-blueprint declarations"
            echo "  --stale-days N           Days without check-in counted as stale (default 3)"
            echo ""
            echo "Output:"
            echo "  -o  | --output-dir DIR   Where to save the report (prompts /tmp or ~/Desktop if omitted)"
            echo "  -n  | --dry-run          Print the summary only; write no report"
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

if ! [[ "$stale_days" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --stale-days needs a whole number of days."
    exit 1
fi

interactive=1
[[ "${no_interaction:-0}" -eq 1 || ! -t 0 || "${assume_yes:-0}" -eq 1 ]] && interactive=0
if [[ $interactive -eq 0 ]]; then
    require_device_target || exit 1
    # with nobody to pick a blueprint, report every declaration
    [[ -z "$blueprint_id_arg" ]] && blueprint_id_arg="-"
fi

# -------------------------------------------------------------------------
# FUNCTIONS
# -------------------------------------------------------------------------

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


# Values look like "{k=v, reasons=[{details={...}}], ...},{...}"; predicates
# inside can hold quoted braces, so split on top-level delimiters only.
def _split_top(s, sep=None):
    depth, quote, buf, out = 0, False, [], []
    for ch in s:
        if ch == '"':
            quote = not quote
        elif not quote:
            if ch in '{[':
                depth += 1
                if sep is None and depth == 1 and ch == '{':
                    buf = []
                    continue
            elif ch in '}]':
                depth -= 1
                if sep is None and depth == 0 and ch == '}':
                    out.append(''.join(buf))
                    continue
            elif sep and ch == sep and depth == 0:
                out.append(''.join(buf))
                buf = []
                continue
        buf.append(ch)
    if sep:
        out.append(''.join(buf))
    return out


def parse_kv_blob(s):
    out = []
    for body in _split_top(s or ""):
        d = {}
        for pair in _split_top(body, ','):
            k, eq, v = pair.partition('=')
            if eq:
                d[k.strip()] = v.strip()
        if d:
            out.append(d)
    return out


def summarize_reasons(raw):
    parts = []
    raw = (raw or "").strip()
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    for r in parse_kv_blob(raw):
        text = " ".join(x for x in (r.get("code", ""), r.get("description", "")) if x)
        for det in parse_kv_blob(r.get("details", "")):
            if det.get("Predicate"):
                text += f" Predicate: {det['Predicate']}"
        if text:
            parts.append(text.strip())
    return " | ".join(parts) or (raw or "").strip()


def is_declaration_key(key):
    return str(key or "").lower().startswith("management.declarations.")


def declarations_from_item(item):
    val = item.get("value")
    if not is_declaration_key(item.get("key")):
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
        active = str(e.get("active", "")).strip().lower()
        reasons = e.get("reasons") or e.get("reason") or ""
        if isinstance(reasons, (list, dict)):
            reasons = json.dumps(reasons, ensure_ascii=False)
        else:
            reasons = summarize_reasons(str(reasons))
        yield {"identifier": ident, "valid": valid, "active": active, "reasons": reasons}


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
        if d["valid"] == "failure":
            status = "Failed"
        elif d["active"] == "false" and bid:
            status = "Inactive"
        else:
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
        order = {"Failed": 0, "Pending": 1, "Inactive": 2, "Installed": 3}
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


# Values look like "{k=v, reasons=[{details={...}}], ...},{...}"; predicates
# inside can hold quoted braces, so split on top-level delimiters only.
def _split_top(s, sep=None):
    depth, quote, buf, out = 0, False, [], []
    for ch in s:
        if ch == '"':
            quote = not quote
        elif not quote:
            if ch in '{[':
                depth += 1
                if sep is None and depth == 1 and ch == '{':
                    buf = []
                    continue
            elif ch in '}]':
                depth -= 1
                if sep is None and depth == 0 and ch == '}':
                    out.append(''.join(buf))
                    continue
            elif sep and ch == sep and depth == 0:
                out.append(''.join(buf))
                buf = []
                continue
        buf.append(ch)
    if sep:
        out.append(''.join(buf))
    return out


def parse_kv_blob(s):
    out = []
    for body in _split_top(s or ""):
        d = {}
        for pair in _split_top(body, ','):
            k, eq, v = pair.partition('=')
            if eq:
                d[k.strip()] = v.strip()
        if d:
            out.append(d)
    return out


def summarize_reasons(raw):
    parts = []
    raw = (raw or "").strip()
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    for r in parse_kv_blob(raw):
        text = " ".join(x for x in (r.get("code", ""), r.get("description", "")) if x)
        for det in parse_kv_blob(r.get("details", "")):
            if det.get("Predicate"):
                text += f" Predicate: {det['Predicate']}"
        if text:
            parts.append(text.strip())
    return " | ".join(parts) or (raw or "").strip()


def is_declaration_key(key):
    return str(key or "").lower().startswith("management.declarations.")


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
        if not is_declaration_key(it.get("key")):
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
            active = str(e.get("active", "")).strip().lower()
            found.append((ident, valid, active, str(e.get("reasons") or "")))
    return found


def device_status(items, bp_id):
    decls = blueprint_decls(items, bp_id)
    if not decls:
        return "Absent", ""
    if any(v == "failure" for _, v, _, _ in decls):
        return "Failed", ""
    # inactive declarations (activation predicate not met) are not expected to apply
    live = [d for d in decls if d[2] != "false"]
    if not live:
        reason = next((summarize_reasons(r) for _, _, _, r in decls if r), "")
        return "Inactive", reason
    states = {v for _, v, _, _ in live}
    if states == {"valid"}:
        return "Deployed", ""
    if "unknown" in states:
        return "Pending", ""
    return "Mixed", ""


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
    if status == "Inactive":
        return ("Activation predicate not met on this device (blueprint targets a "
                "different OS / model / version) - not expected to apply")
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
    t["reason"] = ""
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
    t["status"], t["reason"] = device_status(items, bp_id)

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
        t["reason"],
    ])

if out_path:
    order = {"Failed": 0, "Absent": 1, "Pending": 2, "Mixed": 3, "DDM off": 4,
             "Inactive": 5, "Deployed": 6}
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
    keep_reasons = any(r[9] for r in rows)
    if keep_reasons:
        header.append("Device Reasons")

    def project(r):
        out = [r[0], r[2], r[3], bp_id, r[4], r[5]]
        if keep_pending:
            out.append(r[6])
        if keep_failed:
            out.append(r[7])
        out.append(r[8])
        if keep_reasons:
            out.append(r[9])
        return out

    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for r in sorted(rows, key=lambda r: (order.get(r[4], 9), r[0].lower())):
            w.writerow(project(r))

details_path = sys.argv[8] if len(sys.argv) > 8 else ""
if details_path:
    valid_label = {"valid": "Deployed", "invalid": "Pending", "unknown": "Pending",
                   "failure": "Failed"}
    with open(details_path, "w", newline="") as df:
        dw = csv.writer(df)
        dw.writerow(["Device Name", "Declaration", "Status",
                     "Reason Code", "Reason Description", "Predicate"])
        for t in targets:
            if t["ddm"] == "false":
                continue
            sp = os.path.join(status_dir, f'{t["mgmt"]}.json')
            if not os.path.exists(sp):
                continue
            try:
                with open(sp) as jf:
                    all_items = load_status_items(json.load(jf))
            except (OSError, ValueError):
                continue
            for it in all_items:
                if not is_declaration_key(it.get("key")):
                    continue
                val = it.get("value")
                entries = (parse_kv_blob(val) if isinstance(val, str)
                           else val if isinstance(val, list)
                           else [val] if isinstance(val, dict) else [])
                for e in entries:
                    if not isinstance(e, dict):
                        continue
                    ident = str(e.get("identifier") or e.get("id") or "")
                    if not ident or (bp_id and bp_id not in ident):
                        continue
                    v = str(e.get("valid") or e.get("status") or "").lower()
                    a = str(e.get("active", "")).lower()
                    if v == "failure":
                        slabel = "Failed"
                    elif a == "false":
                        slabel = "Inactive"
                    else:
                        slabel = valid_label.get(v, v or "Unknown")
                    reasons = e.get("reasons") or e.get("reason") or []
                    if isinstance(reasons, str):
                        reasons_list = parse_kv_blob(reasons)
                    elif isinstance(reasons, list):
                        reasons_list = [r for r in reasons if isinstance(r, dict)]
                    elif isinstance(reasons, dict):
                        reasons_list = [reasons]
                    else:
                        reasons_list = []
                    if reasons_list:
                        for r in reasons_list:
                            code = str(r.get("code") or "")
                            desc = str(r.get("description") or "")
                            pred = ""
                            det = r.get("details") or {}
                            if isinstance(det, str):
                                for d2 in parse_kv_blob(det):
                                    pred = str(d2.get("Predicate") or
                                               d2.get("predicate") or "")
                            elif isinstance(det, dict):
                                pred = str(det.get("Predicate") or
                                           det.get("predicate") or "")
                            dw.writerow([t["name"], ident, slabel,
                                         code, desc, pred])
                    else:
                        dw.writerow([t["name"], ident, slabel, "", "", ""])

summary = {
    "blueprint_id": bp_id,
    "devices_total": len(targets),
    "status_breakdown": dict(counts.most_common()),
    "not_deployed": sum(v for k, v in counts.items() if k not in ("Deployed", "Inactive")),
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

# Fill $targets_file (mgmtId, name, ddm, computerId, lastContact, osVersion,
# machineRole) for the chosen targets on the current instance.
resolve_targets() {
    local members_file="${inst_workdir}/members.txt" inventory_json="${inst_workdir}/inventory.json" n
    : > "$members_file"

    if [[ "$target_mode" == "group" ]]; then
        if ! jc pro classic-computer-groups get --name "$group_name" --output json 2>/dev/null \
            | "$jq_bin" -r '(.computer_group // .) | (.computers // [])[] | .id' > "$members_file" 2>/dev/null \
            || [[ ! -s "$members_file" ]]; then
            if [[ $interactive -eq 1 ]]; then
                echo "   Group \"$group_name\" not found or empty on $jss_instance."
                choose_computer_group || return 1
                resolve_targets
                return
            fi
            echo "   ERROR: group \"$group_name\" not found or empty."
            return 1
        fi
        echo "   Group \"$group_name\": $(/usr/bin/grep -c . "$members_file") member(s)."
    fi

    echo "   Fetching computer inventory..."
    fetch_inventory_list GENERAL HARDWARE OPERATING_SYSTEM > "$inventory_json"
    if [[ ! -s "$inventory_json" ]]; then
        echo "   ERROR: could not read computer inventory."
        return 1
    fi

    J_MODE="$target_mode" J_VALUES=$(printf '%s\n' "${target_values[@]}") /usr/bin/python3 - \
        "$inventory_json" "$members_file" > "$targets_file" 2>/dev/null <<'PY'
import json, os, sys
inv = json.load(open(sys.argv[1]))
members = {l.strip() for l in open(sys.argv[2]) if l.strip()}
mode = os.environ.get("J_MODE", "all")
values = [v.strip().lower() for v in os.environ.get("J_VALUES", "").split("\n") if v.strip()]
recs = inv.get("results") if isinstance(inv, dict) else inv
def g(d, *ks):
    for k in ks:
        d = d.get(k) if isinstance(d, dict) else None
    return d
def ea_val(r, ea_name):
    for section in ("general", "hardware", "operatingSystem", "userAndLocation"):
        for ea in (g(r, section, "extensionAttributes") or []):
            if isinstance(ea, dict) and str(ea.get("name") or "").strip().lower() == ea_name:
                vals = [v for v in (ea.get("values") or []) if v not in (None, "", [])]
                if vals:
                    return str(vals[0])
    return ""
def clean(s):
    return str(s).replace("\t", " ").replace("\n", " ").replace("\r", " ")
for r in recs if isinstance(recs, list) else []:
    if not isinstance(r, dict):
        continue
    cid = str(r.get("id") or "")
    name = g(r, "general", "name") or ""
    serial = (g(r, "hardware", "serialNumber") or "").lower()
    if mode == "group" and cid not in members:
        continue
    if mode == "serial" and serial not in values:
        continue
    if mode == "name" and name.lower() not in values:
        continue
    if mode == "name-match" and (not values or values[0] not in name.lower()):
        continue
    ddm = g(r, "general", "declarativeDeviceManagementEnabled")
    ddm = "true" if ddm is True else ("false" if ddm is False else "")
    print("\t".join([clean(g(r, "general", "managementId") or ""), clean(name), ddm, cid,
                     clean(g(r, "general", "lastContactTime") or ""),
                     clean(g(r, "operatingSystem", "version") or ""),
                     clean(ea_val(r, "machine role"))]))
PY

    n=$(/usr/bin/grep -c . "$targets_file" 2>/dev/null || true)
    if [[ "${n:-0}" -eq 0 ]]; then
        echo "   ERROR: no target computers found."
        return 1
    fi
    echo "   ${n} target computer(s)."
}

fetch_statuses() {
    local total n=0 mgmt name ddm rest
    total=$(/usr/bin/grep -c . "$targets_file")
    while IFS=$'\t' read -r mgmt name ddm rest; do
        [[ -z "$mgmt" ]] && continue
        n=$((n + 1))
        if [[ "$ddm" == "false" ]]; then
            printf '\r\033[K   Fetching DDM status: %d of %d (skipped, DDM off)' "$n" "$total"
            continue
        fi
        printf '\r\033[K   Fetching DDM status: %d of %d' "$n" "$total"
        jc pro declarative-device-management status-items "$mgmt" --output json > "${status_dir}/${mgmt}.json" 2>/dev/null
    done < "$targets_file"
    printf '\r\033[K   Fetched DDM status: %d device(s).\n' "$total"
}

# sets $blueprint_id, or leaves it empty for the per-declaration report
choose_blueprint() {
    local c b
    local -a ids=() labels=()
    while IFS=$'\t' read -r c b; do
        [[ -z "$b" ]] && continue
        ids+=("$b"); labels+=("$b   ($c computer(s))")
    done < "${inst_workdir}/blueprints.tsv"

    [[ ${#ids[@]} -eq 0 ]] && echo "   No blueprints found on the target computers."
    choose_from_menu "" "Report on (blueprints deployed to the targets on $jss_instance):" \
        "${labels[@]}" \
        "Type a blueprint ID" \
        "Every blueprint, one row per declaration" || return 1

    if [[ "$menu_choice" -le ${#ids[@]} ]]; then
        blueprint_id="${ids[$((menu_choice - 1))]}"
    elif [[ "$menu_choice" -eq $(( ${#ids[@]} + 1 )) ]]; then
        read -r -p "   Blueprint ID: " blueprint_id
        blueprint_id=$(printf '%s' "$blueprint_id" | /usr/bin/tr -d '[:space:]')
    fi
    if [[ -n "$blueprint_id" ]]; then
        local bp_url="${jss_url}/view/mfe/blueprints/${blueprint_id}"
        echo "   Blueprint URL: ${bp_url}"
        if [[ $interactive -eq 1 ]]; then
            choose_from_menu 2 "Blueprint selected — open in browser to verify first?" \
                "Yes, open in browser" \
                "No, continue" || true
            [[ "$menu_choice" -eq 1 ]] && /usr/bin/open "${bp_url}" 2>/dev/null
        fi
    fi
    if [[ -z "$blueprint_id" && -z "$include_all" ]]; then
        choose_from_menu 1 "Declarations to include:" \
            "Blueprint declarations only" \
            "All declarations (including non-blueprint)" || return 1
        include_all=0
        [[ "$menu_choice" -eq 2 ]] && include_all=1
    fi
}

# per-blueprint report only: MDM command history for devices not fully deployed
fetch_command_history() {
    local suspects total n=0 cid
    suspects=$(/usr/bin/python3 "${workdir}/pivot.py" \
        "$targets_file" "$status_dir" "$cmdhist_dir" "" \
        "$blueprint_id" "suspects" "$stale_days" 2>/dev/null)
    total=$(printf '%s\n' "$suspects" | /usr/bin/grep -c . || true)
    if [[ "${total:-0}" -eq 0 ]]; then
        echo "   No computers need a command-history check."
        return
    fi
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        n=$((n + 1))
        printf '\r   Reading command history for computers not deployed: %d of %d' "$n" "$total"
        jc pro classic-computer-history get "$cid" --output json > "${cmdhist_dir}/${cid}.json" 2>/dev/null
    done <<< "$suspects"
    echo
}

# Fetch the declaration payload JSON for every unique declaration in $blueprint_id.
# Saves ${inst_workdir}/dss-decls/<uuid>.json for each. Skipped in dry-run.
fetch_declaration_payloads() {
    local dss_dir="${inst_workdir}/dss-decls" uuid uuids total
    /bin/mkdir -p "$dss_dir"
    uuids=$(/usr/bin/python3 - "$status_dir" "$blueprint_id" 2>/dev/null <<'PY'
import sys, os, json, re
status_dir, bp_id = sys.argv[1], sys.argv[2]
UUID_RE = re.compile(
    r'_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
    re.I)
seen = set()
for fn in (os.listdir(status_dir) if os.path.isdir(status_dir) else []):
    if not fn.endswith('.json'):
        continue
    try:
        with open(os.path.join(status_dir, fn)) as f:
            obj = json.load(f)
    except (OSError, ValueError):
        continue
    items = (obj if isinstance(obj, list)
             else next((obj[k] for k in ('results', 'statusItems', 'status_items', 'items')
                        if isinstance(obj.get(k), list)), []))
    for it in items:
        if not str(it.get('key') or '').lower().startswith('management.declarations.'):
            continue
        val = it.get('value')
        entries = (val if isinstance(val, list) else [val] if isinstance(val, dict) else [])
        for e in entries:
            ident = str(e.get('identifier') or e.get('id') or '') if isinstance(e, dict) else ''
            if bp_id and bp_id not in ident:
                continue
            m = UUID_RE.search(ident)
            if m:
                seen.add(m.group(1))
for u in sorted(seen):
    print(u)
PY
    )
    [[ -z "$uuids" ]] && return
    total=$(printf '%s\n' "$uuids" | /usr/bin/grep -c .)
    echo "   Fetching declaration payloads: ${total}..."
    while IFS= read -r uuid; do
        [[ -z "$uuid" ]] && continue
        /usr/bin/curl -s -H "Authorization: Bearer ${token}" \
            "${jss_url}/api/v1/dss-declarations/${uuid}" \
            > "${dss_dir}/${uuid}.json" 2>/dev/null
    done <<< "$uuids"
}

aggregate_and_report() {
    local out_arg="" summary_json mode_arg="blueprint" report_type="per-declaration" csv_file xlsx_file final_output details_csv=""
    [[ -n "$blueprint_id" ]] && report_type="blueprint"
    csv_file="${output_dir}/report-macos-blueprint-status_${report_type}_$(url_host "$jss_instance")_${timestamp}.csv"
    xlsx_file="${csv_file%.csv}.xlsx"
    [[ $dry_run -eq 0 ]] && out_arg="$csv_file"
    [[ -n "$blueprint_id" && $dry_run -eq 0 ]] && details_csv="${csv_file%.csv}_details.csv"

    if [[ -n "$blueprint_id" ]]; then
        summary_json=$(/usr/bin/python3 "${workdir}/pivot.py" \
            "$targets_file" "$status_dir" "$cmdhist_dir" \
            "$out_arg" "$blueprint_id" "report" "$stale_days" "${details_csv}" 2>"${inst_workdir}/aggregate.log")
    else
        [[ "$include_all" -eq 1 ]] && mode_arg="all"
        summary_json=$(/usr/bin/python3 "${workdir}/aggregate.py" \
            "$targets_file" "$status_dir" "$out_arg" "$mode_arg" 2>"${inst_workdir}/aggregate.log")
    fi

    if [[ -z "$summary_json" ]]; then
        echo "   ERROR: could not build the report."
        /usr/bin/sed 's/^/      /' "${inst_workdir}/aggregate.log"
        return 1
    fi

    echo
    /usr/bin/python3 - "$summary_json" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
if "blueprint_id" in s:
    print(f"   Blueprint:                {s['blueprint_id']}")
    print(f"   Target computers:         {s['devices_total']}")
    print(f"   Not fully deployed:       {s['not_deployed']}")
else:
    print(f"   Target computers:         {s['devices_total']}")
    print(f"   Computers with failures:  {s['devices_with_failures']}")
    print(f"   Computers, no declarations: {s['devices_no_declarations']}")
    print(f"   Declaration rows:         {s['declaration_rows']}")
for status, count in (s.get("status_breakdown") or {}).items():
    print(f"      {status:24s} {count}")
PY
    if [[ -n "$blueprint_id" ]]; then
        echo
        echo "   Blueprint URL: ${jss_url}/view/mfe/blueprints/${blueprint_id}"
        echo "   Re-run flag:   --blueprint-id ${blueprint_id}"
    fi

    if [[ $dry_run -eq 0 ]]; then
        final_output=$(csv_to_xlsx "$csv_file" "$xlsx_file" "Blueprint Status" 0)
        if [[ "${final_output##*.}" == "xlsx" && -s "${inst_workdir}/blueprints.tsv" ]]; then
            "$mjt_python" - "$final_output" "${inst_workdir}/blueprints.tsv" 2>/dev/null <<'PY'
import sys
from openpyxl import load_workbook
from openpyxl.styles import Font
wb = load_workbook(sys.argv[1])
ws = wb.create_sheet("Blueprints")
ws.append(["Blueprint ID", "Computers"])
ws.cell(row=1, column=1).font = Font(bold=True)
ws.cell(row=1, column=2).font = Font(bold=True)
with open(sys.argv[2]) as f:
    for line in f:
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t', 1)
        if len(parts) == 2:
            count, bid = parts
            try:
                ws.append([bid, int(count)])
            except ValueError:
                ws.append([bid, count])
ws.column_dimensions["A"].width = 40
ws.column_dimensions["B"].width = 12
wb.save(sys.argv[1])
PY
        fi
        if [[ "${final_output##*.}" == "xlsx" && -s "$details_csv" ]]; then
            "$mjt_python" - "$final_output" "$details_csv" 2>/dev/null <<'PY'
import sys, csv
from openpyxl import load_workbook
from openpyxl.styles import Font
from openpyxl.utils import get_column_letter
wb = load_workbook(sys.argv[1])
ws = wb.create_sheet("Declaration Details")
with open(sys.argv[2], newline="") as f:
    rows = list(csv.reader(f))
widths = {}
for r_idx, row in enumerate(rows, start=1):
    ws.append(row)
    for c_idx, val in enumerate(row, start=1):
        widths[c_idx] = max(widths.get(c_idx, 0), len(str(val)))
    if r_idx == 1:
        for c_idx in range(1, len(row) + 1):
            ws.cell(row=1, column=c_idx).font = Font(bold=True)
for c_idx, w in widths.items():
    ws.column_dimensions[get_column_letter(c_idx)].width = min(max(w + 2, 10), 80)
ws.freeze_panes = "A2"
wb.save(sys.argv[1])
PY
            /bin/rm -f "$details_csv"
        fi
        if [[ "${final_output##*.}" == "xlsx" && -d "${inst_workdir}/dss-decls" ]]; then
            "$mjt_python" - "$final_output" "${inst_workdir}/dss-decls" 2>/dev/null <<'PY'
import sys, os, json
from openpyxl import load_workbook
from openpyxl.styles import Font
from openpyxl.utils import get_column_letter
wb = load_workbook(sys.argv[1])
dss_dir = sys.argv[2]
rows = []
for fn in sorted(os.listdir(dss_dir)):
    if not fn.endswith('.json'):
        continue
    try:
        with open(os.path.join(dss_dir, fn)) as f:
            data = json.load(f)
    except (OSError, ValueError):
        continue
    for d in (data.get('declarations') or []):
        dtype = str(d.get('type') or '')
        group = str(d.get('group') or '').title()
        pj = d.get('payloadJson') or '{}'
        try:
            payload = json.loads(pj) if isinstance(pj, str) else (pj or {})
        except (ValueError, TypeError):
            payload = {}
        if payload and isinstance(payload, dict):
            for k, v in payload.items():
                val = json.dumps(v) if isinstance(v, (dict, list)) else str(v)
                rows.append([dtype, group, k, val])
        else:
            rows.append([dtype, group, '', str(pj)])
if rows:
    ws = wb.create_sheet("Payload Settings")
    header = ["Declaration Type", "Group", "Setting", "Value"]
    ws.append(header)
    for c_idx in range(1, len(header) + 1):
        ws.cell(row=1, column=c_idx).font = Font(bold=True)
    widths = {i + 1: len(h) for i, h in enumerate(header)}
    for row in rows:
        ws.append(row)
        for c_idx, val in enumerate(row, start=1):
            widths[c_idx] = max(widths.get(c_idx, 0), len(str(val)))
    for c_idx, w in widths.items():
        ws.column_dimensions[get_column_letter(c_idx)].width = min(max(w + 2, 10), 80)
    ws.freeze_panes = "A2"
wb.save(sys.argv[1])
PY
        fi
        written_files+=("$final_output")
    fi
}

process_instance() {
    inst_workdir="${workdir}/$(instance_slug "$jss_instance")"
    targets_file="${inst_workdir}/targets.tsv"
    status_dir="${inst_workdir}/status"
    cmdhist_dir="${inst_workdir}/cmdhist"
    /bin/mkdir -p "$status_dir" "$cmdhist_dir"

    # blueprint IDs differ per instance, so pick per instance unless given
    blueprint_id=""
    [[ "$blueprint_id_arg" != "-" ]] && blueprint_id="$blueprint_id_arg"

    resolve_targets || return 1
    fetch_statuses
    /usr/bin/python3 "${workdir}/blueprint_menu.py" "$status_dir" 2>/dev/null \
        > "${inst_workdir}/blueprints.tsv"
    if [[ -z "$blueprint_id_arg" ]]; then
        choose_blueprint || return 1
    fi
    include_all="${include_all:-0}"
    [[ -n "$blueprint_id" && $dry_run -eq 0 ]] && fetch_declaration_payloads
    [[ -n "$blueprint_id" ]] && fetch_command_history
    aggregate_and_report
}

# -------------------------------------------------------------------------
# INSTANCE SELECTION
# -------------------------------------------------------------------------

ensure_dependencies jamf-cli jq "openpyxl?" || exit 1

workdir=$(/usr/bin/mktemp -d "${output_location}/report-macos-blueprint-status.XXXXXX")
trap 'remove_jamfcli_token; /bin/rm -rf "$workdir"' EXIT
write_python_helpers

announce_instances
choose_destination_instances
if [[ ${#instance_choice_array[@]} -eq 0 ]]; then
    echo "ERROR: no instance selected."
    exit 1
fi

# -------------------------------------------------------------------------
# TARGETS
# -------------------------------------------------------------------------

if [[ -z "$target_mode" ]]; then
    # the group picker reads from the first instance
    token_for_instance "${instance_choice_array[0]}" || exit 1
    choose_device_targets || exit 1
fi

# -------------------------------------------------------------------------
# OUTPUT
# -------------------------------------------------------------------------

if [[ $dry_run -eq 0 ]]; then
    choose_output_dir || exit 1
fi
timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
written_files=()

for jss_instance in "${instance_choice_array[@]}"; do
    section "$jss_instance"
    if ! token_for_instance "$jss_instance"; then
        echo "   Could not get a token. Skipping."
        returncode=1
        continue
    fi
    process_instance || returncode=1
    remove_jamfcli_token
done

echo
if [[ ${#written_files[@]} -gt 0 ]]; then
    echo "Report(s) written to:"
    printf '   %s\n' "${written_files[@]}"
elif [[ $dry_run -eq 1 ]]; then
    echo "Dry-run: no report written."
fi
echo
exit "$returncode"
