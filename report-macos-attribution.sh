#!/bin/bash

# Report the most likely owner of each target Mac, on one or more Jamf Pro
# instances. Read-only.
#
# Flow: instance(s) -> which Macs (default all) -> output folder ->
#       per instance: inventory + user/location history -> score -> report.
#
# Interactively it asks only which Macs to cover; every signal and the
# user/location history are always gathered. Filters (--model, --chip,
# --enrolled-from/-to) and --requested-by are flag-only.
#
# For each Mac the owner is inferred from signals already in the inventory
# record - MDM-capable accounts, FileVault-enabled accounts, the largest real
# home directory and the last user seen by the Jamf binary - and scored
# High / Medium / Low / None. Conflict = YES flags Macs whose assigned user
# disagrees with what is on the disk: the rows to chase first in a
# missing-hardware audit.
#
# Workbook sheets: Summary, Devices, Local Accounts, User History, Not
# Obtainable (login history and IP history are not kept by Jamf Pro).
#
# Contains personal data (usernames, names, email, IPs): handle per UK GDPR /
# GDPR; the customer is data controller for customer tenants.
#
# Privileges: Read on Computers and Computer Groups (inventory + history).
#
# Usage:
#   ./report-macos-attribution.sh -i https://tenant.jamfcloud.com \
#       --all-devices --model "MacBook Air" --enrolled-from 2025-04-01

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
filter_model=""
filter_chip=""
enrolled_from=""
enrolled_to=""
date_basis=""
do_history=""
requested_by=""
output_dir=""
probe=0
dry_run=0
returncode=0
device_platform="computer"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -il|--instance-list)  shift; chosen_instance_list_file="$1" ;;
        -i|--instance)        shift; chosen_instances+=("$1") ;;
        -a|--all-instances|--all) all_instances=1 ;;
        --id|--client-id|--user) shift; chosen_id="$1" ;;
        -x|--nointeraction)   no_interaction=1 ;;
        -v|--verbose)         verbose=1 ;;
        -j|--jamf-cli)        shift; jamf_cli_path="$1" ;;
        -o|--output-dir|--out) shift; output_dir="$1" ;;
        -y|--yes)             assume_yes=1 ;;
        -n|--dry-run)         dry_run=1 ;;
        --model)              shift; filter_model="$1" ;;
        --chip)               shift; filter_chip="$1" ;;
        --enrolled-from)      shift; enrolled_from="$1" ;;
        --enrolled-to)        shift; enrolled_to="$1" ;;
        --date-basis)         shift; date_basis="$1" ;;
        --history)            do_history=1 ;;
        --no-history)         do_history=0 ;;
        --requested-by)       shift; requested_by="$1" ;;
        --probe)              probe=1 ;;
        --serial|--name|--name-match|--group|--all-devices)
            parse_target_arg "$@" || exit 1
            shift "$target_args_used"
            continue
            ;;
        -h|--help)
            echo "Usage: $0 [MJT flags] [target flags] [filter flags] [--history|--no-history]"
            echo ""
            print_target_usage
            echo "                           (default: every computer)"
            echo ""
            echo "Filters (all optional):"
            echo "  --model STRING           Model contains STRING, e.g. \"MacBook Air\""
            echo "  --chip STRING            Processor contains STRING, e.g. \"M3\" (\"Apple\" = any Apple silicon)"
            echo "  --enrolled-from DATE     On or after YYYY-MM-DD"
            echo "  --enrolled-to DATE       On or before YYYY-MM-DD"
            echo "  --date-basis BASIS       enrollment (last enrolment, default) | initial-entry"
            echo ""
            echo "History (included by default; one API call per Mac):"
            echo "  --no-history             Skip it (faster on large fleets; User History sheet left empty)"
            echo ""
            echo "Output:"
            echo "  -o  | --output-dir DIR   Where to save the report (prompts /tmp or ~/Desktop if omitted)"
            echo "  --requested-by NAME      Recorded on the Summary sheet's data-handling note"
            echo "  -n  | --dry-run          Print the summary only; write no report"
            echo "  --probe                  Print one raw inventory + history record, then exit"
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

for d in "$enrolled_from" "$enrolled_to"; do
    if [[ -n "$d" && ! "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "ERROR: enrolment dates must be YYYY-MM-DD (got '$d')."
        exit 1
    fi
done
if [[ -n "$date_basis" && "$date_basis" != "enrollment" && "$date_basis" != "initial-entry" ]]; then
    echo "ERROR: --date-basis must be enrollment or initial-entry."
    exit 1
fi

interactive=1
[[ "${no_interaction:-0}" -eq 1 || ! -t 0 ]] && interactive=0
do_history="${do_history:-1}"
[[ $interactive -eq 0 ]] && target_mode="${target_mode:-all}"

# -------------------------------------------------------------------------
# FUNCTIONS
# -------------------------------------------------------------------------

write_scorer() {
    /bin/cat > "${workdir}/score.py" << 'PYEOF'
"""
Filter, score and write the attribution report for one instance.

argv[1] = inventory JSON (array, or {"results": [...]})
argv[2] = group member computer IDs file (one per line; used for target mode "group")
argv[3] = history dir (<computerId>.json from classic-computer-history, UserLocation)
argv[4] = mode: "ids" (print matched computer IDs) | "report"
argv[5] = output path without extension ("" = summary only)
Filters and run details come from J_* environment variables.
"""
import sys, os, json, csv, re
from datetime import datetime, timezone, timedelta
from collections import Counter

inv_file, members_file, hist_dir, mode, out_base = sys.argv[1:6]
env = os.environ.get

inventory_raw = json.load(open(inv_file))
records = inventory_raw.get("results", []) if isinstance(inventory_raw, dict) else inventory_raw
records = [r for r in records if isinstance(r, dict)]
members = {l.strip() for l in open(members_file) if l.strip()} if members_file else set()

target_mode = env("J_MODE", "all")
target_values = [v.strip().lower() for v in env("J_VALUES", "").split("\n") if v.strip()]
model_f = env("J_MODEL", "").lower()
chip_f = env("J_CHIP", "").lower()
enr_from = env("J_FROM", "")
enr_to = env("J_TO", "")
basis = env("J_BASIS", "") or "enrollment"
instance = env("J_INSTANCE", "")

EXCLUDED = {
    "root", "daemon", "nobody", "admin", "administrator", "localadmin",
    "jamfadmin", "jamfmanage", "macadmin", "itadmin", "test", "guest",
    "lapsadmin", "_mbsetupuser",
}
HOME_FLOOR_MB = 1000
APPLE_SILICON_KEYWORDS = {"apple", "silicon", "m1", "m2", "m3", "m4", "m5"}


def is_system(username, uid=None):
    if not username or username.startswith("_") or username.lower() in EXCLUDED:
        return True
    if uid is not None:
        try:
            if int(uid) < 500:
                return True
        except (TypeError, ValueError):
            pass
    return False


def parse_iso(s):
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(re.sub(r"\.\d+", "", str(s)).replace("Z", "+00:00"))
    except Exception:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def in_range(dt, lo_str, hi_str):
    if not (lo_str or hi_str):
        return True
    if dt is None:
        return False
    lo = parse_iso(lo_str)
    hi = parse_iso(hi_str)
    if lo and dt < lo:
        return False
    # a date-only upper bound includes that whole day
    if hi and dt >= hi + timedelta(days=1):
        return False
    return True


def fmt_date(s):
    if not s:
        return ""
    s = re.sub(r"\.\d+", "", str(s).strip().replace("T", " "))
    s = re.sub(r"(Z|[+-]\d{2}:?\d{2})$", "", s)
    return s[:16].strip()


def g(rec, section, key):
    return (rec.get(section) or {}).get(key)


def computer_id(rec):
    return str(rec.get("id") or g(rec, "general", "id") or "")


def enrol_date(rec):
    if basis == "initial-entry":
        return g(rec, "general", "initialEntryDate")
    return g(rec, "general", "lastEnrolledDate") or g(rec, "general", "enrollmentDate")


def passes(rec):
    name = (g(rec, "general", "name") or "").lower()
    serial = (g(rec, "hardware", "serialNumber") or "").lower()
    if target_mode == "group" and computer_id(rec) not in members:
        return False
    if target_mode == "serial" and serial not in target_values:
        return False
    if target_mode == "name" and name not in target_values:
        return False
    if target_mode == "name-match" and (not target_values or target_values[0] not in name):
        return False
    if model_f and model_f not in (g(rec, "hardware", "model") or g(rec, "hardware", "modelIdentifier") or "").lower():
        return False
    if chip_f and chip_f not in (g(rec, "hardware", "processorType") or "").lower():
        if not (chip_f in APPLE_SILICON_KEYWORDS and g(rec, "hardware", "appleSilicon")):
            return False
    return in_range(parse_iso(enrol_date(rec)), enr_from, enr_to)


matched_recs = [r for r in records if passes(r)]

if mode == "ids":
    for r in matched_recs:
        print(computer_id(r))
    sys.exit(0)


def score(rec):
    gen = rec.get("general") or {}
    la = rec.get("localUserAccounts") or []

    s1 = (g(rec, "userAndLocation", "username") or "").strip().lower()

    # S2 - MDM-capable accounts (secure token holders)
    s2 = [u.strip().lower() for u in ((gen.get("mdmCapable") or {}).get("capableUsers") or [])
          if u and not is_system(u.strip().lower())]

    # S3 - FileVault-enabled accounts
    s3 = [u.strip().lower() for u in (g(rec, "diskEncryption", "fileVault2EnabledUserNames") or [])
          if u and not is_system(u.strip().lower())]

    # S4 - largest real home directory
    s4_candidates = []
    for acct in la:
        uname = (acct.get("username") or "").strip().lower()
        if is_system(uname, acct.get("uid")):
            continue
        try:
            home = float(acct.get("homeDirectorySizeMb") or 0)
        except (TypeError, ValueError):
            home = 0
        if home >= HOME_FLOOR_MB:
            s4_candidates.append((uname, home))
    s4_candidates.sort(key=lambda x: x[1], reverse=True)
    s4 = s4_candidates[0][0] if s4_candidates else None

    # S5 - last logged-in user recorded by the Jamf binary at recon time
    s5_raw = (gen.get("lastLoggedInUsernameBinary") or "").strip().lower()
    s5_ts = fmt_date(gen.get("lastLoggedInUsernameBinaryTimestamp") or "")
    s5 = s5_raw if (s5_raw and not is_system(s5_raw)) else None

    votes = Counter()
    for u in s2:
        votes[u] += 1
    for u in s3:
        votes[u] += 1
    if s4:
        votes[s4] += 1
    if s5:
        votes[s5] += 1

    inferred = None
    if votes:
        top_n = max(votes.values())
        top = [u for u, c in votes.items() if c == top_n]
        inferred = top[0] if len(top) == 1 else (s2[0] if s2 else top[0])

    if inferred:
        agree_count = sum(1 for u in [s2[0] if s2 else None, s3[0] if s3 else None, s4, s5]
                          if u == inferred)
        s1_ok = (not s1) or (s1 == inferred)
        if agree_count >= 2 and s1_ok:
            conf = "High"
        elif agree_count >= 2:
            conf = "Medium"
        elif s4 == inferred and not s2 and not s3 and not s5 and s4_candidates:
            conf = "Medium"
        else:
            conf = "Low"
    else:
        conf = "None"

    signals = []
    if s1: signals.append("S1(assigned)")
    if s2: signals.append("S2(MDM-capable)")
    if s3: signals.append("S3(FileVault)")
    if s4: signals.append("S4(home-dir)")
    if s5: signals.append("S5(last-logged-in)")

    return {
        "inferred": inferred or "",
        "confidence": conf,
        "conflict": bool(s1 and inferred and s1 != inferred),
        "evidence": ", ".join(signals),
        "s1": s1,
        "s5": s5 or "",
        "s5_ts": s5_ts,
    }


def history_for(cid):
    path = os.path.join(hist_dir, f"{cid}.json")
    if not cid or not os.path.exists(path):
        return []
    try:
        d = json.load(open(path))
    except (OSError, ValueError):
        return []
    node = d.get("computer_history", d) if isinstance(d, dict) else {}
    ul = node.get("user_location") if isinstance(node, dict) else None
    if isinstance(ul, dict):
        ul = ul.get("location")
    if isinstance(ul, dict):
        ul = [ul]
    # skip entries with nothing but a timestamp
    keys = ("username", "full_name", "email_address", "department", "building", "position")
    return [e for e in (ul or []) if isinstance(e, dict) and any(e.get(k) for k in keys)]


matched = [(r, score(r), history_for(computer_id(r))) for r in matched_recs]
conf_dist = Counter(s["confidence"] for _, s, _ in matched)
conflict_count = sum(1 for _, s, _ in matched if s["conflict"])
history_rows = sum(len(h) for _, _, h in matched)


def device_row(rec, s):
    cid = computer_id(rec)
    return [
        cid,
        g(rec, "general", "name") or "",
        g(rec, "hardware", "serialNumber") or "",
        g(rec, "hardware", "model") or "",
        g(rec, "hardware", "processorType") or "",
        g(rec, "operatingSystem", "version") or "",
        fmt_date(g(rec, "general", "lastEnrolledDate") or g(rec, "general", "enrollmentDate")),
        fmt_date(g(rec, "general", "initialEntryDate")),
        fmt_date(g(rec, "general", "lastContactTime")),
        fmt_date(g(rec, "general", "reportDate")),
        g(rec, "general", "lastReportedIpV4") or g(rec, "general", "lastReportedIp") or "",
        g(rec, "general", "lastIpAddress") or "",
        s["s1"], s["s5"], s["s5_ts"],
        s["inferred"], s["confidence"],
        "YES" if s["conflict"] else "",
        s["evidence"],
        f"{instance.rstrip('/')}/computers.html?id={cid}&o=r" if cid else "",
    ]


DEV_COLS = [
    "ID", "Name", "Serial", "Model", "Processor", "macOS Version",
    "Last Enrolled", "Initial Entry", "Last Contact", "Last Inventory",
    "Last Reported IP", "Public IP",
    "Device Record User", "Last Logged-in User", "Last Login Timestamp",
    "Attributed User", "Confidence", "Conflict", "Evidence", "URL",
]

written = ""
if out_base:
    try:
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
        from openpyxl.utils import get_column_letter
    except ImportError:
        openpyxl = None

    if openpyxl is None:
        written = out_base + ".csv"
        with open(written, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(DEV_COLS)
            for rec, s, _ in matched:
                w.writerow(device_row(rec, s))
    else:
        BLUE = "1E88E5"; WHITE = "FFFFFF"; YELLOW = "FFF9C4"; RED = "FFEBEE"
        PINK = "FCE4EC"; DARK_BLUE = "1565C0"

        def fill(c):
            return PatternFill("solid", fgColor=c)

        def font(bold=False, colour="000000", size=10, underline=None):
            return Font(bold=bold, color=colour, size=size, name="Arial", underline=underline)

        def border(c="D0D0D0"):
            s = Side(style="thin", color=c)
            return Border(left=s, right=s, top=s, bottom=s)

        def hdr_row(ws, cols):
            for ci, label in enumerate(cols, 1):
                cell = ws.cell(row=1, column=ci, value=label)
                cell.font = font(bold=True, colour=WHITE)
                cell.fill = fill(BLUE)
                cell.border = border(DARK_BLUE)
                cell.alignment = Alignment(wrap_text=True, vertical="center")
            ws.row_dimensions[1].height = 28
            ws.freeze_panes = "A2"

        def autofit(ws, mn=8, mx=50):
            for col in ws.columns:
                w = max((len(str(c.value or "")) for c in col), default=mn)
                ws.column_dimensions[get_column_letter(col[0].column)].width = min(max(w + 2, mn), mx)

        def table(ws, cols, rows, row_fill=None):
            hdr_row(ws, cols)
            for ri, vals in enumerate(rows, 2):
                for ci, v in enumerate(vals, 1):
                    cell = ws.cell(row=ri, column=ci, value=v)
                    cell.border = border()
                    cell.alignment = Alignment(vertical="center")
                    if row_fill:
                        cell.fill = fill(row_fill[ri - 2])
            autofit(ws)

        wb = openpyxl.Workbook()

        # Summary
        ws = wb.active
        ws.title = "Summary"
        ws.column_dimensions["A"].width = 38
        ws.column_dimensions["B"].width = 60
        r = 1

        def srow(label, value):
            global r
            ws.cell(row=r, column=1, value=label).font = font(bold=True)
            ws.cell(row=r, column=2, value="" if value is None else str(value))
            r += 1

        for col in (1, 2):
            ws.cell(row=r, column=col).fill = fill(BLUE)
        ws.cell(row=r, column=1, value="macOS Attribution Report").font = font(bold=True, colour=WHITE, size=14)
        ws.row_dimensions[r].height = 28
        r += 1
        srow("Instance", instance)
        srow("Run timestamp", env("J_RUN_TS", ""))
        srow("Operator", env("J_OPERATOR", ""))
        srow("Targets", env("J_TARGET_DESC", ""))
        srow("Model filter", model_f or "(none)")
        srow("Chip filter", chip_f or "(none)")
        srow("Date basis", "initial entry" if basis == "initial-entry" else "last enrolment")
        srow("Enrolled from", enr_from or "(none)")
        srow("Enrolled to", enr_to or "(none)")
        srow("Devices matched", len(matched))
        r += 1
        srow("High confidence", conf_dist.get("High", 0))
        srow("Medium confidence", conf_dist.get("Medium", 0))
        srow("Low confidence", conf_dist.get("Low", 0))
        srow("No attributable signal", conf_dist.get("None", 0))
        srow("Conflicts (assigned user vs disk)", conflict_count)
        r += 1
        for col in (1, 2):
            ws.cell(row=r, column=col).fill = fill(PINK)
        ws.cell(row=r, column=1, value="DATA HANDLING").font = font(bold=True, size=11)
        ws.cell(row=r, column=2, value="Personal data - handle per UK GDPR / GDPR").font = font(size=11)
        r += 1
        srow("Contains", "Usernames, real names, email, department, IP addresses")
        srow("Requested by", env("J_REQUESTED_BY", ""))
        srow("Advice", "If this is a customer tenant, the customer is data controller. "
             "Ensure a documented lawful basis exists before sharing.")

        # Devices
        ws2 = wb.create_sheet("Devices")
        conf_fill = {"High": WHITE, "Medium": YELLOW, "Low": YELLOW, "None": RED}
        dev_rows = [device_row(rec, s) for rec, s, _ in matched]
        fills = [RED if s["conflict"] else conf_fill.get(s["confidence"], WHITE) for _, s, _ in matched]
        table(ws2, DEV_COLS, dev_rows, fills)
        url_col = len(DEV_COLS)
        for ri, vals in enumerate(dev_rows, 2):
            if vals[-1]:
                cell = ws2.cell(row=ri, column=url_col)
                cell.hyperlink = vals[-1]
                cell.font = font(colour="0563C1", underline="single")

        # Local Accounts
        acct_rows = []
        for rec, _, _ in matched:
            for acct in (rec.get("localUserAccounts") or []):
                home = acct.get("homeDirectorySizeMb")
                acct_rows.append([
                    computer_id(rec), g(rec, "general", "name") or "",
                    g(rec, "hardware", "serialNumber") or "",
                    acct.get("username") or "", acct.get("fullName") or "",
                    "Yes" if acct.get("admin") else "No",
                    acct.get("userAccountType") or "",
                    "" if home in (None, -1) else home,
                    "Yes" if acct.get("fileVault2Enabled") else "No",
                    acct.get("azureActiveDirectoryId") or "",
                ])
        table(wb.create_sheet("Local Accounts"), [
            "Device ID", "Device Name", "Serial", "Username", "Full Name", "Admin",
            "Type", "Home Dir (MB)", "FileVault Enabled", "Azure AD ID"], acct_rows)

        # User History
        hist_rows = []
        for rec, _, hist in matched:
            for e in hist:
                hist_rows.append([
                    computer_id(rec), g(rec, "general", "name") or "",
                    g(rec, "hardware", "serialNumber") or "",
                    fmt_date(e.get("date_time_utc")) or e.get("date_time") or "",
                    e.get("username") or "", e.get("full_name") or "",
                    e.get("email_address") or "", e.get("department") or "",
                    e.get("building") or "", e.get("position") or "",
                ])
        ws4 = wb.create_sheet("User History")
        table(ws4, ["Device ID", "Device Name", "Serial", "Date", "Username", "Full Name",
                    "Email", "Department", "Building", "Position"], hist_rows)
        if not hist_rows:
            note = ("(history skipped - run with --history)" if env("J_HISTORY") != "1"
                    else "(no user or location changes recorded for these devices)")
            ws4.cell(row=2, column=1, value=note).font = font(colour="888888")

        # Not Obtainable
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
             "Jamf Pro stores only the most recent reported IPs (lastReportedIpV4 / "
             "lastIpAddress). No historical record of past addresses is retained. The "
             "current IPs are included in the Devices sheet for reference."),
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

        written = out_base + ".xlsx"
        wb.save(written)

print(json.dumps({
    "matched": len(matched),
    "confidence": {k: conf_dist.get(k, 0) for k in ("High", "Medium", "Low", "None")},
    "conflicts": conflict_count,
    "history_rows": history_rows,
    "written": written,
}))
PYEOF
}

# print one raw inventory record and its user/location history
run_probe() {
    local cid
    echo "   Raw inventory record (first computer, all sections used):"
    fetch_inventory_list GENERAL HARDWARE USER_AND_LOCATION LOCAL_USER_ACCOUNTS \
        DISK_ENCRYPTION OPERATING_SYSTEM | "$jq_bin" '.[0] // .results[0] // empty'
    cid=$(fetch_inventory_list GENERAL | "$jq_bin" -r '(.[0] // .results[0]).id // empty' 2>/dev/null)
    if [[ -n "$cid" ]]; then
        echo
        echo "   User and location history for computer ID $cid:"
        jc pro classic-computer-history get "$cid" --subset UserLocation -o json 2>/dev/null
    fi
}

# fill $members_file with group member IDs (group targets only)
resolve_group() {
    : > "$members_file"
    [[ "$target_mode" != "group" ]] && return 0
    if ! jc pro classic-computer-groups get --name "$group_name" --output json 2>/dev/null \
        | "$jq_bin" -r '(.computer_group // .) | (.computers // [])[] | .id' > "$members_file" 2>/dev/null \
        || [[ ! -s "$members_file" ]]; then
        if [[ $interactive -eq 1 ]]; then
            echo "   Group \"$group_name\" not found or empty on $jss_instance."
            choose_computer_group || return 1
            resolve_group
            return
        fi
        echo "   ERROR: group \"$group_name\" not found or empty."
        return 1
    fi
    echo "   Group \"$group_name\": $(/usr/bin/grep -c . "$members_file") member(s)."
}

run_score() {
    J_MODE="$target_mode" J_VALUES=$(printf '%s\n' "${target_values[@]}") \
    J_MODEL="$filter_model" J_CHIP="$filter_chip" J_FROM="$enrolled_from" J_TO="$enrolled_to" \
    J_BASIS="$date_basis" J_INSTANCE="$jss_instance" J_HISTORY="$do_history" \
    J_OPERATOR="${USER:-unknown}" J_RUN_TS="$run_ts" J_TARGET_DESC="$target_desc" \
    J_REQUESTED_BY="$requested_by" \
        "$mjt_python" "${workdir}/score.py" "$inventory_json" "$members_file" "$hist_dir" "$@"
}

fetch_history() {
    local total n=0 cid
    total=$(/usr/bin/grep -c . "$ids_file")
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        n=$((n + 1))
        printf '\r   Fetching user and location history: %d of %d' "$n" "$total"
        jc pro classic-computer-history get "$cid" --subset UserLocation -o json \
            > "${hist_dir}/${cid}.json" 2>/dev/null
    done < "$ids_file"
    echo
}

process_instance() {
    local inst_workdir summary out_base=""
    inst_workdir="${workdir}/$(instance_slug "$jss_instance")"
    inventory_json="${inst_workdir}/inventory.json"
    members_file="${inst_workdir}/members.txt"
    ids_file="${inst_workdir}/ids.txt"
    hist_dir="${inst_workdir}/history"
    /bin/mkdir -p "$hist_dir"

    if [[ $probe -eq 1 ]]; then
        run_probe
        return
    fi

    resolve_group || return 1
    echo "   Fetching computer inventory..."
    fetch_inventory_list GENERAL HARDWARE USER_AND_LOCATION LOCAL_USER_ACCOUNTS \
        DISK_ENCRYPTION OPERATING_SYSTEM > "$inventory_json"
    if [[ ! -s "$inventory_json" ]]; then
        echo "   ERROR: could not read computer inventory."
        return 1
    fi

    if ! run_score ids "" > "$ids_file" 2>"${inst_workdir}/score.log"; then
        echo "   ERROR: could not filter the inventory."
        /usr/bin/sed 's/^/      /' "${inst_workdir}/score.log"
        return 1
    fi
    if [[ ! -s "$ids_file" ]]; then
        echo "   No computers match the targets and filters."
        return 0
    fi
    echo "   $(/usr/bin/grep -c . "$ids_file") computer(s) match."

    [[ "$do_history" -eq 1 ]] && fetch_history

    [[ $dry_run -eq 0 ]] && out_base="${output_dir}/report-macos-attribution_$(url_host "$jss_instance")_${timestamp}"
    if ! summary=$(run_score report "$out_base" 2>"${inst_workdir}/score.log"); then
        echo "   ERROR: could not build the report."
        /usr/bin/sed 's/^/      /' "${inst_workdir}/score.log"
        return 1
    fi

    echo
    /usr/bin/python3 - "$summary" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
c = s["confidence"]
print(f"   Computers:          {s['matched']}")
print(f"   Confidence:         High {c['High']}   Medium {c['Medium']}   Low {c['Low']}   None {c['None']}")
print(f"   Conflicts:          {s['conflicts']}")
print(f"   History entries:    {s['history_rows']}")
PY
    written=$(printf '%s' "$summary" | "$jq_bin" -r '.written // empty')
    [[ -n "$written" ]] && written_files+=("$written")
}

choose_targets() {
    choose_from_menu 1 "Which Macs?" \
        "All computers" \
        "Specific Macs (serial number, name or group)" || exit 1
    if [[ "$menu_choice" -eq 1 ]]; then
        target_mode="all"
        return 0
    fi
    # the group picker reads from the first instance
    token_for_instance "${instance_choice_array[0]}" || exit 1
    choose_device_targets || exit 1
}

# -------------------------------------------------------------------------
# INSTANCE SELECTION
# -------------------------------------------------------------------------

ensure_dependencies jamf-cli jq "openpyxl?" || exit 1

workdir=$(/usr/bin/mktemp -d "${output_location:-/tmp}/report-macos-attribution.XXXXXX")
trap 'remove_jamfcli_token; /bin/rm -rf "$workdir"' EXIT
write_scorer

announce_instances
choose_destination_instances
if [[ ${#instance_choice_array[@]} -eq 0 ]]; then
    echo "ERROR: no instance selected."
    exit 1
fi

# -------------------------------------------------------------------------
# TARGETS
# -------------------------------------------------------------------------

if [[ $probe -eq 0 && $interactive -eq 1 && -z "$target_mode" ]]; then
    choose_targets
fi

case "$target_mode" in
    serial)     target_desc="Serial(s) ${target_values[*]}" ;;
    name)       target_desc="Name(s) ${target_values[*]}" ;;
    name-match) target_desc="Names containing '${target_values[0]}'" ;;
    group)      target_desc="Group '$group_name'" ;;
    *)          target_desc="All computers" ;;
esac

if [[ $probe -eq 0 ]]; then
    filters_desc=()
    [[ -n "$filter_model" ]] && filters_desc+=("model '$filter_model'")
    [[ -n "$filter_chip" ]] && filters_desc+=("chip '$filter_chip'")
    [[ -n "$enrolled_from" ]] && filters_desc+=("enrolled >= $enrolled_from")
    [[ -n "$enrolled_to" ]] && filters_desc+=("enrolled <= $enrolled_to")
    [[ "$date_basis" == "initial-entry" && -n "$enrolled_from$enrolled_to" ]] && filters_desc+=("(initial entry date)")
    echo
    echo "   Targets:   $target_desc"
    echo "   Filters:   ${filters_desc[*]:-none}"
    echo "   History:   $( [[ "$do_history" -eq 1 ]] && echo included || echo skipped )"
    echo "   Instances: ${#instance_choice_array[@]}"
    [[ $dry_run -eq 1 ]] && echo "   Dry-run:   no report will be written"
fi

# -------------------------------------------------------------------------
# OUTPUT
# -------------------------------------------------------------------------

if [[ $dry_run -eq 0 && $probe -eq 0 ]]; then
    choose_output_dir || exit 1
fi
timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
run_ts=$(/bin/date '+%Y-%m-%d %H:%M')
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
