#!/usr/bin/env python3
"""
Export a Jamf Pro tenant's macOS posture to an Excel workbook (default),
a folder of CSVs, or a terminal table.

Output sheets (xlsx) / files (csv), in workbook order:
- Jamf MSP Summary             : instance overview, fleet counts, certs, LAPS, SSO, etc.
- macOS - Health Check         : one row per Mac with at least one detected issue, plus Suggested Actions.
- macOS - Managed Macs         : one row per managed Mac (full fleet) with
                                  identity, ownership, hardware/OS, IPv4,
                                  enrolment method (prestage name or UIE),
                                  enrolled/last-seen dates, bootstrap token,
                                  and an "In Health Check" cross-reference.
- iOS - Devices                : one row per managed iOS/iPadOS device (full
                                  fleet) with identity, ownership, model/OS,
                                  enrolment method, enrolled date, last
                                  inventory, and a "Health Check Pending"
                                  cross-reference to iOS - Health Check.
- macOS - Apps - Scope         : one row per managed app and per Install-/Auto-Update- policy.
- macOS - Config Profiles - Scope : one row per profile scope summary.
- macOS - Config Profiles      : flattened key/value settings.
- macOS - Scripts              : one row per policy/script pairing with Notes describing what the script does.
- macOS - Extension Attributes : one row per EA with Notes.
- macOS - Restricted Software  : one row per restricted-software item.
- macOS - Prestages            : prestage settings matrix.
- macOS - FileVault Recovery Keys : one row per encrypted Mac with its Personal Recovery Key.
                                  Requires the API role to have the
                                  'View Disk Encryption Recovery Key' privilege.
- macOS - Software Updates     : one row per Mac with an active MSU plan, a
                                  failure on `pro report update-status
                                  --scan-failures`, an expired MDM profile,
                                  or an invalid DDM declaration. Columns
                                  include Blueprint Status, Update Status,
                                  Issues, and Remediation.
- iOS - Software Updates       : same shape and inclusion rules as the
                                  macOS Software Updates sheet, applied to
                                  managed iOS / iPadOS devices.
- macOS - LAPS Accounts        : one row per (Mac, LAPS-managed admin account).
                                  Reports username + source (MDM vs JMF) only.
                                  Passwords are NOT retrieved — viewing a LAPS
                                  password triggers a rotation. Retrieve at
                                  cutover time, per device, on demand.
- macOS - Health Check Definitions : reference table describing each Health Check flag.
- Jamf Pro Accounts            : hybrid LDAP/Cloud-IdP group membership matrix
                                  (only present if the tenant has hybrid admin
                                  groups). Local-account names are intentionally
                                  excluded; counts appear on the summary sheet.

Use --sheets to pick a subset, e.g. --sheets msp-summary,managed-macs,filevault-keys
or omit and pick interactively. Slugs: msp-summary, health-check, managed-macs,
apps-scope, config-profiles-scope, config-profiles, scripts, extension-attributes,
restricted-software, prestages, filevault-keys, software-updates, laps-accounts,
jamf-pro-accounts, ios-health-check, ios-devices,
ios-apps-scope, ios-config-profiles-scope, ios-config-profiles,
ios-software-updates, ios-orphaned-items.
(The Health Check Key sheets aren't selectable slugs — each is auto-included
whenever its Health Check sheet is selected.)

Requires:
- jamf-cli in PATH

Optional (AI-enhanced descriptions):
- Ollama  https://ollama.com  — local AI server for generating descriptions in the
  Scripts, Extension Attributes, Config Profiles - Scope, and Health Check sheets.
  Install:  brew install ollama
  Model:    ollama pull llama3.2          (~2 GB, works well on 8 GB+ RAM)
  Start:    brew services start ollama   (runs at login)
            — or —  ollama serve         (foreground, current session only)

  The script detects Ollama automatically and offers to install it if missing.
  If Ollama is unavailable the export completes normally using built-in analysis.
"""

from __future__ import annotations

# ── Dependency check ─────────────────────────────────────────────────────────
# Runs before any other imports so failures produce a clear, actionable message
# rather than a cryptic ImportError or NameError.

def _jamfcli_list_profiles(_run) -> list[str]:
    """Return list of configured profile names from jamf-cli config show JSON."""
    import json
    try:
        r = _run(["jamf-cli", "config", "show", "--output", "json"],
                 capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            return []
        d = json.loads(r.stdout)
        return [p["name"] for p in d.get("profiles", []) if p.get("name")]
    except Exception:
        return []


def _jamfcli_default_profile(_run) -> str:
    """Return the current default profile name."""
    import json
    try:
        r = _run(["jamf-cli", "config", "show", "--output", "json"],
                 capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            return ""
        return json.loads(r.stdout).get("default-profile", "")
    except Exception:
        return ""


def _setup_jamfcli_profile_if_needed(_run, warn, ok, hdr, GREEN, YELLOW, RED, BOLD, NC) -> None:
    """If no profiles exist, offer to create one via jamf-cli pro setup.
    Mirrors the setup-profile shell function in the jamf-cli zsh toolkit.
    """
    import sys

    profiles = _jamfcli_list_profiles(_run)
    if profiles:
        return

    print(file=sys.stderr)
    print(f"{BOLD}  No jamf-cli profiles are configured.{NC}", file=sys.stderr)
    print("  A profile tells jamf-cli which Jamf Pro instance to connect to.", file=sys.stderr)
    print(file=sys.stderr)

    if not sys.stdin.isatty():
        warn("Run interactively to set up a profile, or:")
        warn("  jamf-cli pro setup --url https://yourinstance.jamfcloud.com --profile-name <name>")
        return

    try:
        answer = input("  Set up a jamf-cli profile now? [ y / n ]: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print(file=sys.stderr)
        return

    if answer not in ("", "y", "yes"):
        print(file=sys.stderr)
        warn("Skipped. Add a profile later with:")
        warn("  jamf-cli pro setup --url https://yourinstance.jamfcloud.com --profile-name <name>")
        print(file=sys.stderr)
        return

    print(file=sys.stderr)
    print("  ──────────────────────────────", file=sys.stderr)
    print("    New Jamf Pro Profile Setup  ", file=sys.stderr)
    print("  ──────────────────────────────", file=sys.stderr)

    try:
        while True:
            url = input("  Jamf Pro URL (e.g. https://example.jamfcloud.com): ").strip()
            if url:
                if not url.startswith("http"):
                    url = "https://" + url
                url = url.rstrip("/")
                break
            print("  URL is required.", file=sys.stderr)

        while True:
            profile_name = input("  Profile name: ").strip()
            if profile_name:
                break
            print("  Profile name is required.", file=sys.stderr)

    except (EOFError, KeyboardInterrupt):
        print(file=sys.stderr)
        warn("Profile setup cancelled.")
        return

    # ── jamf-cli pro setup (mirrors the shell setup-profile function) ─────────
    hdr("Creating profile...")
    result = _run(["jamf-cli", "pro", "setup",
                   "--url", url,
                   "--profile-name", profile_name])

    if result.returncode != 0:
        print(file=sys.stderr)
        warn("Profile creation failed. Try manually:")
        warn(f"  jamf-cli pro setup --url {url} --profile-name {profile_name}")
        return

    ok(f"Profile '{profile_name}' created.")

    # ── Offer to set as default (mirrors set-profile shell function) ──────────
    try:
        make_default = input(f"  Set '{profile_name}' as default profile? [ y / n ]: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        make_default = "n"

    if make_default in ("", "y", "yes"):
        _run(["jamf-cli", "config", "set-default", profile_name])
        ok(f"Default profile set to '{profile_name}'.")

    print(file=sys.stderr)
    ok(f"Ready. Run with:  python3 report-jamfpro-configuration.py --profile {profile_name}")
    print(file=sys.stderr)

    # Inject the profile into argv so this run continues without re-prompting
    if "--profile" not in sys.argv:
        sys.argv.extend(["--profile", profile_name])


def _check_dependencies() -> None:
    import sys, shutil, subprocess, importlib, os

    GREEN  = "\033[0;32m"
    YELLOW = "\033[1;33m"
    RED    = "\033[0;31m"
    BOLD   = "\033[1m"
    NC     = "\033[0m"

    def ok(msg):   print(f"  {GREEN}✓{NC} {msg}", file=sys.stderr)
    def warn(msg): print(f"  {YELLOW}!{NC} {msg}", file=sys.stderr)
    def err(msg):  print(f"  {RED}✗{NC} {msg}", file=sys.stderr)
    def hdr(msg):  print(f"\n{BOLD}{msg}{NC}", file=sys.stderr)

    def _run(cmd, **kw):
        return subprocess.run(cmd, **kw)

    def _find_good_python() -> str | None:
        """Return path to first Python 3.10+ found, explicitly skipping Xcode."""
        candidates = [
            "/opt/homebrew/bin/python3",   # Homebrew Apple Silicon (preferred)
            "/usr/local/bin/python3",       # Homebrew Intel
            "/usr/bin/python3",             # macOS system Python (may be 3.9)
        ]
        for p in candidates:
            if not os.path.isfile(p):
                continue
            # Skip anything inside Xcode or CommandLineTools
            try:
                real = os.path.realpath(p)
            except Exception:
                real = p
            if "Xcode" in real or "CommandLineTools" in real:
                continue
            try:
                r = _run([p, "-c",
                          "import sys; sys.exit(0 if sys.version_info>=(3,10) else 1)"],
                         capture_output=True)
                if r.returncode == 0:
                    return p
            except Exception:
                continue
        return None

    # ── Escape Xcode / old Python immediately, before doing anything else ────
    # If we're running inside Xcode or CommandLineTools, or Python is < 3.10,
    # silently re-exec with the best available Python right away.
    current_real = os.path.realpath(sys.executable)
    running_xcode = "Xcode" in current_real or "CommandLineTools" in current_real
    if running_xcode or sys.version_info < (3, 10):
        good = _find_good_python()
        if good and good != sys.executable:
            os.execv(good, [good] + sys.argv)
        # If no better Python found, fall through to the normal checks below

    # ── Check if current Python is already good ───────────────────────────────
    py_ok = sys.version_info >= (3, 10)

    # ── Check if we're running the wrong Python (e.g. Xcode) and a good one exists
    if not py_ok:
        good_py = _find_good_python()
        if good_py and good_py != sys.executable:
            # Re-exec silently with the better Python — user won't notice
            os.execv(good_py, [good_py] + sys.argv)
            # execv replaces the process; code below only runs if it fails

    # ── Collect what's still missing ─────────────────────────────────────────
    openpyxl_missing = False
    try:
        importlib.import_module("openpyxl")
    except ImportError:
        openpyxl_missing = True

    msoffcrypto_missing = False
    try:
        importlib.import_module("msoffcrypto")
    except ImportError:
        msoffcrypto_missing = True

    jamfcli_missing  = shutil.which("jamf-cli") is None
    brew_missing     = shutil.which("brew") is None
    python_old       = not py_ok

    anything_missing = python_old or openpyxl_missing or msoffcrypto_missing or jamfcli_missing

    # ── All good — check profiles and return ─────────────────────────────────
    if not anything_missing:
        # Probe that every flag in _JAMFCLI_QUIET_FLAGS (~line 1230) is
        # recognised by the installed jamf-cli binary. An unknown flag causes
        # Cobra to exit non-zero; run_cmd_maybe converts that to "" silently,
        # so a version mismatch would produce a workbook of blank sheets with
        # no error anywhere. Fail loudly here instead.
        # Keep this list in sync with _JAMFCLI_QUIET_FLAGS.
        _quiet_flags_probe = [
            "--no-update-check",
            "--no-version-check",
            "--no-hints",
            "--no-input",
        ]
        _probe = _run(
            ["jamf-cli"] + _quiet_flags_probe + ["--help"],
            capture_output=True,
        )
        if _probe.returncode != 0:
            print(file=sys.stderr)
            err("jamf-cli does not support one or more startup flags: "
                + " ".join(_quiet_flags_probe))
            err("Update jamf-cli (brew upgrade jamf-cli), or remove the "
                "unsupported flags from _JAMFCLI_QUIET_FLAGS (~line 1230).")
            sys.exit(1)
        _setup_jamfcli_profile_if_needed(
            _run, warn, ok, hdr, GREEN, YELLOW, RED, BOLD, NC
        )
        return

    # ── Something is missing — show summary and offer to fix ─────────────────
    print(file=sys.stderr)
    print(f"{BOLD}  Missing dependencies detected:{NC}", file=sys.stderr)
    print(file=sys.stderr)
    if python_old:
        major, minor = sys.version_info[:2]
        warn(f"Python 3.10+ required  (you have {major}.{minor} at {sys.executable})")
    if brew_missing:
        warn("Homebrew not installed  (needed to install jamf-cli and Python)")
    if openpyxl_missing:
        warn("openpyxl not installed  (Python package for Excel output)")
    if msoffcrypto_missing:
        warn("msoffcrypto-tool not installed  (encrypts the workbook on save)")
    if jamfcli_missing:
        warn("jamf-cli not found      (dataJAR CLI for Jamf Pro)")

    print(file=sys.stderr)
    if sys.stdin.isatty():
        try:
            answer = input("  Fix everything now? [ y / n ]: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            answer = "n"
            print(file=sys.stderr)
    else:
        answer = "n"

    # If the user declined "fix everything", fall through to per-item prompts
    # so they can pick exactly what to install. Items with unmet prerequisites
    # (e.g. jamf-cli when Homebrew was declined) will still try and fail with a
    # clear error in the install steps below.
    if answer not in ("", "y", "yes"):
        if not sys.stdin.isatty():
            print(file=sys.stderr)
            err("Setup skipped. Re-run when ready.")
            sys.exit(1)

        print(file=sys.stderr)
        print(f"{BOLD}  OK - let's go item by item:{NC}", file=sys.stderr)
        print(file=sys.stderr)

        def _ask(prompt: str) -> bool:
            try:
                a = input(f"  Install {prompt}? [ y / n ]: ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                print(file=sys.stderr)
                return False
            return a in ("", "y", "yes")

        # Ask in install order so prerequisites are decided first.
        if brew_missing and not _ask("Homebrew"):
            brew_missing = False  # treat as "user opted out"
        if python_old and not _ask("Python 3.10+ (via Homebrew)"):
            python_old = False
        if openpyxl_missing and not _ask("openpyxl (Python Excel library)"):
            openpyxl_missing = False
        if msoffcrypto_missing and not _ask("msoffcrypto-tool (workbook encryption)"):
            msoffcrypto_missing = False
        if jamfcli_missing and not _ask("jamf-cli"):
            jamfcli_missing = False

        # If they declined everything, exit cleanly.
        if not (brew_missing or python_old or openpyxl_missing or msoffcrypto_missing or jamfcli_missing):
            print(file=sys.stderr)
            err("Nothing selected. Re-run when ready.")
            sys.exit(1)

    all_ok = True

    # ── Step 1: Homebrew ──────────────────────────────────────────────────────
    if brew_missing:
        hdr("Installing Homebrew...")
        r = _run(["/bin/bash", "-c",
                  "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"])
        if r.returncode == 0:
            ok("Homebrew installed.")
            # Make brew available in this process
            for brew_path in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew"):
                if os.path.isfile(brew_path):
                    r2 = _run([brew_path, "shellenv"], capture_output=True, text=True)
                    for line in r2.stdout.splitlines():
                        if line.startswith("export "):
                            key, _, val = line[7:].partition("=")
                            os.environ[key] = val.strip('"')
                    break
        else:
            err("Homebrew install failed. Visit https://brew.sh and install manually.")
            all_ok = False

    brew = shutil.which("brew")

    # ── Step 2: Python 3.10+ ─────────────────────────────────────────────────
    if python_old:
        hdr("Installing Python 3 via Homebrew...")
        if brew:
            r = _run([brew, "install", "python"])
            if r.returncode == 0:
                ok("Python installed.")
            else:
                err("Python install failed.")
                all_ok = False
        else:
            err("Homebrew not available - cannot install Python automatically.")
            all_ok = False

    # ── Step 3: openpyxl ─────────────────────────────────────────────────────
    if openpyxl_missing:
        hdr("Installing openpyxl...")
        r = _run([sys.executable, "-m", "pip", "install",
                  "--break-system-packages", "openpyxl"])
        if r.returncode != 0:
            r = _run([sys.executable, "-m", "pip", "install", "openpyxl"])
        if r.returncode == 0:
            ok("openpyxl installed.")
        else:
            err("openpyxl install failed.  Try:  pip3 install openpyxl")
            all_ok = False

    # ── Step 3b: msoffcrypto-tool ────────────────────────────────────────────
    if msoffcrypto_missing:
        hdr("Installing msoffcrypto-tool...")
        r = _run([sys.executable, "-m", "pip", "install",
                  "--break-system-packages", "msoffcrypto-tool"])
        if r.returncode != 0:
            r = _run([sys.executable, "-m", "pip", "install", "msoffcrypto-tool"])
        if r.returncode == 0:
            ok("msoffcrypto-tool installed.")
        else:
            err("msoffcrypto-tool install failed.  Try:  pip3 install msoffcrypto-tool")
            all_ok = False

    # ── Step 4: jamf-cli ─────────────────────────────────────────────────────
    if jamfcli_missing:
        hdr("Installing jamf-cli...")
        if brew:
            _run([brew, "tap", "Jamf-Concepts/tap"])
            r = _run([brew, "install", "jamf-cli"])
            if r.returncode == 0:
                ok("jamf-cli installed.")
            else:
                err("jamf-cli install failed.")
                err("Try manually:  brew install Jamf-Concepts/tap/jamf-cli")
                all_ok = False
        else:
            err("Homebrew not available - cannot install jamf-cli automatically.")
            err("Install Homebrew first:  https://brew.sh")
            all_ok = False

    # ── Step 5: Fix PATH permanently ─────────────────────────────────────────
    if brew and not python_old:
        brew_prefix = _run([brew, "--prefix"], capture_output=True, text=True).stdout.strip()
        brew_bin = os.path.join(brew_prefix, "bin")
        shell = os.environ.get("SHELL", "")
        shell_rc = os.path.expanduser("~/.zshrc") if "zsh" in shell else os.path.expanduser("~/.bash_profile")
        shellenv_line = f'eval "$({brew_bin}/brew shellenv)"'
        try:
            existing = open(shell_rc).read() if os.path.isfile(shell_rc) else ""
            if "brew shellenv" not in existing:
                with open(shell_rc, "a") as f:
                    f.write(f"\n# Added by macOS Settings Export\n{shellenv_line}\n")
                ok(f"Homebrew PATH added to {shell_rc} for future sessions.")
        except Exception:
            pass

    # ── Re-exec with best available Python so fresh imports work ─────────────
    if not all_ok:
        print(file=sys.stderr)
        err("Some components could not be installed. Resolve the issues above and re-run.")
        sys.exit(1)

    print(file=sys.stderr)
    ok("All dependencies installed.")

    # If jamf-cli was just installed it won't have a profile — set one up now
    # before re-execing, while the user is already engaged.
    if jamfcli_missing and shutil.which("jamf-cli") is not None:
        _setup_jamfcli_profile_if_needed(
            _run, warn, ok, hdr, GREEN, YELLOW, RED, BOLD, NC
        )

    good_py = _find_good_python() or sys.executable
    print(f"\n  Re-launching with {good_py}...\n", file=sys.stderr)
    os.execv(good_py, [good_py] + sys.argv)


_check_dependencies()



import argparse
import csv
import fnmatch
import html
import io
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
from datetime import datetime
from typing import Any
import shutil
import xml.etree.ElementTree as ET
from openpyxl import Workbook
from openpyxl.styles import (
    Font, PatternFill, Alignment, Border, Side, GradientFill
)
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.table import Table, TableStyleInfo
from openpyxl.comments import Comment
import zipfile


# ── MJT auth bridge ──────────────────────────────────────────────────────────
# When invoked via report-jamfpro-configuration.sh the shell wrapper supplies --url and
# --token-file, bypassing jamf-cli's profile picker entirely.
_OVERRIDE_URL: "str | None" = None
_OVERRIDE_TOKEN_FILE: "str | None" = None


def _auth_args(profile_name: "str | None") -> list:
    """Return the right auth flags for a jamf-cli subcommand."""
    if _OVERRIDE_URL and _OVERRIDE_TOKEN_FILE:
        return ["--url", _OVERRIDE_URL, "--token-file", _OVERRIDE_TOKEN_FILE]
    if profile_name:
        return ["--profile", profile_name]
    return []


# ── Dash normalisation ───────────────────────────────────────────────────────
# The user dislikes long dashes. Map every Unicode hyphen/dash variant to a
# plain ASCII hyphen-minus so no output cell (including on-device-AI text,
# which loves em-dashes) ever carries a "—" or "–". Box-drawing "─" (U+2500,
# used in terminal rules) is deliberately NOT in this table.
_DASH_TRANSLATION = {
    ord("‐"): "-",  # HYPHEN
    ord("‑"): "-",  # NON-BREAKING HYPHEN
    ord("‒"): "-",  # FIGURE DASH
    ord("–"): "-",  # EN DASH
    ord("—"): "-",  # EM DASH
    ord("―"): "-",  # HORIZONTAL BAR
    ord("−"): "-",  # MINUS SIGN
}


def _dedash(value):
    """Replace long dashes with a plain hyphen. Non-strings pass through."""
    if isinstance(value, str):
        return value.translate(_DASH_TRANSLATION)
    return value


def _inject_ignored_errors(xlsx_bytes: bytes) -> bytes:
    """Add a per-sheet <ignoredErrors numberStoredAsText> block to every
    worksheet in an in-memory .xlsx package.

    openpyxl 3.x cannot emit ignoredErrors, so we patch the sheet XML
    directly. Every data cell is written as text (inlineStr), which is what
    we want — but Excel then decorates numeric-looking text ("18", "17.10",
    storage GB values, etc.) with a green "number stored as text" triangle.
    This suppresses that indicator across each sheet's used range while
    leaving the values as genuine text (so "17.10" never collapses to 17.1).

    Schema position: ignoredErrors must sit after pageMargins/pageSetup and
    before drawing/legacyDrawing/tableParts/extLst, so we insert immediately
    before the first of those (openpyxl always writes pageMargins earlier).
    """
    zin = zipfile.ZipFile(io.BytesIO(xlsx_bytes))
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if re.match(r"xl/worksheets/sheet\d+\.xml$", item.filename):
                xml = data.decode("utf-8")
                m = re.search(r'<dimension ref="([^"]+)"', xml)
                ref = m.group(1) if m else "A1"
                if ":" not in ref:
                    ref = f"{ref}:{ref}"
                frag = (
                    "<ignoredErrors><ignoredError sqref=\"%s\" "
                    "numberStoredAsText=\"1\"/></ignoredErrors>" % ref
                )
                anchor = re.search(
                    r"<legacyDrawing|<tableParts|<drawing|<extLst|</worksheet>",
                    xml,
                )
                if anchor and "<ignoredErrors" not in xml:
                    xml = xml[: anchor.start()] + frag + xml[anchor.start():]
                data = xml.encode("utf-8")
            zout.writestr(item, data)
    return out.getvalue()


def save_encrypted(wb, path, password):
    """Save the openpyxl workbook as an ECMA-376 Agile-Encrypted .xlsx.

    The workbook is first written to an in-memory buffer, then encrypted
    through msoffcrypto's OOXMLFile.encrypt() (the Python API; the CLI
    does not expose encryption). The result is a real password-to-open
    file that Excel/Numbers will prompt for, not openpyxl sheet protection.

    Note: the encryption code path inside msoffcrypto-tool is flagged
    experimental upstream. openpyxl cannot reopen the resulting file
    directly — decrypt first, then load.
    """
    from msoffcrypto.format.ooxml import OOXMLFile
    plain = io.BytesIO()
    wb.save(plain)
    # Patch in ignoredErrors (number-stored-as-text suppression) before
    # encrypting — the whole OOXML package is encrypted as opaque bytes, so
    # the edit must happen on the plaintext zip first.
    patched = io.BytesIO(_inject_ignored_errors(plain.getvalue()))
    patched.seek(0)
    office = OOXMLFile(patched)
    with open(path, "wb") as out:
        office.encrypt(password, out)


# ── Excel styling constants (datajar brand) ──────────────────────────────────
_PINK       = "E91E8C"   # magenta title bar
_PINK_LIGHT = "F8BBD9"   # light pink subtitle band
_GREY_HDR   = "F2F2F2"   # section header grey
_BORDER_CLR = "BDBDBD"   # thin border colour
_WHITE      = "FFFFFF"
_BLACK      = "000000"

# Sheet-tab colours used to visually pair related sheets. Each Health Check
# sheet and its Health Check Key share one colour so they read as a set.
_TAB_HC_MACOS = "1E88E5"   # blue  — macOS Health Check + macOS Health Check Key
_TAB_HC_IOS   = "43A047"   # green — iOS Health Check + iOS Health Check Key


def _side(colour: str = _BORDER_CLR) -> Side:
    return Side(style="thin", color=colour)


def _full_border(colour: str = _BORDER_CLR) -> Border:
    s = _side(colour)
    return Border(left=s, right=s, top=s, bottom=s)


def _inner_grid_border(
    col: int, ncols: int,
    top: Side | None = None,
    bottom: Side | None = None,
    edge: Side | None = None,
) -> Border:
    """Per-cell border that draws black vertical dividers between columns
    but never along the outer table edges.

    `col` is 1-based. `ncols` is the table width. `top`/`bottom` set the
    horizontal sides; `edge` is used for the outer left/right (thin grey
    by default — matches the existing in-cell row borders).

    The result: a sheet that reads as one table with crisp inner column
    separators and a clean outline rather than a heavy grid box.
    """
    _edge = edge if edge is not None else _side(_BORDER_CLR)
    _black = Side(style="thin", color=_BLACK)
    left  = _black if col > 1     else _edge
    right = _black if col < ncols else _edge
    return Border(
        left=left, right=right,
        top=top if top is not None else _side(_BORDER_CLR),
        bottom=bottom if bottom is not None else _side(_BORDER_CLR),
    )


def _fill(hex_colour: str) -> PatternFill:
    return PatternFill("solid", fgColor=hex_colour)


def _font(bold: bool = False, colour: str = _BLACK,
          size: int = 10, name: str = "Arial") -> Font:
    return Font(bold=bold, color=colour, size=size, name=name)


def _apply_title_row(ws, text: str, ncols: int) -> None:
    """Write title in col A, fill all columns pink — no merge so sorting never disrupts it.

    Title row height is fixed at 35 (Excel points) per Sanchi's preference —
    gives the pink title bar a consistent presence across sheets instead of
    shrinking to text height.
    """
    ws.append([_dedash(text)] + [""] * (ncols - 1))
    row = ws.max_row
    for col in range(1, ncols + 1):
        cell = ws.cell(row=row, column=col)
        cell.fill      = _fill(_PINK)
        cell.font      = _font(bold=True, colour=_WHITE, size=12)
        cell.alignment = Alignment(horizontal="left", vertical="center",
                                    wrap_text=True)
    ws.row_dimensions[row].height = 35


def _apply_column_headers(ws, headers: list[str]) -> None:
    """Bold magenta text, white background, thick black bottom border.

    Header row height is fixed at 35 (Excel "points") per Sanchi's preference
    — gives wrapped column titles room to breathe even when the underlying
    column is narrow. Note: openpyxl row heights are in Excel points, not
    pixels; the value reads visually similar at normal Excel zoom.
    """
    ws.append([_dedash(h) for h in headers])
    row = ws.max_row
    _thick_black = Side(style="medium", color=_BLACK)
    _thin_grey   = _side(_BORDER_CLR)
    _black_thin  = Side(style="thin", color=_BLACK)
    ncols = len(headers)
    for col, _ in enumerate(headers, 1):
        cell = ws.cell(row=row, column=col)
        cell.fill   = _fill(_WHITE)
        cell.font   = _font(bold=True, colour=_PINK)
        # Thick black bottom separates header from data. Inner vertical
        # dividers are black; outer table edges stay thin grey.
        left  = _black_thin if col > 1     else _thin_grey
        right = _black_thin if col < ncols else _thin_grey
        cell.border = Border(
            left=left, right=right,
            top=_thin_grey, bottom=_thick_black,
        )
        cell.alignment = Alignment(horizontal="left", vertical="center",
                                    wrap_text=True)
    # Fixed header height so wrapped column titles have room.
    ws.row_dimensions[row].height = 35


def _apply_section_header(ws, text: str, ncols: int) -> None:
    """Grey background, bold black, merged across columns."""
    ws.append([text])
    row = ws.max_row
    ws.merge_cells(start_row=row, start_column=1,
                   end_row=row, end_column=ncols)
    cell = ws.cell(row=row, column=1)
    cell.fill   = _fill(_GREY_HDR)
    cell.font   = _font(bold=True, colour=_BLACK)
    cell.border = _full_border()
    cell.alignment = Alignment(horizontal="left", vertical="center")


_GREY_50PCT = "808080"   # 50%-grey vertical separator used on Health Check Key


def _apply_data_row(
    ws, values: list, ncols: int,
    vertical_grid_50pct: bool = False,
    autoheight_wrap: bool = False,
    col_widths: list[int] | None = None,
) -> None:
    """White background, thin borders, wrap text. Blank values shown as '-'.

    vertical_grid_50pct: use a 50%-grey thin vertical border between columns
        (left/right edges of every cell) for sharper column separation. Top
        and bottom borders stay at the default light grey so rows don't get
        a heavy gridded look.
    autoheight_wrap / col_widths: retained for backwards-compat in the
        callsite signatures but no longer used. Row height is intentionally
        not set anywhere — Excel autofits from content when the file opens.
    """
    # Normalise: None or empty string → "-"; strip long dashes from text.
    normalised = [
        _dedash(v) if (v is not None and str(v).strip() != "") else "-"
        for v in values
    ]
    ws.append(normalised)
    row = ws.max_row

    _thin_light = _side(_BORDER_CLR)
    if vertical_grid_50pct:
        # Sheet-level 50%-grey override (Health Check Key) — keeps the
        # softer separator look on that single reference sheet.
        _thin_50 = Side(style="thin", color=_GREY_50PCT)
        _per_cell_border = lambda c: Border(
            left=_thin_50, right=_thin_50,
            top=_thin_light, bottom=_thin_light,
        )
    else:
        # Default rows: black inner vertical dividers, thin grey outer
        # edges. Top/bottom stay thin grey so horizontal lines don't bulk
        # up the gridded look.
        _per_cell_border = lambda c: _inner_grid_border(
            c, ncols, top=_thin_light, bottom=_thin_light,
        )

    for col in range(1, ncols + 1):
        cell = ws.cell(row=row, column=col)
        cell.fill      = _fill(_WHITE)
        cell.font      = _font()
        cell.border    = _per_cell_border(col)
        cell.alignment = Alignment(horizontal="left", vertical="center",
                                    wrap_text=True)
    # Row height intentionally NOT set — let Excel autofit on open.



def _apply_summary_sheet(ws, rows: list[list], ncols: int) -> None:
    """Write Jamf MSP Summary rows with special formatting:
    - Section header rows (first cell starts/ends with '+') → bold black, thick bottom border
    - Empty rows → thin grey border, no fill change (acts as visual spacer)
    - Data rows → normal _apply_data_row styling
    - No '-' substitution — blank cells stay blank
    """
    _thick_black  = Side(style="medium", color=_BLACK)
    _thin_grey    = _side(_BORDER_CLR)
    _black_thin   = Side(style="thin", color=_BLACK)
    _section_fill = _fill("F5F5F5")  # very light grey for section headers

    def _summary_border(col: int, *, section: bool) -> Border:
        # Section banners get a thick black bottom; everything else uses
        # the standard thin grey. Inner vertical dividers are black on
        # every row type so the column grid stays visible across sections.
        left  = _black_thin if col > 1     else _thin_grey
        right = _black_thin if col < ncols else _thin_grey
        return Border(
            left=left, right=right,
            top=_thin_grey,
            bottom=_thick_black if section else _thin_grey,
        )

    for row_values in rows:
        _dd = [_dedash(v) for v in row_values]
        ws.append(_dd + [""] * max(0, ncols - len(_dd)))
        row_idx = ws.max_row
        first_val = str(row_values[0]) if row_values else ""
        is_section = first_val.startswith("+") and first_val.endswith("+")
        is_blank   = first_val == "" and (len(row_values) < 2 or str(row_values[1]) == "")

        for col in range(1, ncols + 1):
            cell = ws.cell(row=row_idx, column=col)
            # Don't substitute blank with "-" — leave empty
            if cell.value in (None, ""):
                cell.value = None
            if is_section:
                cell.fill   = _section_fill
                cell.font   = _font(bold=True, colour=_BLACK, size=10)
                cell.border = _summary_border(col, section=True)
                cell.alignment = Alignment(horizontal="left", vertical="center")
            elif is_blank:
                cell.fill   = _fill(_WHITE)
                cell.font   = _font()
                cell.border = _summary_border(col, section=False)
                cell.alignment = Alignment(horizontal="left", vertical="center")
            else:
                cell.fill   = _fill(_WHITE)
                cell.font   = _font()
                cell.border = _summary_border(col, section=False)
                cell.alignment = Alignment(horizontal="left", vertical="center",
                                            wrap_text=True)
        # Row heights intentionally NOT set — Excel autofits on open.

def _autofit_columns(
    ws,
    min_width: int = 10,
    max_width: int = 60,
) -> None:
    """Size each column to fit its content as default behaviour.

    Per-cell rule:
      * Cell contains "\\n" → contributes its LONGEST individual line,
        uncapped. The "\\n"s are intentional breaks (Targets, Limitations,
        Exclusions, multi-line group lists), so no individual line should
        be re-wrapped by a too-narrow column.
      * Cell has no "\\n" → contributes its character length, capped at
        `max_width`. That keeps prose columns (Notes, Description) at a
        readable ~60 chars and lets Excel wrap long paragraphs.

    The final column width is the max of those contributions across all
    cells in the column, padded by 2 for breathing room and floored at
    `min_width`.
    """
    for col_cells in ws.columns:
        col_idx    = col_cells[0].column
        col_letter = get_column_letter(col_idx)

        widest = 0
        for c in col_cells:
            if c.value is None:
                continue
            s = str(c.value)
            if "\n" in s:
                # Multi-line cell: every line must fit on one row.
                for line in s.split("\n"):
                    if len(line) > widest:
                        widest = len(line)
            else:
                # Single-line cell: contribute its length, but only up
                # to the wrap cap so a 600-char paragraph doesn't blow
                # the column out.
                contribution = min(len(s), max_width)
                if contribution > widest:
                    widest = contribution

        ws.column_dimensions[col_letter].width = max(widest + 2, min_width)


def _freeze_header_rows(ws, freeze_row: int = 3) -> None:
    """Freeze rows above freeze_row (title + column headers)."""
    ws.freeze_panes = ws.cell(row=freeze_row, column=1)


def _trim_empty_rows_cols(ws, header_rows: int = 2) -> None:
    """Delete columns and rows that contain no data in the data region (rows 3+).
    Header rows (title + column headers) are never removed.
    Deletions run in reverse so indices stay valid.
    """
    def _blank(cell) -> bool:
        v = cell.value
        return v is None or str(v).strip() in ("", "-")

    max_row = ws.max_row
    max_col = ws.max_column

    # Empty columns — check data region only
    empty_cols = [
        col for col in range(1, max_col + 1)
        if all(_blank(ws.cell(row=r, column=col))
               for r in range(header_rows + 1, max_row + 1))
    ]
    for col in reversed(empty_cols):
        ws.delete_cols(col)

    # Recalculate after column deletions
    max_row = ws.max_row
    max_col = ws.max_column

    # Empty rows — skip header rows
    empty_rows = [
        row for row in range(header_rows + 1, max_row + 1)
        if all(_blank(ws.cell(row=row, column=c))
               for c in range(1, max_col + 1))
    ]
    for row in reversed(empty_rows):
        ws.delete_rows(row)



def build_workbook(sheets: dict[str, dict]) -> Workbook:
    """Build a styled workbook.

    sheets: {
        "Sheet Name": {
            "title": str,          # title bar text
            "headers": [str, ...], # column header labels
            "rows": [[...], ...],  # data rows (list of lists)
            # optional:
            "section_col": int,    # 0-based index of column used as section header
                                   # when value has no other columns (omit if unused)
        }
    }
    """
    wb = Workbook()
    wb.remove(wb.active)  # remove default blank sheet

    for sheet_name, spec in sheets.items():
        ws = wb.create_sheet(title=sheet_name)
        # Shared sheet-tab colour ties related sheets together (e.g. a Health
        # Check sheet and its Health Check Key share one colour).
        _tab = spec.get("tab_color")
        if _tab:
            ws.sheet_properties.tabColor = _tab
        headers  = spec["headers"]
        ncols    = len(headers)
        title    = spec.get("title", sheet_name)

        _apply_title_row(ws, title, ncols)
        _apply_column_headers(ws, headers)
        _freeze_header_rows(ws, freeze_row=3)

        rows = spec.get("rows", [])
        _vgrid_50 = bool(spec.get("vertical_grid_50pct"))
        _auto_wrap = bool(spec.get("autoheight_wrap"))

        if spec.get("summary_style"):
            _apply_summary_sheet(ws, rows, ncols)
        else:
            # Estimate column widths up-front so autoheight_wrap can size
            # rows correctly. Same logic as _autofit_columns but excluding
            # the row we're about to write (we don't have a chicken-and-egg).
            _col_width_hints: list[int] = []
            if _auto_wrap:
                _col_width_hints = [
                    min(60, max(10, max(
                        (len(str(r[i])) if i < len(r) and r[i] is not None else 0)
                        for r in rows
                    ) if rows else 10) + 2)
                    for i in range(ncols)
                ]
            for row_values in rows:
                _apply_data_row(
                    ws, list(row_values), ncols,
                    vertical_grid_50pct=_vgrid_50,
                    autoheight_wrap=_auto_wrap,
                    col_widths=_col_width_hints or None,
                )

        _autofit_columns(ws)

        # Remove empty rows and columns from data region. Skip when a sheet
        # opts out (e.g. the Orphans sheet, which post-decorates by cell
        # address after build_workbook returns and so needs stable indices).
        _did_trim = not spec.get("skip_trim")
        if _did_trim:
            _trim_empty_rows_cols(ws, header_rows=2)

        # ── Apply per-cell hyperlinks ────────────────────────────────────────
        # Spec key: "hyperlinks" → dict mapping (data_row_idx_0based,
        # col_idx_0based) to url. Applied AFTER trim so row indices reflect
        # the final layout.
        #
        # Row math: build_workbook reserves rows 1 (title) and 2 (column
        # headers). _freeze_header_rows side-effectively materialises an
        # empty row 3 via ws.cell(row=3, ...). When trim runs that blank
        # row gets removed, so data rows start at Excel row 3. When trim
        # is skipped, the blank row sticks and data starts at row 4.
        _hyperlinks = spec.get("hyperlinks") or {}
        if _hyperlinks:
            _data_row_start = 3 if _did_trim else 4
            for (data_idx, col_idx), url in _hyperlinks.items():
                if not url:
                    continue
                excel_row = data_idx + _data_row_start
                excel_col = col_idx + 1
                if excel_row > ws.max_row or excel_col > ws.max_column:
                    continue
                cell = ws.cell(row=excel_row, column=excel_col)
                cell.hyperlink = url
                # The "Hyperlink" built-in named style gives blue underlined
                # text. Fall back to manual styling if Excel ever drops the
                # named style.
                try:
                    cell.style = "Hyperlink"
                except (KeyError, ValueError):
                    cell.font = Font(color="0563C1", underline="single")
                # Re-assert vertical centering — assigning a named style can
                # reset alignment back to Excel defaults (top-left).
                cell.alignment = Alignment(
                    horizontal="left", vertical="center", wrap_text=True
                )

        # ── Hover tooltips for Health Check issues ───────────────────────────
        # Spec key "issue_comment_platform" ("macos" | "ios") attaches an
        # Excel cell comment to each Issues cell, listing every flagged issue
        # with its "why it matters" definition. This makes the Health Check
        # Key's explanations available inline, right where the issue appears,
        # so the two sheets read as one connected pair. Multiple issues per
        # cell each get their own block. Runs after trim so the Issues column
        # is located by its header rather than a fixed index.
        _icp = spec.get("issue_comment_platform")
        if _icp:
            _issues_col = None
            for _c in range(1, (ws.max_column or 0) + 1):
                if str(ws.cell(row=2, column=_c).value or "").strip().lower() == "issues":
                    _issues_col = _c
                    break
            if _issues_col is not None:
                for _r in range(3, (ws.max_row or 2) + 1):
                    _cell = ws.cell(row=_r, column=_issues_col)
                    _ctext = _build_health_comment(_cell.value, _icp)
                    if not _ctext:
                        continue
                    _cm = Comment(_ctext, "Jamf Health Check")
                    _cm.width = 380
                    # Rough height: ~15pt per line plus padding, so the box
                    # opens large enough to show all stacked explanations.
                    _cm.height = 30 + 15 * (_ctext.count("\n") + 1)
                    _cell.comment = _cm

        # Row heights are intentionally left unset everywhere so Excel
        # autofits from content when the file is opened. No min-height
        # enforcement, no explicit ws.row_dimensions[r].height assignments
        # anywhere upstream — content drives row size on open.

        # Register as an Excel Table for fixed-schema sheets only.
        # Skip matrix/summary sheets, and recompute dimensions from the actual
        # worksheet after trimming — ncols may be smaller now.
        _skip_table = spec.get("summary_style") or spec.get("matrix_style")
        if not _skip_table:
            _actual_ncols = ws.max_column or 1
            _actual_nrows = ws.max_row or 2
            # Only register a table if we have at least a header row
            if _actual_nrows > 2 and _actual_ncols >= 1:
                header_row = 2
                last_row   = max(header_row, _actual_nrows)
                last_col   = get_column_letter(_actual_ncols)
                table_ref  = f"A{header_row}:{last_col}{last_row}"
                safe_name  = "Tbl_" + "".join(
                    c if c.isalnum() else "_" for c in sheet_name
                )
                tbl = Table(displayName=safe_name, ref=table_ref)
                tbl.tableStyleInfo = TableStyleInfo(
                    name="TableStyleLight1",
                    showFirstColumn=False,
                    showLastColumn=False,
                    showRowStripes=False,
                    showColumnStripes=False,
                )
                ws.add_table(tbl)

    return wb
# ─────────────────────────────────────────────────────────────────────────────


def _decorate_orphans_sheet(wb, sheet_name: str, spec: dict) -> None:
    """Post-build decoration for the Orphans sheet.

    The "Done" tick-box column was removed from the Orphans sheets, so the
    only thing this used to do — apply a data-validation dropdown on that
    column — no longer applies. Hyperlinks are handled by the generic
    mechanism inside build_workbook via the spec's "hyperlinks" key.

    The function is kept (and still called from main) as a stable hook
    in case future decorations need to be added per-sheet without changing
    the build_workbook contract.
    """
    if sheet_name not in wb.sheetnames:
        return
    # No-op while the Done column is absent. Intentional.
    return


# ── Terminal table display ────────────────────────────────────────────────────

def _term_table(headers: list[str], rows: list[list], title: str = "") -> None:
    """Print a formatted table to the terminal, respecting terminal width."""
    term_width = shutil.get_terminal_size((120, 40)).columns
    ncols = len(headers)
    if not rows:
        print("  (no data)")
        return

    col_widths = [len(str(h)) for h in headers]
    for row in rows:
        for i, cell in enumerate(row[:ncols]):
            col_widths[i] = max(col_widths[i], len(str(cell) if cell is not None else ""))

    separator_total = (ncols - 1) * 3 + 4
    available = term_width - separator_total
    total_natural = sum(col_widths)
    if total_natural > available and available > 0:
        col_widths = [max(4, int(w * available / total_natural)) for w in col_widths]

    def _fmt_row(row_values: list) -> str:
        cells = []
        for i, val in enumerate(row_values[:ncols]):
            s = str(val) if val is not None else ""
            w = col_widths[i]
            cells.append(s[:w].ljust(w))
        return "| " + " | ".join(cells) + " |"

    divider = "+-" + "-+-".join("-" * w for w in col_widths) + "-+"

    if title:
        print()
        print(f"  {title}")
    print(divider)
    print(_fmt_row(headers))
    print(divider)
    for row in rows:
        print(_fmt_row(row))
    print(divider)
    print(f"  {len(rows)} row(s)")
    print()

# ─────────────────────────────────────────────────────────────────────────────


# ── Progress display ──────────────────────────────────────────────────────────

def _progress(current: int, total: int, label: str, width: int = 30) -> None:
    """Print a single-line progress bar to stderr.

    Format:
      43%  ████████████░░░░░░░░░░░░░░░░░░  142/328

    Overwrites the line each tick. Leaves it on screen at 100%.
    """
    if total == 0:
        return
    pct = current / total
    filled = int(width * pct)
    bar = "█" * filled + "░" * (width - filled)
    bar_line = f"  {int(pct*100):3d}%  {bar}  {current}/{total}"

    if current >= total:
        print(f"\033[2K{bar_line}", file=sys.stderr, flush=True)
    else:
        print(f"\033[2K{bar_line}", end="\r", file=sys.stderr, flush=True)


def _section_start(name: str) -> None:
    print(f"\n→ {name}...", file=sys.stderr, flush=True)


def _section_done(name: str, count: int) -> None:
    print(f"  ✓ {name}: {count} item(s)", file=sys.stderr, flush=True)

# ─────────────────────────────────────────────────────────────────────────────



# Global jamf-cli flags appended to every non-interactive read this script
# makes. A full export spawns hundreds of jamf-cli processes and each one
# would otherwise run a daily release check and a tenant version
# compatibility check before doing any work. These all write to stderr, so
# suppressing them changes nothing about the parsed stdout.
#
#   --no-update-check   skip the daily "newer jamf-cli available" check
#   --no-version-check  skip the tenant version compatibility check
#   --no-hints          suppress advisory hints (e.g. large-result tips)
#   --no-input          never prompt; fail instead of blocking forever
#
# --no-input is safe here specifically because run_cmd / run_cmd_maybe are
# only ever used for machine reads. The interactive profile setup path uses
# its own `_run` wrapper and is deliberately left alone.
_JAMFCLI_QUIET_FLAGS = [
    "--no-update-check",
    "--no-version-check",
    "--no-hints",
    "--no-input",
]


def _with_quiet_flags(cmd: list[str]) -> list[str]:
    """Append the startup-check suppression flags to a jamf-cli command.

    No-ops for any command that isn't jamf-cli, and never appends a flag
    that the caller already set.
    """
    if not cmd:
        return cmd
    if "jamf-cli" not in str(cmd[0]):
        return cmd
    out = list(cmd)
    for flag in _JAMFCLI_QUIET_FLAGS:
        if flag not in out:
            out.append(flag)
    return out


def run_cmd(cmd: list[str]) -> str:
    cmd = _with_quiet_flags(cmd)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip()
        stdout = (proc.stdout or "").strip()
        detail = stderr or stdout or f"exit code {proc.returncode}"
        raise RuntimeError(f"Command failed: {' '.join(cmd)}\n{detail}")
    return proc.stdout


def run_cmd_maybe(cmd: list[str]) -> str:
    cmd = _with_quiet_flags(cmd)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return ""
    return proc.stdout


def _lazy_raw_xml(fetch, *args):
    """Return a memoised zero-arg callable that fetches raw XML on first use.

    The Classic API detail helpers (`extract_scope_groups`,
    `extract_policy_scripts`, `extract_mac_app_scope`) all read the JSON
    response first and only fall back to raw XML when the JSON path yields
    nothing. That fallback is rare, but the loops used to fetch the raw XML
    eagerly for every single item, doubling the API calls for the whole
    export. Passing one of these callables instead defers the fetch until a
    fallback actually needs it, and memoises it so multiple fallbacks in the
    same iteration still cost at most one call.

    The helpers resolve it via `_resolve_raw_xml`, so they continue to accept
    a plain string from any caller that already has the XML in hand (the
    config-profile loop, which needs it unconditionally for the payload
    plist).
    """
    box: list[str] = []

    def _get() -> str:
        if not box:
            box.append(fetch(*args) or "")
        return box[0]

    return _get


def _resolve_raw_xml(raw_xml: Any) -> str:
    """Coerce a raw-XML argument to a string.

    Accepts either an XML string or a zero-arg callable returning one (see
    `_lazy_raw_xml`). Failures degrade to an empty string so the JSON-only
    result stands rather than aborting the export.
    """
    if callable(raw_xml):
        try:
            return raw_xml() or ""
        except Exception:
            return ""
    return raw_xml or ""


def parse_json(s: str) -> Any:
    try:
        return json.loads(s)
    except Exception:
        return None


def _truthy(v: Any) -> bool:
    """Robust boolean coercion.

    Catches the trap where jamf-cli (and the underlying classic API)
    sometimes return scope flags as JSON booleans (`true`/`false`) and
    sometimes as strings (`"true"`/`"false"`) or integers (1/0). Plain
    `bool("false")` is `True` in Python, which previously caused
    correctly all-scoped items to be miscategorised as orphans.
    """
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    if isinstance(v, (int, float)):
        return v != 0
    s = str(v).strip().lower()
    return s in ("true", "yes", "1", "on", "enabled")


def scope_targets_all(scope: dict | None) -> bool:
    """Return True if a scope dict targets ALL devices for its platform.

    "All Computers" / "All Mobile Devices" is a valid scope — items
    using it are NOT orphans. This helper handles every spelling and
    nesting we've seen in the wild:

        all_computers / allComputers              (macOS classic / modern)
        all_mobile_devices / allMobileDevices     (iOS classic / modern)

    The scope object is sometimes returned wrapped (`{"scope": {...}}`)
    when an endpoint hands back the whole policy/profile object instead
    of just the scope subtree. We descend one level when that happens.
    """
    if not isinstance(scope, dict):
        return False
    if "scope" in scope and isinstance(scope["scope"], dict):
        scope = scope["scope"]
    for key in ("all_computers", "allComputers",
                "all_mobile_devices", "allMobileDevices"):
        if key in scope and _truthy(scope[key]):
            return True
    return False


def fetch_instance_overview(profile_name: str | None) -> dict[str, str]:
    """Call pro overview and return a flat {resource: value} dict."""
    cmd = ["jamf-cli", "pro", "overview", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    result: dict[str, str] = {}
    if isinstance(data, list):
        for item in data:
            r = str(item.get("resource") or "").strip()
            v = str(item.get("value") or "").strip()
            if r:
                result[r] = v
    return result


def fetch_jamf_pro_version(profile_name: str | None) -> str:
    """Return the clean Jamf Pro version string (strips build suffix)."""
    cmd = ["jamf-cli", "pro", "jamf-pro-versions", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        raw = str(data.get("version") or "")
        # Strip build suffix: "11.28.1-t1779801919649" → "11.28.1"
        return raw.split("-")[0] if raw else ""
    return ""


def fetch_laps_settings(profile_name: str | None) -> dict[str, Any]:
    """Return Jamf Pro LAPS settings as a flat dict.

    Calls `pro local-admin-passwords settings`. Returns {} on any failure so
    the rest of the report can continue.

    Typical keys (Jamf Pro 11.x):
      autoDeployEnabled, passwordRotationTime, autoExpirationTime,
      autoRotateEnabled, autoRotateExpirationTime
    """
    cmd = ["jamf-cli", "pro", "local-admin-passwords", "settings",
           "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    return data if isinstance(data, dict) else {}


def fetch_sso_settings(profile_name: str | None) -> dict[str, Any]:
    """Return current SSO configuration. Empty dict on failure."""
    cmd = ["jamf-cli", "pro", "sso-settings", "get", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    return data if isinstance(data, dict) else {}


def fetch_cloud_ldap_servers(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all configured Cloud Identity Provider (Cloud LDAP) configs."""
    cmd = ["jamf-cli", "pro", "cloud-ldaps", "get", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        # Some shapes wrap results under "results" or return a single config.
        if "results" in data and isinstance(data["results"], list):
            return data["results"]
        return [data] if data else []
    return []


def fetch_active_alerts(profile_name: str | None) -> list[str]:
    """Return the active Jamf Pro alerts/notifications as a list of strings.

    Calls `pro notifications list`. Each item is normalised to a human-
    readable label using the `type` field plus relevant `params` (e.g.
    expiring-certificate alerts get the cert name and expiry date).
    Returns [] on any failure so the rest of the summary still renders.
    """
    cmd = ["jamf-cli", "pro", "notifications", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        items = data.get("results") or data.get("notifications") or []
    elif isinstance(data, list):
        items = data
    else:
        items = []

    def _humanise_type(t: str) -> str:
        # Convert UPPER_SNAKE_CASE_TYPES → "Upper Snake Case Types".
        return " ".join(w.capitalize() for w in t.replace("_", " ").split())

    out: list[str] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        t = str(it.get("type") or it.get("notificationType") or "").strip()
        if not t:
            continue
        label = _humanise_type(t)
        # Append a snippet from params if there's a recognisable name/date.
        params = it.get("params") or {}
        if isinstance(params, dict):
            _name = (params.get("name") or params.get("certName")
                     or params.get("instanceName") or "")
            _date = (params.get("expiryDate") or params.get("expirationDate")
                     or params.get("date") or "")
            extras = []
            if _name:
                extras.append(str(_name))
            if _date:
                extras.append(str(_date))
            if extras:
                label = f"{label} — {' · '.join(extras)}"
        out.append(label)
    return out


def fetch_jamf_connect_deployments(profile_name: str | None) -> int:
    """Return the number of Jamf Connect deployment configurations.

    Jamf Connect deployments are tied to config profiles; the API exposes
    one entry per profile that includes a Connect config block.
    """
    cmd = ["jamf-cli", "pro", "jamf-connects", "list", "--all",
           "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return len(data)
    if isinstance(data, dict):
        results = data.get("results") or data.get("data") or []
        if isinstance(results, list):
            return len(results)
    return 0


def fetch_jamf_protect_status(profile_name: str | None) -> dict[str, Any]:
    """Return the Jamf Protect integration settings, or {} if absent."""
    cmd = ["jamf-cli", "pro", "jamf-protect", "get", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    return data if isinstance(data, dict) else {}


def fetch_jamf_protect_plans(profile_name: str | None) -> list[dict[str, Any]]:
    """Return the synced Jamf Protect Plans (with associated config-profile info)."""
    cmd = ["jamf-cli", "pro", "jamf-protect-plans", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("results", []) or data.get("plans", []) or []
    return []


def _jamf_protect_configured(status: dict[str, Any], plans: list) -> bool:
    """True if the tenant actually has Jamf Protect set up (else the sheet is omitted).

    Signals: any synced Plans, or a non-empty registration/URL/client id on the
    integration settings. Blank defaults or a 404 (→ {}) count as not configured.
    """
    if plans:
        return True
    if not isinstance(status, dict) or not status:
        return False
    for k in ("registrationId", "protectCloudUrl", "protectUrl",
              "registrationUrl", "apiClientId", "id"):
        v = status.get(k)
        if isinstance(v, str) and v.strip():
            return True
        if isinstance(v, int) and not isinstance(v, bool) and v:
            return True
    return False


def build_jamf_protect_sheet(status: dict[str, Any],
                             plans: list[dict[str, Any]]) -> dict | None:
    """Build the 'Jamf Protect' sheet spec, or None when Protect isn't set up.

    One key/value sheet: the Jamf Pro <-> Jamf Protect integration settings, then
    the synced Plans and the configuration profile each maps to. (Jamf Protect's
    own product config lives in the separate Protect tenant and isn't reachable
    from the Jamf Pro API.)
    """
    if not _jamf_protect_configured(status, plans):
        return None

    def g(d, *keys):
        for k in keys:
            v = d.get(k) if isinstance(d, dict) else None
            if v not in (None, ""):
                return v
        return ""

    def yn(v):
        if isinstance(v, bool):
            return "Yes" if v else "No"
        return v if v not in (None, "") else ""

    rows: list[list] = []
    rows.append(["Integration", ""])
    rows.append(["  Jamf Protect cloud URL", g(status, "protectCloudUrl", "protectUrl", "registrationUrl")])
    rows.append(["  API client ID", g(status, "apiClientId", "clientId")])
    rows.append(["  API client enabled", yn(status.get("apiClientEnabled"))])
    rows.append(["  Auto-install Jamf Protect", yn(status.get("autoInstall"))])
    rows.append(["  Registration ID", g(status, "registrationId")])
    rows.append(["  Last sync", g(status, "lastSyncTime", "syncTime")])

    rows.append(["", ""])
    rows.append([f"Synced Plans ({len(plans)})", ""])
    if plans:
        for p in plans:
            name = g(p, "name", "planName", "displayName") or "(unnamed plan)"
            prof = g(p, "profileName", "configurationProfileName",
                     "scope", "profileId", "profileUuid")
            rows.append([f"  {name}", (f"config profile: {prof}" if prof else "")])
    else:
        rows.append(["  (integration set up; no Plans synced yet)", ""])

    return {
        "title": "Jamf Protect  |  Integration settings and synced Plans",
        "headers": ["Setting", "Value"],
        "rows": rows,
    }




def list_profiles(profile_name: str | None) -> list[dict[str, Any]]:
    cmd = ["jamf-cli", "pro", "classic-macos-config-profiles", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("os_x_configuration_profiles", []) or []
    return []


def list_policies(profile_name: str | None) -> list[dict[str, Any]]:
    cmd = ["jamf-cli", "pro", "classic-policies", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("policies", []) or []
    return []


def get_policy_json(policy_id: int, profile_name: str | None) -> dict[str, Any]:
    cmd = ["jamf-cli", "pro", "classic-policies", "get", str(policy_id), "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        return data
    return {}


def get_policy_raw_xml(policy_id: int, profile_name: str | None) -> str:
    cmd = ["jamf-cli", "pro", "classic-policies", "get", str(policy_id), "--output", "raw"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    return run_cmd_maybe(cmd)


def get_policy_scope_json(policy_id: int, profile_name: str | None) -> dict[str, Any]:
    """Return the scope subtree from a policy's full JSON.

    NOT CALLED by the policy loop any more, and kept only so the reasoning
    below does not get lost. Because the workaround described here fetches the
    entire policy record, this function issued a command byte-identical to
    `get_policy_json` and then threw away everything except `["scope"]`. That
    made every policy cost two identical API calls. The loop now reads
    `pjson["scope"]` directly. Do not reintroduce a call to this from any hot
    path; if you need a policy's scope, you almost certainly already have the
    full record in hand.

    Implementation note (still true, and the reason `scope get` is unusable):
    we deliberately do NOT use `pro classic-policies scope get <id>`. That
    subcommand only resolves policies by NAME (hits
    `/JSSResource/policies/name/<arg>`) and there is no flag to force by-id
    lookup, so when called with a numeric ID it 404s for every policy whose
    literal name isn't that number. This silently broke every macOS policy
    scope fetch on tenants where IDs and names never match (i.e. every real
    tenant). Calling `classic-policies get <id>` works with positional ID, and
    the response already contains the `scope` subtree.
    """
    cmd = ["jamf-cli", "pro", "classic-policies", "get",
           str(policy_id), "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        scope = data.get("scope")
        if isinstance(scope, dict):
            return scope
    return {}


def list_classic_printers(profile_name: str | None) -> list[dict[str, Any]]:
    """Return printers configured in Jamf Pro via the Classic API.

    Tries `pro classic-printers list` first (the conventional jamf-cli noun);
    if that fails (the noun isn't shipped in all jamf-cli builds yet), falls
    back to the raw `/JSSResource/printers` endpoint via `pro raw GET`.
    Returns [] silently on failure so the rest of the export still runs.

    Each entry is normalised to a dict with at least `id` and `name`. Detail
    fields (uri, model, location, cups_name, make_default, use_generic) are
    populated by a follow-up `get` call where available; the list endpoint
    on its own only returns id/name.
    """
    out: list[dict[str, Any]] = []

    cmd = ["jamf-cli", "pro", "classic-printers", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))

    items: list[Any] = []
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        items = data.get("printers") or data.get("results") or []

    # Raw fallback when the modern noun isn't present in this jamf-cli build.
    if not items:
        raw_cmd = ["jamf-cli", "pro", "raw", "GET",
                   "/JSSResource/printers", "--output", "json"]
        if profile_name:
            raw_cmd.extend(_auth_args(profile_name))
        raw_data = parse_json(run_cmd_maybe(raw_cmd))
        if isinstance(raw_data, dict):
            items = raw_data.get("printers") or []

    for it in items:
        if not isinstance(it, dict):
            continue
        pid = it.get("id")
        try:
            pid_int = int(pid) if pid is not None else None
        except (TypeError, ValueError):
            pid_int = None
        if pid_int is None:
            continue
        out.append({
            "id":   pid_int,
            "name": str(it.get("name") or ""),
        })
    return out


def get_classic_printer_json(printer_id: int, profile_name: str | None) -> dict[str, Any]:
    """Return the full detail for a single classic printer.

    Tries `pro classic-printers get <id>` first; falls back to
    `pro raw GET /JSSResource/printers/id/<id>` when the noun is missing.
    Returns {} on failure.
    """
    cmd = ["jamf-cli", "pro", "classic-printers", "get",
           str(printer_id), "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict) and data:
        # API may return the body directly or wrapped under "printer".
        inner = data.get("printer")
        return inner if isinstance(inner, dict) else data

    raw_cmd = ["jamf-cli", "pro", "raw", "GET",
               f"/JSSResource/printers/id/{printer_id}",
               "--output", "json"]
    if profile_name:
        raw_cmd.extend(_auth_args(profile_name))
    raw_data = parse_json(run_cmd_maybe(raw_cmd))
    if isinstance(raw_data, dict):
        inner = raw_data.get("printer")
        if isinstance(inner, dict):
            return inner
        return raw_data
    return {}


def list_scripts(profile_name: str | None) -> list[dict[str, Any]]:
    """Return the full list of scripts known to Jamf Pro.

    Uses the modern `pro scripts list --all`. Results are normalised to a flat
    list of dicts with at least `id` and `name`. Returns [] if the call fails
    so the rest of the export still runs.
    """
    cmd = ["jamf-cli", "pro", "scripts", "list", "--all", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        # Common envelopes: {"results": [...]}, {"scripts": [...]}, paged wrappers.
        items = data.get("results") or data.get("scripts") or []
    else:
        items = []

    out: list[dict[str, Any]] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        sid = it.get("id")
        try:
            sid_int = int(sid) if sid is not None else None
        except (TypeError, ValueError):
            sid_int = None
        if sid_int is None:
            continue
        out.append({
            "id":      sid_int,
            "name":    str(it.get("name") or ""),
            "notes":   str(it.get("notes") or ""),
            "body":    str(it.get("scriptContents") or ""),
        })
    return out



def list_computer_eas(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all computer extension attributes from Jamf Pro.

    Uses `pro classic-computer-extension-attributes list --all`. Results are
    normalised to a flat list of dicts with at least `id`, `name`, and
    `description`. Returns [] on failure so the rest of the export still runs.
    """
    cmd = ["jamf-cli", "pro", "computer-extension-attributes",
           "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        items = (data.get("results")
                 or data.get("computer_extension_attributes")
                 or [])
    else:
        items = []

    out: list[dict[str, Any]] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        eid = it.get("id")
        try:
            eid_int = int(eid) if eid is not None else None
        except (TypeError, ValueError):
            eid_int = None
        if eid_int is None:
            continue
        # `enabled` is a classic-API field on computer-extension-attributes.
        # Captured here so the Orphans sheet can surface disabled EAs.
        out.append({
            "id":             eid_int,
            "name":           str(it.get("name") or ""),
            "description":    str(it.get("description") or ""),
            "inputType":      str(it.get("inputType") or ""),
            "scriptContents": str(it.get("scriptContents") or ""),
            "enabled":        bool(it.get("enabled", True)),
        })
    return out


def list_packages(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all packages (pkg, dmg, etc.) registered in Jamf Pro.

    Uses `pro packages list`. Items are normalised to a flat list of dicts
    with at least `id` and `name`. Returns [] on failure.
    """
    cmd = ["jamf-cli", "pro", "packages", "list", "--all", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        items = (data.get("results")
                 or data.get("packages")
                 or [])
    else:
        items = []

    out: list[dict[str, Any]] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        pkg_id = it.get("id")
        try:
            pkg_id_int = int(pkg_id) if pkg_id is not None else None
        except (TypeError, ValueError):
            pkg_id_int = None
        if pkg_id_int is None:
            continue
        out.append({
            "id":       pkg_id_int,
            "name":     str(it.get("name") or it.get("fileName") or ""),
            "filename": str(it.get("fileName") or ""),
            "category": str(it.get("categoryName")
                            or (it.get("category") or {}).get("name", "")
                            or ""),
        })
    return out


def list_computer_groups(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all computer groups (smart + static) from Jamf Pro.

    Uses `pro computer-groups list --output json`. Each item is normalised to
    `{id, name, is_smart}`. Returns [] on failure so the Orphans sheet can
    degrade gracefully if the call fails.
    """
    cmd = ["jamf-cli", "pro", "computer-groups", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        items = (data.get("results")
                 or data.get("computer_groups")
                 or [])
    else:
        items = []

    out: list[dict[str, Any]] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        gid = it.get("id")
        try:
            gid_int = int(gid) if gid is not None else None
        except (TypeError, ValueError):
            gid_int = None
        if gid_int is None:
            continue
        # The classic API can report this as `is_smart` (bool) or `isSmart`.
        raw_smart = it.get("is_smart")
        if raw_smart is None:
            raw_smart = it.get("isSmart")
        out.append({
            "id":       gid_int,
            "name":     str(it.get("name") or ""),
            "is_smart": bool(raw_smart),
        })
    return out


def get_script_body(script_name: str, profile_name: str | None) -> str:
    """Fetch the script contents for a named script via pro scripts get."""
    cmd = ["jamf-cli", "pro", "scripts", "get", "--name", script_name, "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        # Modern API returns scriptContents or script_contents
        body = data.get("scriptContents") or data.get("script_contents") or ""
        if body:
            return str(body)
        # May be nested under a "script" key
        inner = data.get("script") or {}
        if isinstance(inner, dict):
            body = inner.get("script_contents") or inner.get("scriptContents") or ""
            return str(body)
    return ""


def _trim_description(text: str, max_chars: int = 400) -> str:
    """Trim a description to max_chars, preferring a natural sentence boundary."""
    import textwrap as _tw
    text = " ".join(text.split())
    if len(text) <= max_chars:
        return text
    sentences = re.split(r'(?<=[.!?])\s+', text)
    result = ""
    for s in sentences:
        candidate = (result + " " + s).strip()
        if len(candidate) <= max_chars:
            result = candidate
        else:
            break
    return result if result else _tw.shorten(text, width=max_chars, placeholder="...")


# ─────────────────────────────────────────────────────────────────────────────
# Script-summary overrides.
#
# Some scripts in Jamf Pro have noisy or unhelpful bodies that produce a poor
# auto-generated summary. List exact script names here mapped to the
# description you want shown in the Scripts sheet instead. The match is
# case-insensitive on the full script name.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_SUMMARY_OVERRIDES: dict[str, str] = {
    "gen-script-policy-auto-update.py":
        "Updates, installs and uninstalls Jamf Auto Update titles.",
    "gen-script-policy-auto-update.sh":
        "Updates, installs and uninstalls Jamf Auto Update titles.",
}


# ─────────────────────────────────────────────────────────────────────────────
# Extension-attribute description overrides.
#
# Exact name matches (case-insensitive) take priority over the auto-generated
# summary. EAs whose names start with "License - " are handled separately
# below and do not need an entry here.
# ─────────────────────────────────────────────────────────────────────────────
EA_DESCRIPTION_OVERRIDES: dict[str, str] = {
    "restrictions":         "Assigns and Unassigns Restrictions profile",
    "administrator rights": "Assigns and Unassigns the ability to make a user an admin rights",
    "notes":                "Displays the contents of the Notes field",
    "machine role":         "Display and change the role (rebuild to update the role permanently)",
}


# ─────────────────────────────────────────────────────────────────────────────
# Sensitive policy / profile names to omit from every output sheet.
#
# Anything that touches local admin passwords or shared credentials goes here.
# Match is case-insensitive on the full name (exact match — no substring).
# ─────────────────────────────────────────────────────────────────────────────
SENSITIVE_POLICY_NAMES: set[str] = {
    "policy - reset local administrator password",
    "policy - reset password - _datajardotmobi",
}


def _is_sensitive_name(name: str) -> bool:
    """True if the given policy/profile name should be excluded from output."""
    return (name or "").strip().lower() in SENSITIVE_POLICY_NAMES


# ─────────────────────────────────────────────────────────────────────────────
# Profile-type definitions — fed to Ollama so AI-written summaries explain
# what these payload types actually do rather than guessing from key names.
# ─────────────────────────────────────────────────────────────────────────────
PROFILE_TYPE_DEFINITIONS: str = (
    "Managed Login Items: A configuration profile payload that automatically "
    "enables and allows specified applications or background services to launch "
    "at login without user approval. Uses rules (bundle ID, team identifier) to "
    "match items and prevents users from disabling them.\n"
    "Screen Recording Profile: A configuration profile that controls which "
    "applications are permitted to capture the screen. Delivered as part of the "
    "Privacy Preferences Policy Control (PPPC) framework. Screen Recording is "
    "the one PPPC permission Apple does NOT allow MDM to silently pre-approve — "
    "users must manually grant it when prompted.\n"
    "PPPC Profile (Privacy Preferences Policy Control): A configuration profile "
    "payload that pre-approves or denies an application's access to protected "
    "macOS resources (camera, microphone, contacts, calendar, full disk access) "
    "via Apple's Transparency, Consent, and Control (TCC) framework — without "
    "user interaction. Screen Recording is the documented exception."
)


# ─────────────────────────────────────────────────────────────────────────────
# Ollama — local AI description generator
#
# Used to generate EA descriptions when no description exists and no override
# matches. Falls back silently to _summarise_script() if Ollama is not running.
# ─────────────────────────────────────────────────────────────────────────────
OLLAMA_MODEL        = "qwen2.5:7b"          # primary generation model
OLLAMA_MODEL_FALLBACK = "llama3.2:latest"   # fallback if qwen2.5 not available
OLLAMA_EMBED_MODEL  = "nomic-embed-text:latest"  # embedding model for fuzzy matching
OLLAMA_URL          = "http://127.0.0.1:11434/api/generate"
OLLAMA_EMBED_URL    = "http://127.0.0.1:11434/api/embeddings"
OLLAMA_TIMEOUT      = 30   # seconds per generation request
OLLAMA_EMBED_TIMEOUT = 10  # seconds per embedding request


# ─────────────────────────────────────────────────────────────────────────────
# Ollama cache — sqlite-backed, content-addressable
#
# Stores Ollama-generated summaries keyed by sha256(version, kind, model, args).
# Because the summary is a pure function of (prompt template, model, inputs),
# the cached value is always valid as long as none of those change. If the
# prompt template itself changes (e.g. you tweak wording in _ollama_describe_*
# below), bump _OLLAMA_CACHE_VERSION to invalidate every entry at once.
#
# Cache file: ~/.cache/report-jamfpro-configuration/ollama.sqlite (XDG-compliant),
# created the first time Ollama is used.
# Safe to delete by hand at any time — the next run rebuilds entries lazily.
#
# Empty / falsy results are NOT cached so failures (Ollama down, timeout)
# don't poison the cache and prevent retries.
# ─────────────────────────────────────────────────────────────────────────────
_OLLAMA_CACHE_VERSION = 1  # ← bump when ANY _ollama_describe_* prompt changes
_OLLAMA_CACHE_PATH = pathlib.Path.home() / ".cache" / "report-jamfpro-configuration" / "ollama.sqlite"


class _OllamaCache:
    """SQLite-backed lookup keyed by hash of (kind, model, payload).

    Wraps a single connection; safe for the single-threaded script-run use
    case. If the cache file can't be opened the instance silently disables
    itself — Ollama calls then run as if the cache didn't exist.
    """

    def __init__(self, path: pathlib.Path):
        self.path = path
        self.hits = 0
        self.misses = 0
        self.disabled = False
        self.conn = None

    def _connect(self) -> bool:
        """Open the cache on first use, so runs without Ollama never create
        the cache folder. Returns False if the cache is unavailable."""
        if self.conn:
            return True
        if self.disabled:
            return False
        path = self.path
        try:
            import sqlite3
            path.parent.mkdir(parents=True, exist_ok=True)
            self.conn = sqlite3.connect(str(path))
            self.conn.execute(
                "CREATE TABLE IF NOT EXISTS cache ("
                "  key TEXT PRIMARY KEY,"
                "  kind TEXT NOT NULL,"
                "  model TEXT NOT NULL,"
                "  summary TEXT NOT NULL,"
                "  created_at INTEGER NOT NULL"
                ")"
            )
            self.conn.commit()
        except Exception as e:
            print(f"WARNING: Ollama cache unavailable ({e}); "
                  f"continuing without caching.", file=sys.stderr)
            self.disabled = True
            return False
        return True

    def _key(self, kind: str, model: str, payload: str) -> str:
        import hashlib
        h = hashlib.sha256()
        h.update(
            f"v{_OLLAMA_CACHE_VERSION}\x00{kind}\x00{model}\x00{payload}"
            .encode("utf-8")
        )
        return h.hexdigest()

    def get(self, kind: str, model: str, payload: str) -> str | None:
        """Returns the cached summary or None on miss. Bumps hit counter."""
        if not self._connect():
            return None
        try:
            cur = self.conn.execute(
                "SELECT summary FROM cache WHERE key = ?",
                (self._key(kind, model, payload),),
            )
            row = cur.fetchone()
        except Exception:
            return None
        if row:
            self.hits += 1
            return row[0]
        return None

    def set(self, kind: str, model: str, payload: str, summary: str) -> None:
        """Store a summary. Refuses to cache empty/falsy values."""
        if not summary or not self._connect():
            return
        try:
            import time as _t
            self.conn.execute(
                "INSERT OR REPLACE INTO cache "
                "(key, kind, model, summary, created_at) VALUES (?, ?, ?, ?, ?)",
                (self._key(kind, model, payload), kind, model, summary,
                 int(_t.time())),
            )
            self.conn.commit()
        except Exception:
            pass

    def note_miss(self) -> None:
        """Increment miss counter — called when a wrapped function actually
        invokes Ollama (vs returning a cached value)."""
        self.misses += 1


_ollama_cache = _OllamaCache(_OLLAMA_CACHE_PATH)


def _setup_ollama() -> bool:
    """Ensure Ollama is installed, running, and has the required model.

    Steps:
      1. Check ollama binary — offer brew install if missing.
      2. Check server is reachable — start it if not.
      3. Check model is pulled — pull it if missing.

    Returns True if fully ready, False on any unrecoverable failure so
    the caller can fall back to _summarise_script() gracefully.
    """
    import shutil, time, urllib.request

    GREEN  = "\033[0;32m"
    YELLOW = "\033[1;33m"
    RED    = "\033[0;31m"
    NC     = "\033[0m"

    def _ok(msg):   print(f"  {GREEN}✓{NC} {msg}", file=sys.stderr, flush=True)
    def _warn(msg): print(f"  {YELLOW}!{NC} {msg}", file=sys.stderr, flush=True)
    def _err(msg):  print(f"  {RED}✗{NC} {msg}", file=sys.stderr, flush=True)

    def _server_up() -> bool:
        try:
            urllib.request.urlopen("http://127.0.0.1:11434", timeout=2)
            return True
        except Exception:
            return False

    # ── 1. Binary check ───────────────────────────────────────────────────────
    if not shutil.which("ollama"):
        brew = shutil.which("brew")
        if not brew:
            _warn("Ollama not found and Homebrew unavailable — skipping AI descriptions.")
            return False

        if sys.stdin.isatty():
            try:
                ans = input(
                    "  Ollama not installed. Install via Homebrew for AI-generated "
                    "EA descriptions? [ y / n ]: "
                ).strip().lower()
            except (EOFError, KeyboardInterrupt):
                print(file=sys.stderr)
                return False
            if ans not in ("", "y", "yes"):
                _warn("Ollama skipped — using script analysis for blank EA descriptions.")
                return False
        else:
            _warn("Ollama not found — skipping AI descriptions.")
            return False

        print("  Installing Ollama...", file=sys.stderr, flush=True)
        r = subprocess.run([brew, "install", "ollama"],
                           capture_output=True, text=True)
        if r.returncode != 0 or not shutil.which("ollama"):
            _err("Ollama install failed — falling back to script analysis.")
            return False
        _ok("Ollama installed.")

    # ── 2. Server check ───────────────────────────────────────────────────────
    if not _server_up():
        print("  Starting Ollama server...", file=sys.stderr, flush=True)
        try:
            subprocess.Popen(
                ["ollama", "serve"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as exc:
            _err(f"Could not start Ollama: {exc} — falling back to script analysis.")
            return False

        # Wait up to 15 seconds for the server to become reachable
        for _ in range(15):
            time.sleep(1)
            if _server_up():
                break
        else:
            _err("Ollama server did not start in time — falling back to script analysis.")
            return False
        _ok("Ollama server started.")

    # ── 3. Model check ────────────────────────────────────────────────────────
    try:
        result = subprocess.run(
            ["ollama", "list"], capture_output=True, text=True, timeout=10
        )
        listed = result.stdout
    except Exception:
        listed = ""

    # Prefer qwen2.5 — fall back to llama3.2 if it's already local
    global OLLAMA_MODEL
    if OLLAMA_MODEL not in listed:
        if OLLAMA_MODEL_FALLBACK in listed:
            _warn(f"'{OLLAMA_MODEL}' not found — using '{OLLAMA_MODEL_FALLBACK}' instead.")
            OLLAMA_MODEL = OLLAMA_MODEL_FALLBACK
        else:
            if sys.stdin.isatty():
                try:
                    ans = input(
                        f"  Model '{OLLAMA_MODEL}' not found locally. "
                        f"Pull it now (~4.7 GB)? [ y / n ]: "
                    ).strip().lower()
                except (EOFError, KeyboardInterrupt):
                    print(file=sys.stderr)
                    return False
                if ans not in ("", "y", "yes"):
                    _warn("Model pull skipped — falling back to script analysis.")
                    return False
            else:
                _warn(f"Model '{OLLAMA_MODEL}' not available — falling back to script analysis.")
                return False

            print(f"  Pulling {OLLAMA_MODEL} (this may take a few minutes)...",
                  file=sys.stderr, flush=True)
            r = subprocess.run(["ollama", "pull", OLLAMA_MODEL])
            if r.returncode != 0:
                _err("Model pull failed — falling back to script analysis.")
                return False

    _ok(f"Generation model: {OLLAMA_MODEL}")

    # ── 4. Embedding model check (nomic-embed-text) ───────────────────────────
    # Used for fuzzy catalog matching — optional, non-blocking.
    global OLLAMA_EMBED_MODEL
    if OLLAMA_EMBED_MODEL not in listed:
        if sys.stdin.isatty():
            try:
                ans = input(
                    f"  Embedding model '{OLLAMA_EMBED_MODEL}' not found. "
                    f"Pull it for better app version matching (~274 MB)? [ y / n ]: "
                ).strip().lower()
            except (EOFError, KeyboardInterrupt):
                print(file=sys.stderr)
                ans = "n"
            if ans in ("", "y", "yes"):
                print(f"  Pulling {OLLAMA_EMBED_MODEL}...", file=sys.stderr, flush=True)
                r = subprocess.run(["ollama", "pull", OLLAMA_EMBED_MODEL])
                if r.returncode == 0:
                    _ok(f"Embedding model: {OLLAMA_EMBED_MODEL}")
                else:
                    _warn("Embedding model pull failed — using string matching for catalog.")
                    OLLAMA_EMBED_MODEL = ""
            else:
                _warn("Embedding model skipped — using string matching for catalog.")
                OLLAMA_EMBED_MODEL = ""
        else:
            OLLAMA_EMBED_MODEL = ""
    else:
        _ok(f"Embedding model: {OLLAMA_EMBED_MODEL}")

    return True


def _ollama_query(prompt: str) -> str:
    """Send a prompt to Ollama and return the response text, or "" on failure."""
    import urllib.request, json as _json

    payload = _json.dumps({
        "model":  OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
    }).encode()
    try:
        req = urllib.request.Request(
            OLLAMA_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=OLLAMA_TIMEOUT) as resp:
            result = _json.loads(resp.read().decode())
            text = str(result.get("response") or "").strip()
            text = text.strip('"').strip("'").strip()
            # Strip common preamble patterns the model sometimes adds anyway
            for _pat in (
                r"^This (?:Bash |shell |Python |zsh )?script(?: named '[^']*')?\s+",
                r"^This (?:Jamf Pro )?(?:extension attribute|EA|config(?:uration)? profile)"
                r"(?: named '[^']*')?\s+",
                r"^The script\s+",
            ):
                text = re.sub(_pat, "", text, flags=re.IGNORECASE)
            # Capitalise first letter after stripping
            text = text[:1].upper() + text[1:] if text else text
            # On-device models love em-dashes — strip them at the source so
            # no AI-derived text carries a long dash into any output format.
            text = _dedash(text)
            return text if len(text) > 5 else ""
    except Exception:
        return ""


def _ollama_embed(text: str) -> "list[float]":
    """Return a nomic-embed-text embedding vector, or [] on failure."""
    import urllib.request as _ur, json as _json
    if not OLLAMA_EMBED_MODEL:
        return []
    payload = _json.dumps({
        "model":  OLLAMA_EMBED_MODEL,
        "prompt": text,
    }).encode()
    try:
        req = _ur.Request(
            OLLAMA_EMBED_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with _ur.urlopen(req, timeout=OLLAMA_EMBED_TIMEOUT) as resp:
            return _json.loads(resp.read().decode()).get("embedding", [])
    except Exception:
        return []


def _cosine(a: "list[float]", b: "list[float]") -> float:
    """Cosine similarity between two vectors."""
    if not a or not b:
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    mag_a = sum(x * x for x in a) ** 0.5
    mag_b = sum(x * x for x in b) ** 0.5
    return dot / (mag_a * mag_b) if mag_a and mag_b else 0.0


# Catalog embedding index — built once after catalog CSV is loaded.
# Maps catalog display/jamf name → (version, embedding vector)
_catalog_embed_index: "dict[str, tuple[str, list[float]]]" = {}


def _build_catalog_embed_index(au_versions: "dict[str, str]") -> None:
    """Pre-compute embeddings for every catalog entry name.

    Runs once after _load_auto_update_versions(). Populates _catalog_embed_index
    so per-policy lookups are fast (one embed per query, many dot products).
    Silently skips if embed model is unavailable.
    """
    global _catalog_embed_index
    if not OLLAMA_EMBED_MODEL or not au_versions:
        return
    _catalog_embed_index = {}
    entries = list(au_versions.items())  # [(name, version), ...]
    print(f"  Building catalog embedding index ({len(entries)} entries)…",
          file=sys.stderr, flush=True)
    for name, version in entries:
        vec = _ollama_embed(name)
        if vec:
            _catalog_embed_index[name] = (version, vec)
    print(f"  ✓ Indexed {len(_catalog_embed_index)} catalog entries.",
          file=sys.stderr, flush=True)


def _catalog_version_fuzzy(lookup_name: str, threshold: float = 0.88) -> str:
    """Return catalog version for lookup_name using embedding similarity.

    Falls back to "" if index is empty or no match exceeds the threshold.
    """
    if not _catalog_embed_index:
        return ""
    query_vec = _ollama_embed(lookup_name)
    if not query_vec:
        return ""
    best_score = 0.0
    best_version = ""
    for name, (version, vec) in _catalog_embed_index.items():
        score = _cosine(query_vec, vec)
        if score > best_score:
            best_score = score
            best_version = version
    return best_version if best_score >= threshold else ""


def _ollama_describe_ea(ea_name: str, script_body: str) -> str:
    """Verb-first description of what an EA script does.

    Cached: result is a pure function of (ea_name, script_body, model).
    """
    payload = f"{ea_name}\x00{script_body}"
    cached = _ollama_cache.get("ea", OLLAMA_MODEL, payload)
    if cached is not None:
        return cached
    _ollama_cache.note_miss()
    result = _ollama_query(
        f"Write a one-sentence (max 20 words) description of what this Jamf Pro "
        f"extension attribute script does. "
        f"Start directly with an action verb (e.g. Checks, Returns, Sets, Detects, "
        f"Reads, Verifies). "
        f"Do NOT start with 'This script', 'This EA', 'This extension attribute', "
        f"the script name, or any preamble. No quotes.\n\n"
        f"Script:\n{script_body[:3000]}"
    )
    _ollama_cache.set("ea", OLLAMA_MODEL, payload, result)
    return result


def _ollama_describe_script(script_name: str, script_body: str) -> str:
    """Verb-first description of what a Jamf Pro policy script does.

    Cached: result is a pure function of (script_name, script_body, model).
    """
    payload = f"{script_name}\x00{script_body}"
    cached = _ollama_cache.get("script", OLLAMA_MODEL, payload)
    if cached is not None:
        return cached
    _ollama_cache.note_miss()
    result = _ollama_query(
        f"Write a one-sentence (max 20 words) description of what this Jamf Pro "
        f"script does. "
        f"Start directly with an action verb (e.g. Installs, Removes, Sets, Enables, "
        f"Configures, Creates, Deletes, Updates, Grants). "
        f"Do NOT start with 'This script', 'This Bash script', 'This shell script', "
        f"the script name, or any preamble. No quotes.\n\n"
        f"Script:\n{script_body[:3000]}"
    )
    _ollama_cache.set("script", OLLAMA_MODEL, payload, result)
    return result


def _ollama_summarise_profile(profile_name: str, settings_text: str) -> str:
    """Verb-first plain-English summary of a config profile's settings.

    Profile-type definitions are passed in as reference so the model writes
    meaningful summaries for Managed Login Items, Screen Recording, and PPPC
    profiles (which look similar in raw payload form but behave differently).

    Cached: cache key includes PROFILE_TYPE_DEFINITIONS, so updating the
    reference table automatically invalidates the right cache entries.
    """
    payload = f"{profile_name}\x00{settings_text}\x00{PROFILE_TYPE_DEFINITIONS}"
    cached = _ollama_cache.get("profile", OLLAMA_MODEL, payload)
    if cached is not None:
        return cached
    _ollama_cache.note_miss()
    result = _ollama_query(
        f"You are summarising a Jamf Pro configuration profile.\n\n"
        f"Reference — what these profile types do:\n"
        f"{PROFILE_TYPE_DEFINITIONS}\n\n"
        f"Use the reference above when the profile matches one of those types. "
        f"For Screen Recording profiles, always note that users must still "
        f"manually grant the permission (MDM cannot silently pre-approve it).\n\n"
        f"Write a one-sentence (max 25 words) summary of what this profile "
        f"enforces or configures. "
        f"Start directly with an action verb (e.g. Enforces, Restricts, Enables, "
        f"Disables, Configures, Deploys, Blocks, Pre-approves, Auto-launches). "
        f"Do NOT start with 'This profile', 'This configuration', the profile name, "
        f"or any preamble. No quotes.\n\n"
        f"Profile name: {profile_name}\n"
        f"Settings:\n{settings_text[:3000]}"
    )
    _ollama_cache.set("profile", OLLAMA_MODEL, payload, result)
    return result


def _ollama_health_actions(comp_name: str, model: str,
                           os_version: str, issues: str,
                           existing_actions: str) -> str:
    """Enhance existing health-check remediation actions for a specific Mac.

    Takes the pre-written suggested actions and improves them for clarity and
    practicality from a Jamf Pro MDM administrator's perspective. Only rewrites
    wording where it adds value — does not invent new steps or remove existing ones.

    Cached: keyed on the full input tuple. Note that `comp_name` shifts the
    cache key per-Mac, so re-runs benefit only when a Mac's issues list is
    stable. Still worth caching because health-check re-runs in CI / sched
    jobs often see identical inputs.
    """
    payload = f"{comp_name}\x00{model}\x00{os_version}\x00{issues}\x00{existing_actions}"
    cached = _ollama_cache.get("health", OLLAMA_MODEL, payload)
    if cached is not None:
        return cached
    _ollama_cache.note_miss()
    result = _ollama_query(
        f"You are an experienced Jamf Pro MDM administrator. "
        f"A Mac named '{comp_name}' (model: {model}, macOS: {os_version}) "
        f"has these issues: {issues}.\n\n"
        f"Existing suggested actions: {existing_actions}\n\n"
        f"Enhance these actions for clarity and practicality where needed. "
        f"Use Jamf Pro workflows or macOS terminal commands "
        f"(e.g. jamf recon, sudo profiles remove -all, "
        f"sudo /usr/bin/profiles renew -type enrollment, mdmclient). "
        f"Do NOT suggest UI steps, System Preferences, Finder, or 'Enrol in Profile'. "
        f"If the existing actions are already clear and practical, return them unchanged. "
        f"Keep the same number of action items. Reply with only the actions — no preamble, no bullet points."
    )
    _ollama_cache.set("health", OLLAMA_MODEL, payload, result)
    return result


# ─────────────────────────────────────────────────────────────────────────────
# Health Check Definitions
#
# Reference table for the macOS - Health Check sheet. Each tuple is
# (Check, What it flags, Why it matters). The customer reads this sheet to
# understand any flagged row in the Health Check report.
#
# Order matches the order of checks in the health-check loop below.
# Keep these two lists in sync.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# Reference URL cache for the Health Check Key sheet.
#
# Hardcoded as a static map so the script doesn't have to look these up at
# runtime. Keyed by the Check name (case-sensitive — keep in sync with the
# tuples below). All URLs are public-facing Apple / Jamf documentation.
# Edit this dict to refine or update a reference; the change is picked up on
# the next run with no other code edits.
# ─────────────────────────────────────────────────────────────────────────────
HEALTH_CHECK_REFERENCES: dict[str, str] = {
    "No role assigned":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Computer_Extension_Attributes.html",
    "MDM Expired":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Automatic_Renewal_of_the_MDM_Profile.html",
    "No check-in for N days":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Computer_Check-In.html",
    "Unsupervised":
        "https://support.apple.com/guide/deployment/intro-to-device-supervision-depc9488806f/web",
    "Unsupported macOS":
        "https://support.apple.com/en-gb/100100",
    "Minimum support macOS":
        "https://support.apple.com/en-gb/100100",
    "Disk space (5 tiers)":
        "https://support.apple.com/en-gb/guide/mac-help/mchld5fcf7d8/mac",
    "Bootstrap token not escrowed":
        "https://support.apple.com/guide/deployment/use-secure-and-bootstrap-tokens-dep24dbdcf9e/web",
    "Jamf Connect Login incompatible":
        "https://learn.jamf.com/en-US/bundle/jamf-connect-documentation/page/Release_History.html",
    "FileVault recovery key not escrowed":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/FileVault_Encryption.html",
    "SIP disabled":
        "https://support.apple.com/en-gb/guide/security/secb7ea06b49/web",
    "Pending OS updates":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Managed_Software_Updates.html",
    "User-Approved MDM missing":
        "https://support.apple.com/guide/deployment/intro-to-mdm-profiles-depc0aadd3fe/web",
    "Not MDM-capable":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Computer_Enrollment.html",
    "Missing managementId":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Computer_Enrollment.html",
    "Battery health (laptops only)":
        "https://support.apple.com/en-gb/HT201585",
    "Intel Mac":
        "https://support.apple.com/en-gb/HT211814",
    "Platform SSO not registered":
        "https://learn.jamf.com/en-US/bundle/jamf-connect-documentation/page/Platform_SSO.html",
}


HEALTH_CHECK_DEFINITIONS: list[tuple[str, str, str]] = [
    (
        "No role assigned",
        "Computer's 'Machine Role' extension attribute is empty.",
        "Without a role, smart-group automation can't classify the device; "
        "deployment workflows that target by role silently skip it.",
    ),
    (
        "MDM Expired",
        "MDM profile expiration date has already passed.",
        "Device has fallen out of management. Configuration profiles stop "
        "applying, new policies can't reach it, and Apple won't deliver "
        "MDM commands to it.",
    ),
    (
        "No check-in for N days",
        "Device hasn't communicated with Jamf Pro in more than 180 days.",
        "Device may be offline, retired, or its MDM channel is broken. "
        "Inventory in Jamf Pro is stale; no commands or policies can be "
        "delivered until it checks in again.",
    ),
    (
        "Unsupervised",
        "Device is not supervised.",
        "Without supervision, many advanced restrictions are unavailable "
        "(blocking app removal, blocking Activation Lock, single-app mode, "
        "stricter profile enforcement, etc.).",
    ),
    (
        "Unsupported macOS",
        "Running macOS 13 (Ventura) or older.",
        "Apple no longer issues security updates for these versions. "
        "Newer management profiles may be incompatible. The device is "
        "increasingly at risk of unpatched vulnerabilities.",
    ),
    (
        "Minimum support macOS",
        "Running macOS 14 (Sonoma).",
        "Apple ends Sonoma support in October 2026. Plan upgrades to "
        "macOS 15 or 26 in advance to avoid an unsupported fleet.",
    ),
    (
        "Disk space (5 tiers)",
        "Data partition free space falls below 50 GB. Severity tiers: "
        "borderline (<50), low (<20), danger zone (<15), critical (<5).",
        "Updates need 20-30 GB headroom. Below 15 GB, macOS warns the "
        "user and performance degrades. Below 5 GB, the system risks "
        "crashes, failed swap and data loss.",
    ),
    (
        "Bootstrap token not escrowed",
        "Bootstrap token has not been delivered to MDM.",
        "Without an escrowed token, software updates and configuration "
        "changes that require user-approval can't be authorised by MDM. "
        "Several Apple Silicon management commands stop working.",
    ),
    (
        "Jamf Connect Login incompatible",
        "Jamf Connect Login v2.x is installed on macOS 26 (Tahoe) or newer.",
        "JCL v2 is not supported on Tahoe. Login flow breaks at next "
        "reboot - users may be locked out until v3+ is deployed.",
    ),
    (
        "FileVault recovery key not escrowed",
        "Disk is encrypted but Jamf Pro doesn't hold the Personal "
        "Recovery Key.",
        "If the user forgets their password or the device is lost, the "
        "data cannot be recovered. Compliance frameworks (SOC 2, ISO "
        "27001, HIPAA) typically require escrowed keys.",
    ),
    (
        "SIP disabled",
        "System Integrity Protection is off.",
        "SIP protects critical macOS paths from being modified by root "
        "processes. With it disabled, malware or rogue scripts can "
        "tamper with the OS itself.",
    ),
    (
        "Pending OS updates",
        "Device has one or more software updates queued but not applied.",
        "Patched CVEs remain exploitable until the update lands. Admin "
        "compliance reports based on OS version will overstate the "
        "fleet's patch posture.",
    ),
    (
        "User-Approved MDM missing",
        "User has not approved the MDM profile in System Settings.",
        "Many MDM commands silently fail on devices without "
        "user-approved MDM, including kernel and system extension "
        "approvals, supervised-only restrictions, and some profile "
        "payloads.",
    ),
    (
        "Not MDM-capable",
        "Device is not capable of accepting MDM commands.",
        "Effectively unmanaged from a configuration standpoint. Often "
        "indicates a broken enrolment, MDM profile removal, or a "
        "device that pre-dates supervision.",
    ),
    (
        "Missing managementId",
        "Internal Jamf Pro management identifier is empty.",
        "Usually a symptom of broken enrolment. Some Jamf Pro workflows "
        "and Apple MDM commands rely on this identifier and will fail "
        "silently when it's missing.",
    ),
    (
        "Battery health (laptops only)",
        "MacBook battery shows any of: Service Recommended condition, "
        "capacity below 80%, or 1,000+ cycles.",
        "Indicates a battery approaching end-of-life. User productivity "
        "is impacted as runtime drops. AppleCare warranty coverage may "
        "still apply - escalate before the window closes.",
    ),
    (
        "Intel Mac",
        "Device is an Intel-based Mac (not Apple Silicon).",
        "Apple has fully transitioned to Apple Silicon. Future macOS "
        "releases will drop Intel support, and many newer features "
        "are Apple-Silicon-only. Surface for refresh planning.",
    ),
    (
        "Platform SSO not registered",
        "A Platform SSO profile is scoped to all Macs but this device's "
        "PSSO-status extension attribute reports it is not registered.",
        "Until the user completes Platform SSO registration, the local "
        "account password and the IdP password stay out of sync and the "
        "single-sign-on and password-sync benefits of PSSO never apply.",
    ),
]


# iOS equivalents of the macOS Health Check reference data. The check names
# below are the canonical labels shown on the "iOS - Health Check Key" sheet;
# the runtime iOS Health Check issue strings (which carry dynamic suffixes
# like day counts and free-space figures) are mapped back to these via
# _match_health_key() so hover tooltips resolve.
IOS_HEALTH_CHECK_REFERENCES: dict[str, str] = {
    "Stale check-in":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Mobile_Device_Inventory_Information.html",
    "Unmanaged":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Mobile_Device_Enrollment_Methods.html",
    "Unsupervised institutional device":
        "https://support.apple.com/guide/deployment/intro-to-device-supervision-depc9488806f/web",
    "Minimum support iOS":
        "https://support.apple.com/en-gb/100100",
    "Unsupported iOS":
        "https://support.apple.com/en-gb/100100",
    "No space for iOS update":
        "https://support.apple.com/en-gb/guide/iphone/iph3f0ba85f/ios",
    "Low storage":
        "https://support.apple.com/en-gb/guide/iphone/iph3f0ba85f/ios",
    "MDM profile expiring or expired":
        "https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Automatic_Renewal_of_the_MDM_Profile.html",
    "Personal / BYOD ownership":
        "https://support.apple.com/guide/deployment/user-enrollment-and-mdm-dep23db2037d/web",
}


IOS_HEALTH_CHECK_DEFINITIONS: list[tuple[str, str, str]] = [
    (
        "Stale check-in",
        "Device hasn't sent inventory to Jamf Pro in more than 30 days, or "
        "has no recorded inventory date at all.",
        "Inventory is stale, so compliance, app, and OS reporting for this "
        "device can't be trusted. The device may be offline, retired, or "
        "effectively unmanaged.",
    ),
    (
        "Unmanaged",
        "The device's managed flag is false, so the MDM channel is inactive.",
        "Jamf Pro can't deliver commands, profiles, or apps. The device "
        "still shows in inventory but is not actually under management.",
    ),
    (
        "Unsupervised institutional device",
        "A company- or institutionally-owned device is not supervised.",
        "Supervision unlocks the strongest MDM controls (Lost Mode, app "
        "removal, single-app mode, stricter restrictions). Without it, those "
        "commands are unavailable on a device the organisation owns.",
    ),
    (
        "Minimum support iOS",
        "Running iOS/iPadOS 17.x, the oldest major version still supported.",
        "Apple's security fixes for this version are winding down. Plan an "
        "upgrade to iOS 18 or 26 before iOS 27 ships to avoid an "
        "unsupported device.",
    ),
    (
        "Unsupported iOS",
        "Running iOS/iPadOS 16.x or earlier.",
        "Apple no longer ships security updates for these versions. The "
        "device is increasingly exposed to unpatched vulnerabilities and "
        "misses newer management features.",
    ),
    (
        "No space for iOS update",
        "Free storage is below the ~6 GB an iOS major update typically needs.",
        "OS updates fail to download or install until space is freed, "
        "leaving the device stuck on an older, potentially unsupported "
        "version.",
    ),
    (
        "Low storage",
        "Less than 10% of total capacity is free.",
        "The device is nearly full. Performance degrades, backups and "
        "updates can fail, and the user is likely already seeing storage "
        "warnings.",
    ),
    (
        "MDM profile expiring or expired",
        "The device's MDM enrolment certificate has already expired, or is "
        "due to expire within 90 days.",
        "Once the MDM profile expires the device falls out of management "
        "entirely: profiles stop applying and no commands reach it until it "
        "is re-enrolled.",
    ),
    (
        "Personal / BYOD ownership",
        "The device is personally owned (BYOD).",
        "User-owned devices deliberately limit MDM: Lost Mode, app removal, "
        "and many restrictions don't apply. Flagged for context, not "
        "necessarily a fault.",
    ),
]


# Ordered (substring, canonical-key) rules mapping a runtime Health Check
# issue string back to a definition. Substrings are matched case-insensitively;
# the first match wins, so more specific rules come first.
_MACOS_ISSUE_MATCH: list[tuple[str, str]] = [
    ("no role", "No role assigned"),
    ("no check-in for", "No check-in for N days"),
    ("mdm expired", "MDM Expired"),
    ("unsupervised", "Unsupervised"),
    ("minimum support", "Minimum support macOS"),
    ("unsupported", "Unsupported macOS"),
    ("disk ", "Disk space (5 tiers)"),
    ("bootstrap token", "Bootstrap token not escrowed"),
    ("jamf connect login", "Jamf Connect Login incompatible"),
    ("filevault recovery key", "FileVault recovery key not escrowed"),
    ("sip disabled", "SIP disabled"),
    ("pending os updates", "Pending OS updates"),
    ("user-approved mdm", "User-Approved MDM missing"),
    ("not mdm-capable", "Not MDM-capable"),
    ("missing managementid", "Missing managementId"),
    ("battery health", "Battery health (laptops only)"),
    ("intel mac", "Intel Mac"),
    ("platform sso", "Platform SSO not registered"),
]

_IOS_ISSUE_MATCH: list[tuple[str, str]] = [
    ("stale check-in", "Stale check-in"),
    ("no inventory date", "Stale check-in"),
    ("unmanaged", "Unmanaged"),
    ("unsupervised", "Unsupervised institutional device"),
    ("minimum support", "Minimum support iOS"),
    ("unsupported", "Unsupported iOS"),
    ("no space for ios update", "No space for iOS update"),
    ("low storage", "Low storage"),
    ("mdm profile", "MDM profile expiring or expired"),
    ("byod", "Personal / BYOD ownership"),
]


def _match_health_key(issue_line: str, platform: str) -> "str | None":
    """Map one runtime issue string to its definition key, or None."""
    line = str(issue_line or "").strip().rstrip(";").strip().lower()
    if not line:
        return None
    rules = _IOS_ISSUE_MATCH if platform == "ios" else _MACOS_ISSUE_MATCH
    for needle, key in rules:
        if needle in line:
            return key
    return None


def _build_health_comment(cell_text, platform: str) -> "str | None":
    """Build a hover-tooltip string for an Issues cell.

    Each distinct flagged issue contributes one block: the check name plus its
    "why it matters" explanation. Multiple issues in one cell stack, so the
    tooltip explains every flag the cell carries. Returns None when nothing
    resolves (e.g. a "-" cell).
    """
    if cell_text is None:
        return None
    raw = str(cell_text).strip()
    if raw in ("", "-"):
        return None
    defs = (IOS_HEALTH_CHECK_DEFINITIONS if platform == "ios"
            else HEALTH_CHECK_DEFINITIONS)
    index = {k: (what, why) for k, what, why in defs}
    blocks: list[str] = []
    seen: set[str] = set()
    for part in raw.split("\n"):
        key = _match_health_key(part, platform)
        if not key or key in seen:
            continue
        seen.add(key)
        _what, why = index.get(key, ("", ""))
        blocks.append(f"{key}\n{why}")
    if not blocks:
        return None
    return "\n\n".join(blocks)


def _summarise_script(body: str, notes: str = "") -> str:
    """Derive a one-line description from a script body.

    Priority:
    1. DESCRIPTION block: text between "# DESCRIPTION" and the next #### fence.
    2. notes field (if non-empty and not just boilerplate).
    3. First meaningful comment line.
    4. Meaningful function names.
    5. Fallback: language + line count.
    """
    if not body or not body.strip():
        return "Empty script"

    # Execution-history line pattern, reused below.
    # Matches Jamf Pro UI execution-log rows that admins sometimes paste into
    # script bodies as an informal changelog:
    #   "2016-09-22 at 1:35 PM | mcharles | 1 Computer"
    exec_history = re.compile(
        r"\d{4}-\d{1,2}-\d{1,2}\s+at\s+\d{1,2}:\d{2}\s*(?:AM|PM)?\s*\|"
        r"\s*\S+\s*\|\s*\d+\s+Computers?",
        re.IGNORECASE,
    )

    # ── 1. DESCRIPTION block ─────────────────────────────────────────────────
    desc_match = re.search(
        r"#\s*DESCRIPTION\s*\n(.*?)(?=\n\s*#{4,})",
        body, re.DOTALL | re.IGNORECASE,
    )
    if desc_match:
        block = desc_match.group(1)
        lines = []
        for line in block.splitlines():
            stripped = line.strip().lstrip("#").strip()
            if (
                stripped
                and not stripped.startswith("-")
                and not exec_history.search(stripped)
            ):
                lines.append(stripped)
        if lines:
            summary = " ".join(lines)
            return _trim_description(summary)

    # ── 2. notes field ───────────────────────────────────────────────────────
    if notes and notes.strip() and len(notes.strip()) > 10:
        n = notes.strip()
        return _trim_description(n)

    # ── 3. First meaningful comment ──────────────────────────────────────────
    skip = re.compile(
        r"(https?://|copyright|licence|license|author:|version:|date:|shellcheck)",
        re.IGNORECASE,
    )
    # exec_history is defined at the top of the function and reused here.
    for line in body.splitlines():
        s = line.strip()
        if not s or s.startswith("#!") or not s.startswith("#"):
            continue
        c = s.lstrip("#").strip()
        if (
            len(c) > 10
            and not skip.search(c)
            and not exec_history.search(c)
            and not c.startswith("-")
        ):
            return _trim_description(c)

    # ── 4. Meaningful function names ─────────────────────────────────────────
    funcs = re.findall(r"^(?:function\s+)?(\w+)\s*\(\s*\)\s*\{", body, re.MULTILINE)
    ignore = {"main", "usage", "help", "cleanup", "die", "err", "error",
              "log", "warn", "info", "debug", "check", "run", "setup",
              "start", "finish"}
    meaningful = [f for f in funcs if f.lower() not in ignore][:5]
    if meaningful:
        return "Functions: " + ", ".join(meaningful)
    if funcs:
        return "Functions: " + ", ".join(funcs[:5])

    # ── 5. Fallback ───────────────────────────────────────────────────────────
    lines = body.splitlines()
    shebang = lines[0].strip() if lines else ""
    lang = ("zsh" if "zsh" in shebang else "bash" if "bash" in shebang
            else "Python" if "python" in shebang else "shell")
    return f"{lang} script ({len(lines)} lines)"


def extract_policy_scripts(policy_json: dict[str, Any], raw_xml: Any) -> list[dict[str, Any]]:
    """Return scripts attached to a Classic policy.

    Each entry: {id, name, priority, parameters: [p4..p11]}.
    Reads from JSON first; falls back to raw XML if JSON omits the section.

    `raw_xml` may be an XML string or a zero-arg callable returning one (see
    _lazy_raw_xml). It is resolved only if the JSON path yields nothing.
    Handles the Classic API's habit of serialising a single-item collection as
    either a dict or a one-element list.
    """
    rows: list[dict[str, Any]] = []
    seen: set[int] = set()

    def _coerce_int(v: Any) -> int | None:
        try:
            return int(v)
        except (TypeError, ValueError):
            return None

    def _push(entry: dict[str, Any]) -> None:
        sid = _coerce_int(entry.get("id"))
        if sid is None or sid in seen:
            return
        seen.add(sid)
        params = [str(entry.get(f"parameter{i}") or "") for i in range(4, 12)]
        rows.append({
            "id":         sid,
            "name":       str(entry.get("name") or ""),
            "priority":   str(entry.get("priority") or ""),
            "parameters": params,
        })

    # ── JSON path ──────────────────────────────────────────────────────────
    block = policy_json.get("scripts") if isinstance(policy_json, dict) else None
    if isinstance(block, dict):
        inner = block.get("script")
        if isinstance(inner, list):
            for s in inner:
                if isinstance(s, dict):
                    _push(s)
        elif isinstance(inner, dict):
            _push(inner)
    elif isinstance(block, list):
        for s in block:
            if isinstance(s, dict):
                _push(s)

    if rows:
        return rows

    # ── XML fallback ───────────────────────────────────────────────────────
    # raw_xml may be a lazy callable (see _lazy_raw_xml); resolving it here,
    # after the JSON path has already failed, is what keeps the eager fetch
    # out of the hot loop.
    raw_xml = _resolve_raw_xml(raw_xml)
    if raw_xml and raw_xml.strip():
        try:
            root = ET.fromstring(raw_xml)
            for s in root.findall(".//scripts/script"):
                entry: dict[str, Any] = {}
                for child in s:
                    entry[child.tag] = (child.text or "").strip()
                _push(entry)
        except ET.ParseError:
            pass

    return rows


def list_vpp_macos_apps(profile_name: str | None) -> list[dict[str, Any]]:
    # Preferred modern endpoint path.
    cmd = ["jamf-cli", "pro", "vpp-locations", "content", "--all", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))

    entries: list[dict[str, Any]] = []

    if data is not None:
        # Use iterative traversal to avoid recursion depth issues with very large payloads.
        stack: list[Any] = [data]
        marker_keys = {
            "adamId",
            "adam_id",
            "bundleId",
            "bundle_id",
            "name",
            "platform",
            "deviceType",
        }
        while stack:
            obj = stack.pop()
            if isinstance(obj, dict):
                if marker_keys.intersection(set(obj.keys())):
                    entries.append(obj)
                stack.extend(obj.values())
            elif isinstance(obj, list):
                stack.extend(obj)

    # Fallback to classic assignments if no entries found.
    if not entries:
        cmd = ["jamf-cli", "pro", "classic-vpp-assignments", "list", "--output", "json"]
        if profile_name:
            cmd.extend(_auth_args(profile_name))
        cdata = parse_json(run_cmd_maybe(cmd))
        if isinstance(cdata, list):
            entries.extend([x for x in cdata if isinstance(x, dict)])
        elif isinstance(cdata, dict):
            vals = cdata.get("vpp_assignments", [])
            if isinstance(vals, list):
                entries.extend([x for x in vals if isinstance(x, dict)])

    # De-duplicate by stable key tuple.
    seen: set[tuple[str, str, str]] = set()
    uniq: list[dict[str, Any]] = []
    for e in entries:
        name = str(e.get("name") or e.get("appName") or e.get("title") or "")
        adam = str(e.get("adamId") or e.get("adam_id") or e.get("id") or "")
        bundle = str(e.get("bundleId") or e.get("bundle_id") or "")
        key = (name, adam, bundle)
        if key in seen:
            continue
        seen.add(key)
        uniq.append(e)

    # Keep likely macOS app records; if platform signal is absent, keep row.
    macos: list[dict[str, Any]] = []
    for e in uniq:
        platform = str(e.get("platform") or e.get("deviceType") or e.get("device_type") or "").lower()
        if not platform or "mac" in platform or "osx" in platform:
            macos.append(e)

    return macos


def list_mac_apps(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all managed macOS App Store / VPP apps via classic-mac-apps list."""
    cmd = ["jamf-cli", "pro", "classic-mac-apps", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("mac_applications", []) or []
    return []


def get_mac_app_json(app_id: int, profile_name: str | None) -> dict[str, Any]:
    cmd = ["jamf-cli", "pro", "classic-mac-apps", "get", str(app_id), "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        return data
    return {}


def get_mac_app_raw_xml(app_id: int, profile_name: str | None) -> str:
    cmd = ["jamf-cli", "pro", "classic-mac-apps", "get", str(app_id), "--output", "raw"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    return run_cmd_maybe(cmd)


# ── Restricted Software ───────────────────────────────────────────────────────

def list_restricted_software(profile_name: str | None) -> list[dict[str, Any]]:
    cmd = ["jamf-cli", "pro", "classic-restricted-software", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("restricted_software", []) or []
    return []


def get_restricted_software_json(rs_id: int, profile_name: str | None) -> dict[str, Any]:
    cmd = ["jamf-cli", "pro", "classic-restricted-software", "get",
           str(rs_id), "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        return data
    return {}


# ── iOS / Mobile Device API ──────────────────────────────────────────────────
# Endpoints used:
#   pro mobile-devices list                   — flat list w/ general + hardware
#   pro classic-mobile-apps list/get          — apps (classic API, scope as strings)
#   pro classic-mobile-config-profiles list/get — config profiles (classic API)
#   pro mobile-device-groups list             — smart + static groups together
#
# Key quirks vs macOS:
#   * Device IDs come back as `mobileDeviceId` (string), not `id` (int).
#   * Scope values are comma-separated strings, not arrays. See
#     extract_mobile_scope() for the parser.
#   * Classic mobile config profiles have NO `enabled` field — the platform
#     doesn't expose enable/disable. The orphan rule for "disabled profile"
#     therefore can't apply; we report only scope-based orphans.
#   * Device groups use camelCase `isSmartGroup`, not snake_case `is_smart`.

def list_mobile_devices(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all mobile devices known to Jamf Pro.

    Each item has GENERAL + HARDWARE populated; SECURITY / APPLICATIONS /
    PROFILES are null on this endpoint — call inventory-details with the
    relevant --section to fetch those when needed. Returns [] on failure.
    """
    cmd = ["jamf-cli", "pro", "mobile-devices", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return (data.get("mobile_devices")
                or data.get("results")
                or [])
    return []


def list_mobile_apps(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all mobile-device apps (classic API)."""
    cmd = ["jamf-cli", "pro", "classic-mobile-apps", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return (data.get("mobile_device_applications")
                or data.get("results")
                or [])
    return []


def get_mobile_app_json(app_id: int, profile_name: str | None) -> dict[str, Any]:
    cmd = ["jamf-cli", "pro", "classic-mobile-apps", "get",
           str(app_id), "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        return data
    return {}


def list_mobile_config_profiles(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all classic mobile-device configuration profiles."""
    cmd = ["jamf-cli", "pro", "classic-mobile-config-profiles", "list",
           "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return (data.get("configuration_profiles")
                or data.get("results")
                or [])
    return []


def get_mobile_config_profile_json(prof_id: int,
                                   profile_name: str | None) -> dict[str, Any]:
    cmd = ["jamf-cli", "pro", "classic-mobile-config-profiles", "get",
           str(prof_id), "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        return data
    return {}


def list_mobile_device_groups(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all mobile-device groups (smart + static together).

    Normalised so every item has `id`, `name`, `is_smart` (bool) — translating
    the upstream `isSmartGroup` field to the same shape we use for macOS
    computer-groups elsewhere in this script.
    """
    cmd = ["jamf-cli", "pro", "mobile-device-groups", "list", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        items = (data.get("mobile_device_groups")
                 or data.get("results")
                 or [])
    else:
        items = []

    out: list[dict[str, Any]] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        gid = it.get("id")
        try:
            gid_int = int(gid) if gid is not None else None
        except (TypeError, ValueError):
            gid_int = None
        if gid_int is None:
            continue
        out.append({
            "id":       gid_int,
            "name":     str(it.get("name") or ""),
            "is_smart": bool(it.get("isSmartGroup")),
        })
    return out


def extract_mobile_scope(scope_dict: dict | None) -> tuple[list[str], list[str], list[str]]:
    """Parse an iOS scope dict into (targets, limitations, exclusions) name lists.

    iOS classic scope values come back in three different shapes depending
    on tenant + endpoint:
      1. Empty string when nothing is scoped:    `"mobile_device_groups": ""`
      2. Comma-separated string when populated:  `"mobile_device_groups": "Group A,Group B"`
      3. List of wrapper dicts (modern API):     `[{"mobile_device_group": {"id": 49, "name": "..."}}, ...]`
    This helper normalises all three into a flat list of name strings.
    """
    if not isinstance(scope_dict, dict):
        return [], [], []

    # Inner-dict key names used by the modern API to wrap each scope entry.
    _WRAPPER_KEYS = (
        "mobile_device_group", "mobile_device",
        "user_group", "user", "jss_user_group", "jss_user",
        "network_segment", "ibeacon", "building", "department",
    )

    def _names_from_dict(d: dict) -> list[str]:
        """Extract one or more names from a scope-entry dict.

        Handles three shapes we've seen in the wild:
          a) {"mobile_device_group": {"id": 49, "name": "X"}}
          b) {"mobile_device_group": [{"id": 4, "name": "A"},
                                       {"id": 5, "name": "B"}, ...]}
          c) {"id": 49, "name": "X"}   (flat — no wrapper key)
        """
        for k in _WRAPPER_KEYS:
            inner = d.get(k)
            if isinstance(inner, dict):
                n = str(inner.get("name") or inner.get("id") or "").strip()
                return [n] if n else []
            if isinstance(inner, list):
                out: list[str] = []
                for item in inner:
                    if isinstance(item, dict):
                        n = str(item.get("name") or item.get("id") or "").strip()
                        if n:
                            out.append(n)
                    elif item not in (None, ""):
                        out.append(str(item).strip())
                return out
        # Flat shape: {"id": 49, "name": "X"}
        n = str(d.get("name") or d.get("id") or "").strip()
        return [n] if n else []

    def _split(val) -> list[str]:
        if not val:
            return []
        if isinstance(val, dict):
            # Top-level dict (no outer list) — also possible.
            return _names_from_dict(val)
        if isinstance(val, list):
            out: list[str] = []
            for v in val:
                if isinstance(v, dict):
                    out.extend(_names_from_dict(v))
                elif v not in (None, ""):
                    out.append(str(v).strip())
            return [x for x in out if x]
        return [s.strip() for s in str(val).split(",") if s.strip()]

    # Targets: groups and individual devices.
    targets = (_split(scope_dict.get("mobile_device_groups"))
               + _split(scope_dict.get("mobile_devices")))

    # Limitations: user_groups, users, network_segments, ibeacons.
    lim_block = scope_dict.get("limitations") or {}
    limitations = (_split(lim_block.get("user_groups"))
                   + _split(lim_block.get("users"))
                   + _split(lim_block.get("network_segments"))
                   + _split(lim_block.get("ibeacons")))

    # Exclusions: same sub-buckets as scope.
    exc_block = scope_dict.get("exclusions") or {}
    exclusions = (_split(exc_block.get("mobile_device_groups"))
                  + _split(exc_block.get("mobile_devices"))
                  + _split(exc_block.get("user_groups"))
                  + _split(exc_block.get("users"))
                  + _split(exc_block.get("network_segments"))
                  + _split(exc_block.get("ibeacons")))

    return targets, limitations, exclusions


# ── Computer Prestages ────────────────────────────────────────────────────────

def fetch_account_groups(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all Jamf Pro account groups with full member detail."""
    cmd = ["jamf-cli", "pro", "account-groups", "list", "--all", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("results", []) or []
    return []


def fetch_user_accounts(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all Jamf Pro user accounts (local + LDAP-linked).

    Used to derive Total / LDAP / Local counts for the summary sheet. We do
    NOT surface the local account names in any sheet — only counts.
    """
    cmd = ["jamf-cli", "pro", "user-accounts", "list", "--all", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("results", []) or data.get("accounts", []) or []
    return []


def fetch_sso_failover(profile_name: str | None,
                       sso_settings: dict[str, Any] | None = None) -> str:
    """Return the instance failover URL, or '' if not available.

    Tries, in order:
      1. A pre-fetched SSO settings payload (some Jamf Pro versions include
         `failoverUrl` inline on /v1/sso).
      2. `jamf-cli pro sso-settings sso` if not already provided.
      3. The pro overview, scanning for a key that looks like a failover URL.

    Note: jamf-cli does not expose `/v1/sso/failover` directly, so we read
    whatever the SSO payload carries. If the field is genuinely missing we
    return '' and the summary shows "-".
    """
    candidates: list[str] = []
    src = sso_settings if isinstance(sso_settings, dict) else fetch_sso_settings(profile_name)
    for key in ("failoverUrl", "ssoFailoverUrl", "failover_url"):
        val = src.get(key)
        if val:
            candidates.append(str(val).strip())
    return next((c for c in candidates if c), "")


def list_computer_prestages(profile_name: str | None) -> list[dict[str, Any]]:
    cmd = ["jamf-cli", "pro", "computer-prestages", "list", "--all", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("results", []) or []
    return []


def get_computer_prestage_json(ps_id: str, profile_name: str | None) -> dict[str, Any]:
    cmd = ["jamf-cli", "pro", "computer-prestages", "get",
           str(ps_id), "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        return data
    return {}


# ── Computer Inventory (health check) ────────────────────────────────────────

def list_computers_inventory(
    profile_name: str | None,
    include_disk_encryption: bool = False,
    include_user_and_location: bool = False,
    include_extension_attributes: bool = False,
) -> list[dict[str, Any]]:
    """Fetch all computers with sections needed for health check in one bulk call.

    include_disk_encryption: also pull the DISK_ENCRYPTION section so
        FileVault personal recovery keys are populated on each partition (only
        returned when the API role has 'View Disk Encryption Recovery Key').
    include_user_and_location: also pull USER_AND_LOCATION so the assigned
        user/email/department appear on each row (used by the FV PRK, LAPS
        Accounts, and Managed Macs sheets).
    include_extension_attributes: also pull EXTENSION_ATTRIBUTES so the
        Machine Role EA (and others) come through populated on every row
        rather than only on the records the health-check loop touches.
    """
    sections = [
        "GENERAL", "HARDWARE", "OPERATING_SYSTEM", "STORAGE", "SECURITY",
        "SOFTWARE_UPDATES",
    ]
    if include_disk_encryption:
        sections.append("DISK_ENCRYPTION")
    if include_user_and_location:
        sections.append("USER_AND_LOCATION")
    if include_extension_attributes:
        sections.append("EXTENSION_ATTRIBUTES")
    cmd = ["jamf-cli", "pro", "computers-inventory", "list", "--all", "--output", "json"]
    for s in sections:
        cmd.extend(["--section", s])
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("results", []) or []
    return []


def list_filevault_inventory(profile_name: str | None) -> list[dict[str, Any]]:
    """Bulk-fetch FileVault info (including Personal Recovery Key) for all Macs.

    The PRK is NOT returned by `pro computers-inventory list` even with
    --section DISK_ENCRYPTION — that section only carries the encryption
    state. The PRK lives behind the dedicated endpoint exposed as
    `pro computers-inventory filevault`, which is paginated and returns one
    entry per computer keyed by computerId.

    Returns a list of dicts. Each dict has at least: computerId, name,
    personalRecoveryKey (when the API role allows), bootPartitionEncryptionDetails,
    individualRecoveryKeyValidityStatus, institutionalRecoveryKeyPresent.
    """
    cmd = ["jamf-cli", "pro", "computers-inventory", "filevault",
           "--all", "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        results = data.get("results") or data.get("computers") or []
        if isinstance(results, list):
            return results
    return []


def list_laps_accounts_for_device(
    management_id: str, profile_name: str | None
) -> list[dict[str, Any]]:
    """Return the LAPS-capable admin accounts for one device.

    ⚠ This call does NOT view passwords — it only enumerates which usernames
    on the device are LAPS-managed and where they came from (MDM vs JMF).
    Calling this endpoint does NOT trigger a password rotation. Only the
    /password endpoint triggers a rotation, and this script never calls it.

    Returns a list of dicts: [{"username": str, "userSource": "MDM"|"JMF",
    "guid": str}].
    """
    if not management_id:
        return []
    cmd = ["jamf-cli", "pro", "local-admin-passwords", "accounts",
           "get", management_id, "--output", "json"]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        results = data.get("results") or data.get("accounts") or []
        if isinstance(results, list):
            return results
    return []


# ─────────────────────────────────────────────────────────────────────────────
# Managed Software Updates + Declarative Device Management helpers
#
# These power the "macOS - Software Updates" and "iOS - Software Updates"
# sheets. We use four jamf-cli surfaces:
#
#   1. `pro managed-software-updates-plans list` — the authoritative list of
#      active update plans (one per device per target version).
#   2. `pro report update-status --scan-failures` — curated devices with
#      update-related issues including the failure reason where Jamf knows
#      it. Cheaper than walking every device individually.
#   3. `pro ddm-statuss status-items --id <clientManagementId>` — per-device
#      Declarative Device Management status. This drives the Blueprint
#      Status column and exposes invalid declarations (DDM equivalent of
#      "deploy failed"). Per memory: this endpoint can need Platform
#      Gateway auth on some tenants; we treat failures as a soft miss.
#   4. `pro mdm-commands list --filter clientManagementId==<id>;status==FAILED`
#      — the "event store" the user mentioned. Recent FAILED MDM commands
#      give us per-device context to enrich the Issues column when the
#      update-status report only carries a generic error code.
#
# All helpers return empty containers on failure so the sheet can still
# render with reduced detail rather than aborting.
# ─────────────────────────────────────────────────────────────────────────────

def list_msu_plans(profile_name: str | None) -> list[dict[str, Any]]:
    """Return all Managed Software Update plans (`pro managed-software-updates-plans list`).

    Each plan typically carries: planUuid, device.deviceId, device.objectType
    (COMPUTER / MOBILE_DEVICE), updateAction, versionType, specificVersion,
    state, errorReasons, forceInstallLocalDateTime. Empty list on any error.
    """
    cmd = [
        "jamf-cli", "pro", "managed-software-updates-plans", "list",
        "--all", "--output", "json",
    ]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return (
            data.get("results") or data.get("plans")
            or data.get("availableUpdates") or []
        )
    return []


def report_update_status_failures(profile_name: str | None) -> list[dict[str, Any]]:
    """`pro report update-status --scan-failures` — curated failures view.

    Returns devices with software-update issues, including failure reasons
    captured by Jamf Pro. Cheaper than walking every device. Shape varies
    by jamf-cli version so we tolerate list / "results" / "rows" wrappers.
    """
    cmd = [
        "jamf-cli", "pro", "report", "update-status",
        "--scan-failures", "--output", "json",
    ]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for k in ("results", "rows", "devices", "failures", "items"):
            v = data.get(k)
            if isinstance(v, list):
                return v
    return []


def get_ddm_status_items(client_management_id: str,
                         profile_name: str | None) -> list[dict[str, Any]]:
    """Per-device DDM status — `pro ddm-statuss status-items --id <cmid>`.

    Returns the raw status-items list. The "management.declarations.*" keys
    carry per-blueprint validity info; the caller summarises them with
    `summarise_blueprint_status`. Returns [] on any error so this column
    degrades gracefully when the endpoint needs Platform Gateway auth or
    the device isn't enrolled in DDM yet.
    """
    if not client_management_id:
        return []
    cmd = [
        "jamf-cli", "pro", "ddm-statuss", "status-items",
        "--id", str(client_management_id), "--output", "json",
    ]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for k in ("statusItems", "results", "items"):
            v = data.get(k)
            if isinstance(v, list):
                return v
    return []


def list_mdm_command_failures_for_device(
    client_management_id: str,
    profile_name: str | None,
    limit: int = 5,
) -> list[dict[str, Any]]:
    """Recent FAILED MDM commands for a device — the "event store" enrich
    source. Used to add specific context to the Issues column when the
    report-update-status row only carries a generic error code.

    `--filter` syntax: `clientManagementId==<id>;status==FAILED`. Limit to
    the most recent few so the column stays readable.
    """
    if not client_management_id:
        return []
    cmd = [
        "jamf-cli", "pro", "mdm-commands", "list",
        "--filter", f"clientManagementId=={client_management_id};status==FAILED",
        "--limit", str(limit),
        "--sort", "dateSent:desc",
        "--output", "json",
    ]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for k in ("results", "commands", "items"):
            v = data.get(k)
            if isinstance(v, list):
                return v
    return []


# Regex used by summarise_blueprint_status to pull individual {…} records
# out of the comma-joined "value" string Jamf returns under
# "management.declarations.configurations".
_DDM_RECORD_RE  = re.compile(r"\{([^{}]+)\}")
_DDM_BLUEPRINT_RE = re.compile(r"blueprint_([0-9a-f-]+)_", flags=re.IGNORECASE)


def summarise_blueprint_status(
    status_items: list[dict[str, Any]],
) -> tuple[str, bool]:
    """Reduce DDM status-items → ("3 blueprints · 8 valid · 1 invalid", any_invalid).

    The second tuple element is True when at least one declaration is
    flagged invalid — used by the row builder to escalate that device into
    the "has issues" bucket.
    """
    if not status_items:
        return ("—", False)
    valid = invalid = unknown = 0
    blueprint_ids: set[str] = set()
    for item in status_items:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "")
        if "declarations.configurations" not in key.lower():
            continue
        value = str(item.get("value") or "")
        for record in _DDM_RECORD_RE.findall(value):
            fields: dict[str, str] = {}
            for kv in record.split(","):
                if "=" in kv:
                    k, _, v = kv.partition("=")
                    fields[k.strip().lower()] = v.strip()
            ident = fields.get("identifier", "")
            m = _DDM_BLUEPRINT_RE.match(ident)
            if m:
                blueprint_ids.add(m.group(1).lower())
            v = fields.get("valid", "").lower()
            if v == "valid":
                valid += 1
            elif v == "invalid":
                invalid += 1
            else:
                unknown += 1
    if not (valid or invalid or unknown):
        return ("—", False)
    bp_count = len(blueprint_ids)
    parts: list[str] = []
    if bp_count:
        parts.append(f"{bp_count} blueprint{'s' if bp_count != 1 else ''}")
    parts.append(f"{valid} valid")
    if invalid:
        parts.append(f"{invalid} invalid")
    if unknown:
        parts.append(f"{unknown} unknown")
    return (" · ".join(parts), invalid > 0)


# ── Remediation lookup ───────────────────────────────────────────────────────
# Hand-curated mapping from error patterns (regexes) → operator remediation.
# Ordered specific → generic so the first match wins. The row builder falls
# back to an Ollama-generated one-liner when nothing matches.
# Reuses `_ollama_*` helpers defined later in this module.

_MSU_REMEDIATION_RULES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"mdm.*(profile )?expir|expir.*mdm", re.IGNORECASE),
     "Re-enrol the device. The MDM enrollment profile has expired — Jamf Pro can no longer send commands, so software updates and all other MDM workflows will fail until the profile is renewed."),
    (re.compile(r"declaration.*invalid|invalid.*declaration|configuration.*invalid", re.IGNORECASE),
     "Re-deploy the blueprint. One or more declarations are flagged invalid by the device — usually a payload format issue or an unsupported declaration on this OS version."),
    (re.compile(r"declin|user.*denied|user.*reject", re.IGNORECASE),
     "User declined the update in Self Service or System Settings. Re-queue with --force, or contact the user to walk through the install."),
    (re.compile(r"insufficient.*space|not.{1,15}enough.*space|disk.*space|low.*storage", re.IGNORECASE),
     "Not enough free disk space for the update. Run a cleanup policy or ask the user to clear ~25 GB of headroom (Apple's recommended minimum for a major macOS update)."),
    (re.compile(r"download.*fail|failed.*download|network", re.IGNORECASE),
     "Update download failed. Check device connectivity. If the network is captive-portalled or firewalled, ensure swscan.apple.com and gdmf.apple.com are reachable."),
    (re.compile(r"bootstrap.*token", re.IGNORECASE),
     "Bootstrap token isn't escrowed for this Mac. Re-enrol via Self Service so the bootstrap token is captured — without it, software updates can't be authorised remotely on Apple Silicon."),
    (re.compile(r"battery|charge|power", re.IGNORECASE),
     "Battery too low for the update. Ask the user to plug into mains power, then re-queue the plan."),
    (re.compile(r"unsuper|not.{1,15}supervised", re.IGNORECASE),
     "Device isn't supervised. Re-enrol via ADE / Apple Business Manager — DDM software updates require supervision."),
    (re.compile(r"timed?.?out|timeout", re.IGNORECASE),
     "Update plan timed out waiting for the device. Verify the device is online and checking in, then re-queue."),
    (re.compile(r"not.*capable|not.*supported|model.*incompat|hardware.*incompat", re.IGNORECASE),
     "Device hardware can't run the requested OS version. Update the plan to a version this model supports, or retire/replace the device."),
    (re.compile(r"apns|push.*cert|push.*notification", re.IGNORECASE),
     "APNs push delivery failed for this device. Verify the Push Certificate in Jamf Pro hasn't lapsed, and try `pro computers blank-push` to wake the device."),
    (re.compile(r"plan.{0,15}fail|failed.{0,5}plan", re.IGNORECASE),
     "Plan failed during install. Inspect the device's recent MDM command history for the specific reason; common causes include user cancellation, low storage, or APNs delivery."),
]


def lookup_msu_remediation(error_text: str) -> str | None:
    """Return remediation text for a known MSU/DDM error pattern, or None
    when nothing matches (caller can decide whether to call Ollama)."""
    if not error_text:
        return None
    for pat, fix in _MSU_REMEDIATION_RULES:
        if pat.search(error_text):
            return fix
    return None


def extract_mac_app_scope(scope_json: dict[str, Any], raw_xml: Any) -> tuple[list[str], list[str], list[str]]:
    """Extract target / limitation / exclusion computer groups from a mac_application scope.

    `raw_xml` may be an XML string or a zero-arg callable returning one (see
    _lazy_raw_xml). It is resolved only if the JSON walk yields nothing.

    Falls back to raw XML when the scope endpoint returns no group names.
    The XML path for mac_application scope is identical to os_x_configuration_profile.
    """
    targets: list[str] = []
    limitations: list[str] = []
    exclusions: list[str] = []

    def names_from_list(value: Any) -> list[str]:
        """Handle Jamf's inconsistent scope lists.

        Jamf Classic API returns computer_groups as:
          - a list of dicts when multiple groups: [{"id": 1, "name": "Foo"}, ...]
          - a dict with a singular wrapper when one group:
              {"computer_group": {"id": 7, "name": "All Managed"}}
          - an empty string "" when nothing is assigned (not [] or null)
        """
        result: list[str] = []
        if not value or isinstance(value, str):
            return result
        if isinstance(value, dict):
            # Singular wrapper: {"computer_group": {"id": N, "name": "..."}}
            inner = value.get("computer_group")
            if isinstance(inner, dict):
                name = inner.get("name")
                if name:
                    result.append(str(name))
                return result
            # Bare single dict: {"id": N, "name": "..."}
            name = value.get("name")
            if name:
                result.append(str(name))
            return result
        if isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    name = item.get("name")
                    if name:
                        result.append(str(name))
                elif isinstance(item, str) and item.strip():
                    result.append(item.strip())
        return result

    def walk(obj: Any, section: str = "target") -> None:
        if isinstance(obj, dict):
            for key, val in obj.items():
                key_l = key.lower()
                next_section = section
                if key_l == "limitations":
                    next_section = "limitation"
                elif key_l == "exclusions":
                    next_section = "exclusion"
                if key_l == "computer_groups":
                    names = names_from_list(val)
                    if next_section == "exclusion":
                        exclusions.extend(names)
                    elif next_section == "limitation":
                        limitations.extend(names)
                    else:
                        targets.extend(names)
                walk(val, next_section)
        elif isinstance(obj, list):
            for item in obj:
                walk(item, section)

    # scope_json is the scope block itself (app_json["scope"]), so walk it directly.
    # The top-level keys are all_computers, computer_groups, computers, exclusions, etc.
    if scope_json:
        walk(scope_json)

    # raw_xml may be a lazy callable (see _lazy_raw_xml). It is resolved only
    # inside this branch, i.e. once the JSON walk has come up empty, so a
    # policy or app whose JSON carried its scope never pays for the fetch.
    if not targets and not limitations and not exclusions:
        raw_xml = _resolve_raw_xml(raw_xml)
    else:
        raw_xml = ""
    if raw_xml.strip():
        try:
            root = ET.fromstring(raw_xml)
            for cg in root.findall(".//scope/computer_groups/computer_group/name"):
                if cg.text:
                    targets.append(cg.text)
            for cg in root.findall(".//scope/limitations/computer_groups/computer_group/name"):
                if cg.text:
                    limitations.append(cg.text)
            for cg in root.findall(".//scope/exclusions/computer_groups/computer_group/name"):
                if cg.text:
                    exclusions.append(cg.text)
        except ET.ParseError:
            pass

    tgt = sorted({x.strip() for x in targets if x and x.strip()})
    lim = sorted({x.strip() for x in limitations if x and x.strip()})
    exc = sorted({x.strip() for x in exclusions if x and x.strip()})
    return tgt, lim, exc


def get_profile_json(profile_id: int, profile_name: str | None) -> dict[str, Any]:
    cmd = [
        "jamf-cli",
        "pro",
        "classic-macos-config-profiles",
        "get",
        str(profile_id),
        "--output",
        "json",
    ]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        return data
    return {}


def get_profile_raw_xml(profile_id: int, profile_name: str | None) -> str:
    cmd = [
        "jamf-cli",
        "pro",
        "classic-macos-config-profiles",
        "get",
        str(profile_id),
        "--output",
        "raw",
    ]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    return run_cmd_maybe(cmd)


def get_profile_scope_json(profile_id: int, profile_name: str | None) -> dict[str, Any]:
    """Return the scope subtree from a macOS config profile's full JSON.

    NOT CALLED by the config-profile loop any more, for the same reason as
    get_policy_scope_json: the workaround below fetches the whole profile
    record, making this command byte-identical to `get_profile_json` and so a
    duplicate API call per profile. The loop now reads `profile_json["scope"]`
    directly. Kept for the note below.

    Same broken-by-design issue as get_policy_scope_json: the dedicated
    `classic-macos-config-profiles scope get <id>` subcommand hits the
    by-NAME endpoint with no by-id flag, so it 404s in real tenants. We
    fetch the full profile via `classic-macos-config-profiles get <id>`
    (which accepts positional ID) and extract the `scope` subtree.
    """
    cmd = [
        "jamf-cli", "pro", "classic-macos-config-profiles", "get",
        str(profile_id), "--output", "json",
    ]
    if profile_name:
        cmd.extend(_auth_args(profile_name))
    data = parse_json(run_cmd_maybe(cmd))
    if isinstance(data, dict):
        scope = data.get("scope")
        if isinstance(scope, dict):
            return scope
    return {}


def profile_name_from_json(profile_json: dict[str, Any], fallback: str) -> str:
    general = profile_json.get("general", {}) if isinstance(profile_json, dict) else {}
    return str(general.get("name") or fallback)


def policy_name_from_json(policy_json: dict[str, Any], fallback: str) -> str:
    general = policy_json.get("general", {}) if isinstance(policy_json, dict) else {}
    return str(general.get("name") or fallback)


def category_from_json(profile_json: dict[str, Any]) -> str:
    general = profile_json.get("general", {}) if isinstance(profile_json, dict) else {}
    category = general.get("category", {}) if isinstance(general, dict) else {}
    if isinstance(category, dict):
        return str(category.get("name") or "")
    return ""


def get_payload_xml_string(raw_xml: str) -> str:
    if not raw_xml.strip():
        return ""
    try:
        root = ET.fromstring(raw_xml)
    except ET.ParseError:
        return ""

    payload_elem = None
    for elem in root.iter():
        if elem.tag.lower() == "payloads":
            payload_elem = elem
            break

    if payload_elem is None:
        return ""

    text = payload_elem.text or ""
    text = html.unescape(text.strip())
    return text


def parse_payload_plist(payload_xml: str) -> dict[str, Any] | None:
    if not payload_xml:
        return None
    try:
        return plistlib.loads(payload_xml.encode("utf-8"))
    except Exception:
        return None


def flatten_value(value: Any, key_path: str, out_rows: list[tuple[str, str]]) -> None:
    if isinstance(value, dict):
        for key in sorted(value.keys(), key=lambda x: str(x)):
            next_path = f"{key_path}.{key}" if key_path else str(key)
            flatten_value(value[key], next_path, out_rows)
        return

    if isinstance(value, list):
        for idx, item in enumerate(value):
            next_path = f"{key_path}[{idx}]"
            flatten_value(item, next_path, out_rows)
        return

    if isinstance(value, bool):
        val = "true" if value else "false"
    elif value is None:
        val = ""
    else:
        val = str(value)

    out_rows.append((key_path, val))


def short_key_from_path(key_path: str) -> str:
    if not key_path:
        return ""
    token = key_path.split(".")[-1]
    if "[" in token:
        base = token.split("[", 1)[0]
        if base:
            return base
    return token


def extract_scope_groups(scope_json: dict[str, Any], raw_xml: Any) -> tuple[list[str], list[str], list[str]]:
    """Extract target / limitation / exclusion computer groups from a scope block.

    `raw_xml` may be an XML string or a zero-arg callable returning one (see
    _lazy_raw_xml). It is resolved only if the JSON walk yields nothing, which
    is what lets the policy loop avoid fetching XML it will never read.
    """
    targets: list[str] = []
    limitations: list[str] = []
    exclusions: list[str] = []

    def names_from_group_list(value: Any) -> list[str]:
        result: list[str] = []
        if isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    name = item.get("name")
                    if name:
                        result.append(str(name))
                elif isinstance(item, str):
                    result.append(item)
        return result

    def walk_scope(obj: Any, section: str = "target") -> None:
        if isinstance(obj, dict):
            for key, val in obj.items():
                key_l = str(key).lower()
                next_section = section
                if key_l == "limitations":
                    next_section = "limitation"
                elif key_l == "exclusions":
                    next_section = "exclusion"
                if key_l == "computer_groups":
                    names = names_from_group_list(val)
                    if next_section == "exclusion":
                        exclusions.extend(names)
                    elif next_section == "limitation":
                        limitations.extend(names)
                    else:
                        targets.extend(names)
                walk_scope(val, next_section)
        elif isinstance(obj, list):
            for item in obj:
                walk_scope(item, section)

    if scope_json:
        walk_scope(scope_json)

    # Fallback to raw XML if scope endpoint did not provide names.
    # raw_xml may be a lazy callable (see _lazy_raw_xml). It is resolved only
    # inside this branch, so items whose JSON already carried their scope
    # never trigger the extra fetch.
    if not targets and not limitations and not exclusions:
        raw_xml = _resolve_raw_xml(raw_xml)
    else:
        raw_xml = ""
    if raw_xml.strip():
        try:
            root = ET.fromstring(raw_xml)
            for cg in root.findall(".//scope/computer_groups/computer_group/name"):
                if cg.text:
                    targets.append(cg.text)
            for cg in root.findall(".//scope/limitations/computer_groups/computer_group/name"):
                if cg.text:
                    limitations.append(cg.text)
            for cg in root.findall(".//scope/exclusions/computer_groups/computer_group/name"):
                if cg.text:
                    exclusions.append(cg.text)
        except ET.ParseError:
            pass

    tgt = sorted({x.strip() for x in targets if x and x.strip()})
    lim = sorted({x.strip() for x in limitations if x and x.strip()})
    exc = sorted({x.strip() for x in exclusions if x and x.strip()})
    return tgt, lim, exc


# ─────────────────────────────────────────────────────────────────────────────
# Jamf Auto Update catalog CSV
#
# The catalog is published as a direct CSV download. The script caches copies
# in ~/.jamf-export/auto-update-catalog/ and only re-downloads when the newest
# cached copy is more than _CATALOG_MAX_AGE_DAYS old. Keeps the last 2 copies.
# ─────────────────────────────────────────────────────────────────────────────
_CATALOG_URL = (
    "https://content.datajar.mobi/JamfAutoUpdate"
    "/Jamf+Auto+Update+Catalog+Browser+Export.csv"
)
_CATALOG_STORE       = pathlib.Path.home() / ".jamf-export" / "auto-update-catalog"
_CATALOG_KEEP        = 2   # number of CSV copies to retain
_CATALOG_MAX_AGE_DAYS = 3  # re-download only when newest cached copy is older


def _fetch_auto_update_catalog() -> "pathlib.Path | None":
    """Download the Jamf Auto Update catalog CSV, honouring a 6-day cache.

    If a cached copy exists and is <= _CATALOG_MAX_AGE_DAYS old, it is reused
    without any network call. Otherwise the CSV is downloaded fresh from
    _CATALOG_URL, cached to _CATALOG_STORE, and old copies pruned to
    _CATALOG_KEEP. On download failure the newest cached copy (if any) is
    used as a fallback. Returns the path to the local CSV, or None.
    """
    import urllib.request
    import urllib.error
    import time as _time

    def _get(url: str, timeout: int = 30) -> bytes:
        req = urllib.request.Request(
            url, headers={"User-Agent": "jamfmsp-settings-export/1.0"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()

    # Cached copies live in _CATALOG_STORE. We fall back to the newest one
    # any time the live fetch is unavailable (no network, download failed).
    # The catalog moves slowly so a stale local copy is far better than no
    # Version column at all.
    _CATALOG_STORE.mkdir(parents=True, exist_ok=True)
    existing = sorted(_CATALOG_STORE.glob("*.csv"), key=lambda p: p.stat().st_mtime)

    def _cached_fallback(reason: str) -> "pathlib.Path | None":
        if existing:
            newest = existing[-1]
            print(
                f"  ↩ Using cached catalog CSV ({newest.name}) — {reason}.",
                file=sys.stderr,
            )
            return newest
        print(f"  ! No cached catalog CSV available — {reason}.", file=sys.stderr)
        return None

    # ── Reuse a fresh-enough cached copy without downloading ─────────────────
    if existing:
        newest = existing[-1]
        age_days = (_time.time() - newest.stat().st_mtime) / 86400.0
        if age_days <= _CATALOG_MAX_AGE_DAYS:
            print(
                f"  ↩ Using cached catalog CSV ({newest.name}) — "
                f"{age_days:.1f} days old (≤ {_CATALOG_MAX_AGE_DAYS}d).",
                file=sys.stderr,
            )
            return newest

    # ── Cached copy missing or stale → download fresh ────────────────────────
    try:
        data = _get(_CATALOG_URL)
    except Exception as exc:
        print(f"  ! Catalog CSV download failed: {exc}", file=sys.stderr)
        return _cached_fallback(f"download failed: {exc}")

    stamp = _time.strftime("%Y%m%d-%H%M%S")
    dest = _CATALOG_STORE / f"auto-update-catalog-{stamp}.csv"
    try:
        dest.write_bytes(data)
        print(f"  ✓ Catalog CSV downloaded → {dest.name}", file=sys.stderr)
    except Exception as exc:
        print(f"  ! Could not write catalog CSV: {exc}", file=sys.stderr)
        return _cached_fallback(f"write failed: {exc}")

    # ── Prune old copies ──────────────────────────────────────────────────────
    all_csvs = sorted(
        _CATALOG_STORE.glob("*.csv"), key=lambda p: p.stat().st_mtime
    )
    for old in all_csvs[:-_CATALOG_KEEP]:
        try:
            old.unlink()
        except Exception:
            pass

    return dest


def _load_auto_update_versions(csv_path: pathlib.Path) -> "dict[str, str]":
    """Parse the catalog CSV → {normalised_name: version}.

    Both Display Name and Jamf Auto Update Name are added as keys (lowercased
    and stripped) so matching is forgiving. When an app has multiple rows
    (e.g. arm64 / x86_64), the first row's version wins.
    """
    import csv as _csv

    versions: dict[str, str] = {}
    try:
        with csv_path.open(newline="", encoding="utf-8-sig") as fh:
            rows = list(_csv.reader(fh))

        # Find the header row (contains "Display Name")
        header_idx = next(
            (i for i, row in enumerate(rows)
             if any("display name" in str(c).lower() for c in row)),
            None,
        )
        if header_idx is None:
            return versions

        header = [c.strip().lower() for c in rows[header_idx]]
        try:
            col_display = header.index("display name")
            col_jamf    = header.index("jamf auto update name")
            col_version = header.index("version")
        except ValueError:
            return versions

        for row in rows[header_idx + 1:]:
            if len(row) <= max(col_display, col_jamf, col_version):
                continue
            display = row[col_display].strip()
            jamf    = row[col_jamf].strip()
            version = row[col_version].strip()
            if not version:
                continue
            for name in (display, jamf):
                key = name.strip().lower()
                if key and key not in versions:
                    versions[key] = version
    except Exception:
        pass

    return versions


# ── Output format constants ──────────────────────────────────────────────────
FMT_XLSX     = "xlsx"
FMT_CSV      = "csv"
FMT_TERMINAL = "terminal"

DATASETS = {
    "1":  ("Jamf MSP Summary",            "msp-summary"),
    "2":  ("Health Check Definitions",    "health-check-definitions"),
    "3":  ("Health Check",                "health-check"),
    "4":  ("Prestages",                   "prestages"),
    "5":  ("Config Profiles",             "config-profiles"),
    "6":  ("Config Profiles - Scope",     "config-profiles-scope"),
    "7":  ("Apps - Scope",                "apps-scope"),
    "8":  ("Scripts",                     "scripts"),
    "9":  ("Extension Attributes",        "extension-attributes"),
    "10": ("Restricted Software",         "restricted-software"),
    "11": ("FileVault Recovery Keys",     "filevault-keys"),
    "12": ("Software Updates",            "software-updates"),
    "13": ("Orphaned Items",              "orphaned-items"),
    "14": ("iOS - Health Check",          "ios-health-check"),
    "15": ("iOS - Devices",               "ios-devices"),
    "16": ("iOS - Apps - Scope",          "ios-apps-scope"),
    "17": ("iOS - Config Profiles - Scope","ios-config-profiles-scope"),
    "18": ("iOS - Config Profiles",       "ios-config-profiles"),
    "19": ("iOS - Software Updates",      "ios-software-updates"),
    "20": ("iOS - Orphaned Items",        "ios-orphaned-items"),
    "21": ("Jamf Pro Accounts",           "jamf-pro-accounts"),
    "22": ("All",                         "all"),
}


# ── UI styling helpers ───────────────────────────────────────────────────────
# Mirrors the visual language of Launcher.command — blue horizontal rules,
# coloured section headers, and " N │ Item" menu lines. Colours collapse to
# empty strings when stdout is not a TTY so logs and pipes stay clean.
if sys.stdout.isatty():
    _UI_BOLD   = "\033[1m"
    _UI_DIM    = "\033[2m"
    _UI_GREEN  = "\033[0;32m"
    _UI_YELLOW = "\033[0;33m"
    _UI_RED    = "\033[0;31m"
    _UI_BLUE   = "\033[0;34m"
    _UI_NC     = "\033[0m"
else:
    _UI_BOLD = _UI_DIM = _UI_GREEN = _UI_YELLOW = _UI_RED = _UI_BLUE = _UI_NC = ""

# Width of horizontal rules — matches Launcher.command's _W.
_UI_W = 36

def _ui_hbar(width: int = _UI_W) -> None:
    pass

def _ui_section(title: str, width: int = _UI_W) -> None:
    print(f"\n{title}")

def _ui_menu_line(num: object, label: str, suffix: str = "") -> None:
    print(f"   [{num}] {label}{suffix}")


def _prompt_dataset() -> str:
    """Interactively ask which dataset to display in the terminal."""
    _ui_section("Terminal Dataset")
    print()
    for key, (label, _) in DATASETS.items():
        _ui_menu_line(int(key), label)
    print()
    _ui_hbar()
    choice = input(f"   Choose by number [1]: ").strip()
    return DATASETS.get(choice, ("macOS - Config Profiles - Scope", "config-profiles-scope"))[1]


def _prompt_profile() -> str | None:
    """Interactively ask which jamf-cli profile to use.

    Accepts either a numeric index (e.g. "3") or a typed profile name
    (e.g. "mcd"). Name matching is case-insensitive and tolerant of
    surrounding whitespace.

    Returns the chosen profile name, or None if the user accepted the
    default (in which case jamf-cli's own default profile is used and we
    don't pass --profile to it). Returns None on any error so the caller
    falls back to default behaviour.
    """
    try:
        r = subprocess.run(
            ["jamf-cli", "config", "show", "--output", "json"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0:
            return None
        d = json.loads(r.stdout)
    except Exception:
        return None

    names = [p["name"] for p in d.get("profiles", []) if p.get("name")]
    if not names:
        return None

    default_name = d.get("default-profile") or ""
    # Sort with the default first so option 1 is the "do what I usually do" choice.
    names.sort(key=lambda n: (n != default_name, n.lower()))

    _ui_section("Choose a jamf-cli profile")
    print()
    for i, n in enumerate(names, 1):
        suffix = f"  {_UI_DIM}(default){_UI_NC}" if n == default_name else ""
        _ui_menu_line(i, n, suffix)
    print()
    _ui_hbar()

    # Default choice: the first entry, which is the jamf-cli default if one exists.
    choice = input(f"   Choose by number or name [1]: ").strip()

    # Empty → default.
    if not choice:
        chosen = names[0]
    else:
        # First try number.
        idx = None
        try:
            idx = int(choice) - 1
        except ValueError:
            pass
        if idx is not None and 0 <= idx < len(names):
            chosen = names[idx]
        else:
            # Try exact name match (case-insensitive).
            _by_lower = {n.lower(): n for n in names}
            chosen = _by_lower.get(choice.lower())
            if chosen is None:
                # Then try unique prefix match — so "mcd" matches "mcd-prod"
                # when there's no ambiguity.
                _prefix = [n for n in names if n.lower().startswith(choice.lower())]
                if len(_prefix) == 1:
                    chosen = _prefix[0]
                else:
                    print(f"  {_UI_YELLOW}No match for '{choice}'.{_UI_NC} Using '{names[0]}'.")
                    chosen = names[0]

    # If the chosen profile is jamf-cli's default, return None so we don't
    # bother passing --profile downstream — fewer moving parts.
    return None if chosen == default_name else chosen


def _resolve_instances(preselected: str | None) -> list[str | None]:
    """Resolve which jamf-cli instance(s) to run against.

    Delegates to the shared picker in lib/jamf_menu.py, which asks
    "Select multiple instances? [ y / n ]" (default no) and, when yes, accepts a
    comma-separated mix of profile names and menu numbers. Returns a list of
    profile names; a single [None] means "use jamf-cli's default profile".

    Falls back to the legacy single-profile picker (no multi support) if the
    shared lib can't be imported, so the script keeps working standalone.
    """
    if preselected is not None:
        return [preselected]
    if not sys.stdin.isatty():
        return [None]

    try:
        import os as _os
        _lib = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "lib")
        if _lib not in sys.path:
            sys.path.insert(0, _lib)
        import jamf_menu  # type: ignore
        return list(jamf_menu.select_instances(preselected=preselected))
    except Exception:
        # Shared lib unavailable — degrade gracefully to the single picker.
        return [_prompt_profile()]


# ─────────────────────────────────────────────────────────────────────────────
# Sheet menu — used both for the interactive picker and the --sheets flag.
# Order matches the workbook's final reading order. "Jamf Pro Accounts" only
# appears if the tenant actually has hybrid admin groups, so it's listed here
# but silently dropped if empty.
# ─────────────────────────────────────────────────────────────────────────────
SHEET_MENU: list[tuple[str, str]] = [
    # Note: "Jamf MSP Summary" is intentionally NOT in this menu. It is
    # always included as the first sheet of every workbook and cannot be
    # deselected (per user policy).
    #
    # Note: "macOS - LAPS Accounts" has been dropped. Querying LAPS
    # passwords triggers a rotation, which we explicitly never want.
    # LAPS status still appears in the Jamf MSP Summary when enabled.
    ("health-check",           "macOS - Health Check"),
    ("managed-macs",           "macOS - Managed Macs"),
    ("apps-scope",             "macOS - Apps - Scope"),
    ("config-profiles-scope",  "macOS - Config Profiles - Scope"),
    ("config-profiles",        "macOS - Config Profiles"),
    ("scripts",                "macOS - Scripts"),
    ("extension-attributes",   "macOS - Extension Attributes"),
    ("restricted-software",    "macOS - Restricted Software"),
    ("printers",               "macOS - Printers"),
    ("prestages",              "macOS - Prestages"),
    ("filevault-keys",         "macOS - FileVault Recovery Keys"),
    ("software-updates",       "macOS - Software Updates"),
    ("orphaned-items",         "macOS - Orphaned Items"),
    # iOS group — mirrors macOS ordering: Health Check at the top,
    # Apps Scope → Config Profiles Scope → Config Profiles, Orphans last.
    ("ios-health-check",       "iOS - Health Check"),
    ("ios-devices",            "iOS - Devices"),
    ("ios-apps-scope",         "iOS - Apps - Scope"),
    ("ios-config-profiles-scope", "iOS - Config Profiles - Scope"),
    ("ios-config-profiles",    "iOS - Config Profiles"),
    ("ios-software-updates",   "iOS - Software Updates"),
    ("ios-orphaned-items",     "iOS - Orphaned Items"),
    ("jamf-pro-accounts",      "Jamf Pro Accounts"),
    ("jamf-protect",           "Jamf Protect"),
    # Note: the Health Check Key sheets (macOS + iOS) are intentionally NOT
    # in this menu. They are not independently selectable — each one is
    # auto-included whenever its Health Check sheet is selected (see the
    # auto-include pass in main()).
]


def _prompt_sheet_selection() -> set[str]:
    """Interactively choose which sheets to include in the workbook.

    Returns a set of sheet display-names. Empty input / Enter = all sheets.
    Accepts comma-separated numbers, ranges (e.g. 1-5), or 'all'.
    """
    _ui_section("Workbook Sheets")
    print()
    # Group lines visually by family. Family is inferred from the display
    # name prefix — keeps the picker readable as the list grows.
    _last_family = None
    for i, (_, label) in enumerate(SHEET_MENU, 1):
        family = (
            "macOS" if label.startswith("macOS")
            else "iOS" if label.startswith("iOS")
            else "Jamf Pro"
        )
        if _last_family is not None and family != _last_family:
            print()  # blank line between families
        _last_family = family
        suffix = ""
        if label == "macOS - FileVault Recovery Keys":
            suffix = f"  {_UI_DIM}← requires View Disk Encryption Recovery Key privilege{_UI_NC}"
        _ui_menu_line(i, label, suffix)
    print()
    _ui_hbar()
    print(f"  {_UI_DIM}Enter sheet numbers (e.g. 1,3,5  or  1-7,10){_UI_NC}")
    print(f"  {_UI_DIM}Press Enter for ALL sheets (default).{_UI_NC}")
    print()
    raw = input("   Choose by number: ").strip().lower()

    all_names = {label for _, label in SHEET_MENU}
    if not raw or raw == "all":
        return all_names

    chosen: set[str] = set()
    for token in raw.replace(" ", "").split(","):
        if not token:
            continue
        if "-" in token:
            a, _, b = token.partition("-")
            try:
                lo, hi = int(a), int(b)
            except ValueError:
                continue
            for i in range(lo, hi + 1):
                if 1 <= i <= len(SHEET_MENU):
                    chosen.add(SHEET_MENU[i - 1][1])
        else:
            try:
                i = int(token)
            except ValueError:
                continue
            if 1 <= i <= len(SHEET_MENU):
                chosen.add(SHEET_MENU[i - 1][1])

    return chosen or all_names


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export Jamf macOS data to Excel, CSV, or terminal table"
    )
    parser.add_argument("--profile", help="jamf-cli profile name", default=None)
    parser.add_argument("--ids", help="Comma-separated profile IDs to export", default="")
    parser.add_argument("--name-pattern", help="Glob pattern for profile names", default="")
    parser.add_argument(
        "--output-prefix",
        help="Output directory/stem. Defaults to <output-dir>/<profile>-jamfpro-configuration",
        default="",
    )
    parser.add_argument(
        "--output-dir", dest="output_dir",
        help="Folder for output files. If omitted, choose /tmp or ~/Desktop "
             "(defaults to /tmp when not interactive)",
        default="",
    )
    parser.add_argument(
        "--format", dest="fmt",
        choices=[FMT_XLSX, FMT_CSV, FMT_TERMINAL],
        default=None,
        help="Output format: xlsx (default), csv, or terminal",
    )
    parser.add_argument(
        "--dataset",
        choices=["msp-summary", "health-check-definitions", "health-check",
                  "managed-macs",
                  "prestages", "config-profiles", "config-profiles-scope",
                  "apps-scope", "scripts", "extension-attributes",
                  "restricted-software", "filevault-keys",
                  "software-updates", "ios-software-updates",
                  "jamf-pro-accounts", "all"],
        default=None,
        help="Dataset for terminal display (terminal mode only)",
    )
    parser.add_argument(
        "--sheets",
        default=None,
        help=("Comma-separated slugs of sheets to include in xlsx output "
              "(e.g. msp-summary,health-check,filevault-keys). "
              "'all' or omitted = every sheet. "
              f"Available slugs: {', '.join(s for s, _ in SHEET_MENU)}"),
    )
    # MJT bridge: shell wrapper supplies these instead of --profile
    parser.add_argument("--url", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--token-file", dest="token_file", default=None, help=argparse.SUPPRESS)
    args = parser.parse_args()

    # ── MJT auto-exec: re-exec through shell wrapper when present ────────────
    # Lets the script be run directly from the mjt folder and still get the
    # instance picker. The wrapper calls back with --url + --token-file set,
    # bypassing this block on the second pass.
    if args.url is None and args.token_file is None:
        _wrapper = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "report-jamfpro-configuration.sh"
        )
        if os.path.exists(_wrapper):
            os.execv("/bin/bash", ["/bin/bash", _wrapper] + sys.argv[1:])

    # ── MJT override: use --url + --token-file when supplied by wrapper ──────
    if args.url and args.token_file:
        global _OVERRIDE_URL, _OVERRIDE_TOKEN_FILE
        _OVERRIDE_URL = args.url
        _OVERRIDE_TOKEN_FILE = args.token_file
        _instances = [None]  # run once; profile picker skipped
    else:
        # ── Resolve jamf-cli profile (flag → interactive picker → default) ──────
        # Only prompt if the user didn't pass --profile and we're on an interactive
        # terminal. In non-interactive runs (cron, CI), keep the existing behaviour
        # of using jamf-cli's default profile.
        # Resolve which jamf-cli instance(s) to run against. Asks "select multiple
        # instances? [ y / n ]" (default no); single → [name-or-None], multi → a list
        # of profile names. The format/sheet selections below are asked ONCE and
        # shared across every instance.
        _instances = _resolve_instances(args.profile)

    # ── Resolve output format: Excel unless --format says otherwise ──────────
    fmt = args.fmt or FMT_XLSX

    # ── For terminal mode, resolve dataset before any expensive fetches ──────
    terminal_dataset: str | None = None
    if fmt == FMT_TERMINAL:
        terminal_dataset = args.dataset
        if terminal_dataset is None:
            if sys.stdin.isatty():
                terminal_dataset = _prompt_dataset()
            else:
                terminal_dataset = "config-profiles-scope"

    # ── Resolve which sheets to include (xlsx + csv only) ────────────────────
    # CLI flag wins, otherwise prompt interactively, otherwise all sheets.
    _all_sheet_names = {label for _, label in SHEET_MENU}
    if fmt in (FMT_XLSX, FMT_CSV):
        if args.sheets:
            if args.sheets.strip().lower() == "all":
                selected_sheets = set(_all_sheet_names)
            else:
                _slug_to_name = {slug: name for slug, name in SHEET_MENU}
                selected_sheets = {
                    _slug_to_name[s.strip().lower()]
                    for s in args.sheets.split(",")
                    if s.strip().lower() in _slug_to_name
                }
                if not selected_sheets:
                    selected_sheets = set(_all_sheet_names)
        elif sys.stdin.isatty():
            selected_sheets = _prompt_sheet_selection()
        else:
            selected_sheets = set(_all_sheet_names)
    else:
        # Terminal mode picks its own dataset; sheet selection is irrelevant.
        selected_sheets = set(_all_sheet_names)

    # The Jamf MSP Summary is always included as the first sheet — it isn't
    # offered in the picker, so we force-add it here regardless of what the
    # user selected. (No-op when picked via "all".)
    if fmt in (FMT_XLSX, FMT_CSV):
        selected_sheets.add("Jamf MSP Summary")

    # Health Check Key sheets ride along with their Health Check sheet. They
    # aren't offered as standalone picks — selecting a Health Check sheet
    # automatically pulls in its definitions/key sheet so the flags and their
    # explanations always travel together. Applies to every selection source
    # (--sheets flag, interactive picker, or "all").
    if fmt in (FMT_XLSX, FMT_CSV):
        if "macOS - Health Check" in selected_sheets:
            selected_sheets.add("macOS - Health Check Key")
        if "iOS - Health Check" in selected_sheets:
            selected_sheets.add("iOS - Health Check Key")

    # ── Run the export once per selected instance ────────────────────────────
    # "One file per instance": each profile gets a full export with its own
    # dated output file. Format and sheet selections above are shared, so the
    # user is only asked once. In the common (default-filename) path the profile
    # name is embedded in each filename, so multiple instances never collide.
    # ── Output folder: asked once, shared across every instance ──────────────
    if fmt != FMT_TERMINAL and not args.output_prefix and not args.output_dir:
        args.output_dir = _choose_output_dir()

    _rc = 0
    _multi = len(_instances) > 1
    if _multi and args.output_prefix:
        # A shared --output-prefix across instances would overwrite itself.
        # Fall back to auto per-profile filenames so each tenant is preserved.
        print(f"  {_UI_YELLOW}--output-prefix ignored for multi-instance runs "
              f"(per-profile filenames used instead).{_UI_NC}")
        args.output_prefix = None
    for _idx, _prof in enumerate(_instances, 1):
        args.profile = _prof
        if _multi:
            _label = _prof if _prof else "(default)"
            print()
            _ui_section(f"Instance {_idx}/{len(_instances)}: {_label}")
        _rc = _export_one(args, fmt, selected_sheets, terminal_dataset) or _rc
    return _rc


def _choose_output_dir() -> str:
    """Offer /tmp or ~/Desktop by number; /tmp when there is no terminal."""
    if not sys.stdin.isatty():
        return "/tmp"
    print("\nSave output files to:")
    print("   [1] /tmp")
    print("   [2] ~/Desktop")
    while True:
        try:
            choice = input("   Choose by number [1]: ").strip() or "1"
        except EOFError:
            return "/tmp"
        if choice == "1":
            return "/tmp"
        if choice == "2":
            return str(pathlib.Path.home() / "Desktop")
        print("   Not a valid option.")


def _instance_label(profile: "str | None") -> str:
    """Name used in filenames and as the xlsx password for this instance.

    In MJT wrapper mode there is no jamf-cli profile, so use the first label
    of the instance hostname (https://acme.jamfcloud.com -> acme). Otherwise
    use the profile name, resolving jamf-cli's default profile when unset.
    """
    if _OVERRIDE_URL:
        from urllib.parse import urlparse
        host = urlparse(_OVERRIDE_URL).hostname or _OVERRIDE_URL
        return host.split(".")[0] or host
    if profile:
        return profile
    return _jamfcli_default_profile(subprocess.run) or "default"


def _export_one(args, fmt, selected_sheets, terminal_dataset) -> int:
    """Run the full export for a single resolved instance (args.profile).

    Split out from main() so multi-instance runs can loop it once per profile.
    Depends only on args, fmt, selected_sheets, terminal_dataset.
    """
    # ── Early fleet probe — drives empty-fleet gating ────────────────────────
    # We probe per-platform device presence right at the top so the downstream
    # fetch blocks can be skipped when a platform has zero managed devices.
    #
    # We CAN'T trust `pro overview` for this — observed on a 8000-device
    # tenant where overview returned 0 for both Managed Computers and Managed
    # Devices despite the list endpoints showing thousands. The list endpoints
    # are authoritative, so we use them directly:
    #   * `pro computers list` — lightweight basic computer list
    #   * `pro mobile-devices list` — same for iOS
    # Both calls are paginated server-side; the response time is bounded.
    # We do NOT reuse `_overview_probe` for fleet gating anymore — overview
    # is only loaded later for the Jamf MSP Summary's other fields.
    _section_start("Probing fleet (computers + mobile devices)")

    def _probe_count(noun: str, profile_name: str | None) -> int:
        """Probe whether a platform has any managed devices.

        Asks jamf-cli for just one record (`--page-size 1`) to keep the call
        cheap on large tenants — on an 8000-device fleet, this would be a
        ~5-10MB JSON dump otherwise. We treat any returned record (even one)
        as "presence" — we don't need an accurate total here, just non-zero.

        Returns the count of records actually returned (capped at 1). For
        callers that want a real total, fall back to the full list endpoint.
        """
        cmd = ["jamf-cli", "pro", noun, "list",
               "--page-size", "1", "--output", "json"]
        if profile_name:
            cmd.extend(_auth_args(profile_name))
        try:
            data = parse_json(run_cmd_maybe(cmd))
        except Exception:
            return 0
        if isinstance(data, list):
            return min(1, len(data))
        if isinstance(data, dict):
            # Common envelopes across endpoints.
            for k in ("computers", "mobile_devices", "results", "totalCount"):
                v = data.get(k)
                if isinstance(v, list):
                    return min(1, len(v))
                if isinstance(v, int):
                    return 1 if v > 0 else 0
        return 0

    # Presence probes only — these return 0 or 1, not the real fleet size.
    # Real counts go to the Jamf MSP Summary via the overview fetch below.
    _have_macos_fleet = _probe_count("computers", args.profile) > 0
    _have_ios_fleet   = _probe_count("mobile-devices", args.profile) > 0
    _section_done(
        f"Fleet probe: macOS={'yes' if _have_macos_fleet else 'no'}, "
        f"iOS={'yes' if _have_ios_fleet else 'no'}",
        1,
    )

    # raw_profile names the tenant (filename + xlsx password); safe_profile is
    # the filename-safe form. Both are needed whether or not --output-prefix
    # is given.
    import re as _re
    raw_profile = _instance_label(args.profile)
    safe_profile = _re.sub(r"[^\w.\-]", "-", raw_profile)
    safe_profile = _re.sub(r"-{2,}", "-", safe_profile).strip("-")
    if args.output_prefix:
        prefix = pathlib.Path(args.output_prefix).expanduser()
    else:
        # Convention aligned with the .command toolkit:
        #   <output-dir>/<profile>-<slug>-<YYYYMMDD>.<ext>
        # Slug is "jamfpro-configuration" — this exporter covers both macOS
        # and iOS, so a platform-neutral name fits better than "macos-".
        out_dir = pathlib.Path(args.output_dir or "/tmp").expanduser()
        prefix = out_dir / f"{safe_profile}-jamfpro-configuration"

    # Filename convention: <profile>-<slug>-<YYYYMMDD>.<ext>
    datestamp = datetime.now().strftime("%Y%m%d")
    _stem = prefix.name

    # Output: single workbook — path built further below after prefix is resolved.

    ids_filter: set[int] = set()
    if args.ids.strip():
        for token in args.ids.split(","):
            token = token.strip()
            if token:
                try:
                    ids_filter.add(int(token))
                except ValueError:
                    print(f"WARNING: Skipping non-numeric ID: {token}", file=sys.stderr)

    # Skip every macOS list fetch when the tenant has zero managed macOS
    # devices — the resulting sheets would be empty anyway and we save a
    # lot of API time. The flag below is used for the policies / mac-apps
    # / restricted-software / prestages / scripts / EAs / FV / fleet
    # fetches further down too.
    if not _have_macos_fleet:
        print("Note: zero managed macOS devices — skipping all macOS data fetches.",
              file=sys.stderr)
    try:
        profiles = list_profiles(args.profile) if _have_macos_fleet else []
    except RuntimeError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1

    selected: list[dict[str, Any]] = []
    for p in profiles:
        pid = p.get("id")
        pname = str(p.get("name") or "")
        if not isinstance(pid, int):
            try:
                pid = int(pid)
            except Exception:
                continue

        if ids_filter and pid not in ids_filter:
            continue

        if args.name_pattern and not fnmatch.fnmatchcase(pname.lower(), args.name_pattern.lower()):
            continue

        # Requested exclusion.
        if pname.strip().lower() == "auto-update":
            continue

        selected.append({"id": pid, "name": pname})

    if not selected:
        # No macOS config profiles in this tenant (or all filtered out).
        # Don't bail — other sheets (Health Check, Managed Macs, Apps,
        # Scripts, EAs, iOS sheets, Jamf MSP Summary) don't need macOS
        # profile data and the user may have picked only those. Empty
        # config-profile sheets just render with zero rows.
        print("Note: no macOS configuration profiles to process "
              "(continuing with other sheets).", file=sys.stderr)

    # ── Decide early whether to skip the (expensive) per-profile fetch ───────
    # The per-profile loop below makes 3 API calls per config profile. It
    # feeds four things: the two macOS Config Profiles sheets, the macOS
    # Orphaned Items sheet (needs per-profile scope/group data), and the
    # Platform SSO signals used by BOTH the macOS Health Check sheet and the
    # Jamf MSP Summary's Platform SSO section.
    #
    # Terminal mode: skip when the single chosen dataset needs no profile data.
    _non_profile_datasets = {
        "apps-scope", "restricted-software",
        "prestages", "jamf-pro-accounts", "health-check",
        "health-check-definitions",
        "filevault-keys", "managed-macs",
    }
    # xlsx/csv mode: skip only when NONE of the profile-dependent sheets are
    # selected. Health Check is included because its "Platform SSO not
    # registered" flag depends on the profile scan — dropping the fetch while
    # Health Check is selected would silently weaken that sheet.
    _profile_dependent_sheets = {
        "macOS - Config Profiles",
        "macOS - Config Profiles - Scope",
        "macOS - Orphaned Items",
        "macOS - Health Check",
    }
    skip_profiles = (
        (fmt == FMT_TERMINAL and terminal_dataset in _non_profile_datasets)
        or (fmt in (FMT_XLSX, FMT_CSV)
            and not (selected_sheets & _profile_dependent_sheets))
    )
    if skip_profiles and fmt in (FMT_XLSX, FMT_CSV):
        # Note the one visible side effect: with no profile scan, the Jamf MSP
        # Summary's Platform SSO row can't be populated (that data lives only
        # inside profile payloads).
        print("Note: no config-profile / orphans / health-check sheets "
              "selected — skipping per-profile fetch to save time "
              "(Platform SSO summary row will be blank).", file=sys.stderr)

    # ── Accumulate rows in memory ─────────────────────────────────────────────

    settings_rows: list[list] = []
    scope_rows: list[list] = []
    # Parallel id lists — same length as the corresponding rows. Used to
    # build Name-column hyperlinks on the Config Profiles + Config Profiles
    # - Scope sheets.
    settings_row_ids: list[int | None] = []
    scope_row_ids: list[int | None] = []

    # ── Orphan-detection capture (Orphans sheet) ─────────────────────────────
    # Initialised before the first loop that writes to any of these — the
    # config-profile loop below appends to profile_meta, and the policy /
    # mac-app / restricted-software loops further down each append to their
    # own list. Used by the Orphans sheet builder near the end of main().
    policy_meta: list[dict[str, Any]] = []
    profile_meta: list[dict[str, Any]] = []
    macapp_meta: list[dict[str, Any]] = []
    rs_meta: list[dict[str, Any]] = []
    used_groups: set[str] = set()
    used_scripts: set[int] = set()

    # Platform SSO (PSSO) profile capture — populated inside the profile
    # payload loop below for any payload with PayloadType ==
    # com.apple.extensiblesso. Feeds the Platform SSO section of the
    # Jamf MSP Summary sheet later in main().
    psso_profiles: list[dict[str, Any]] = []
    # used_packages: any package id (or name, when id missing) referenced by
    # ANY policy regardless of enabled state / name filter. Drives the
    # Packages orphan section.
    used_packages: set[int] = set()
    used_package_names: set[str] = set()

    _profile_items = [] if skip_profiles else selected
    if _profile_items:
        _section_start("Fetching config profile details")
    for _pi, p in enumerate(_profile_items, 1):
        pid = p["id"]
        fallback_name = p["name"]
        _progress(_pi, len(_profile_items), fallback_name)

        # Two API calls per profile, not three. The scope subtree is already
        # part of the full profile record, so it comes off profile_json rather
        # than from a second identical fetch (see get_profile_scope_json).
        #
        # Unlike the policy and mac-app loops, the raw XML stays EAGER here:
        # get_payload_xml_string() needs it unconditionally to pull the
        # payload plist out of <payloads>, so there is nothing to defer.
        profile_json = get_profile_json(pid, args.profile)
        raw_xml = get_profile_raw_xml(pid, args.profile)
        scope_json = profile_json.get("scope") if isinstance(profile_json, dict) else None
        if not isinstance(scope_json, dict):
            scope_json = {}

        profile_name = profile_name_from_json(profile_json, fallback_name)
        profile_category = category_from_json(profile_json)

        # ── Orphan capture (config profiles) ─────────────────────────────────
        # Recorded BEFORE the name filter AND the "no targets → skip" filter
        # below so the Orphans sheet can list profiles that exist but aren't
        # scoped to anything — including " copy" / " OLD" / test profiles
        # that get suppressed from the curated sheets.
        _orphan_p_targets, _orphan_p_lims, _orphan_p_excls = extract_scope_groups(scope_json, raw_xml)
        # All-Computers is a valid scope — items using it are not orphans.
        # scope_targets_all() handles every spelling + wrapper variant.
        _all_macs_profile = scope_targets_all(scope_json)
        profile_meta.append({
            "id": pid,
            "name": profile_name,
            "target_groups": list(_orphan_p_targets),
            "limitation_groups": list(_orphan_p_lims),
            "excluded_groups": list(_orphan_p_excls),
            "all_computers": _all_macs_profile,
        })
        used_groups.update(_orphan_p_targets)
        used_groups.update(_orphan_p_lims)
        used_groups.update(_orphan_p_excls)

        _pname_l = profile_name.strip().lower()
        if (_pname_l == "auto-update"
                or _pname_l.endswith(" copy")
                or re.search(r'\btest(ing)?\b', _pname_l)
                or re.search(r' OLD\b', profile_name.strip())
                or _is_sensitive_name(profile_name)):
            continue

        target_groups, limitation_groups, excluded_groups = extract_scope_groups(scope_json, raw_xml)

        if not target_groups:
            continue

        included_str = ";\n".join(target_groups)
        limitations_str = ";\n".join(limitation_groups)
        excluded_str = ";\n".join(excluded_groups)

        scope_rows.append([
            profile_name,
            profile_category if profile_category else "-",
            included_str,
            limitations_str if limitations_str else "-",
            excluded_str,
        ])
        scope_row_ids.append(int(pid) if isinstance(pid, int) else None)

        payload_xml = get_payload_xml_string(raw_xml)
        payload_plist = parse_payload_plist(payload_xml)

        if not isinstance(payload_plist, dict):
            settings_rows.append([
                profile_name, "", "", "payload_parse_status",
                "unable_to_parse_payload", included_str, excluded_str,
            ])
            settings_row_ids.append(int(pid) if isinstance(pid, int) else None)
            continue

        payload_content = payload_plist.get("PayloadContent", [])
        if not isinstance(payload_content, list):
            payload_content = []

        if not payload_content:
            settings_rows.append([
                profile_name, "", "", "payload_parse_status",
                "no_payload_content", included_str, excluded_str,
            ])
            settings_row_ids.append(int(pid) if isinstance(pid, int) else None)
            continue

        # Track Identifier/BundleIdentifier values already emitted within this
        # profile so the same app id (e.g. com.adobe.Photoshop) is not repeated
        # across every dock tile or app entry — once per profile is enough.
        # Also dedupe against the payload domain (PayloadType) when they match.
        _seen_identifiers: set[str] = set()

        for idx, payload in enumerate(payload_content):
            if not isinstance(payload, dict):
                settings_rows.append([
                    profile_name, "", "", f"PayloadContent_{idx}",
                    str(payload), included_str, excluded_str,
                ])
                settings_row_ids.append(int(pid) if isinstance(pid, int) else None)
                continue

            payload_type = str(payload.get("PayloadType") or "")
            payload_display_name = str(
                payload.get("PayloadDisplayName")
                or payload.get("PayloadIdentifier")
                or payload_type
                or ""
            )

            # ── Platform SSO capture ────────────────────────────────────
            # Only the extensiblesso payload type carries PSSO. We capture
            # enough to populate the Summary section without needing a
            # separate sheet. Recorded once per (profile, payload) so a
            # single profile with both PSSO and SAML extensiblesso payloads
            # still gets recognised as PSSO.
            if payload_type.lower() == "com.apple.extensiblesso":
                _auth_method = str(payload.get("AuthenticationMethod") or "").strip()
                # PlatformSSO sub-dict carries the modern fields under newer
                # macOS — older AuthenticationMethod=Password is SAML/Kerberos
                # extensiblesso, not Platform SSO. Treat any presence of the
                # PlatformSSO sub-dict OR AuthenticationMethod=UserSecureEnclaveKey
                # as PSSO.
                _pso_sub = payload.get("PlatformSSO") if isinstance(payload, dict) else None
                _is_psso = (
                    _auth_method.lower() == "usersecureenclavekey"
                    or isinstance(_pso_sub, dict)
                )
                if _is_psso:
                    _ext_id = str(payload.get("ExtensionIdentifier") or "").strip()
                    _team   = str(payload.get("TeamIdentifier") or "").strip()
                    # Map well-known ExtensionIdentifiers to friendly IdP
                    # names. Fall back to ExtensionIdentifier verbatim so
                    # unknown providers still show up rather than disappearing.
                    _idp_map = {
                        "com.microsoft.companyportalmac.ssoextension": "Microsoft Entra ID",
                        "com.microsoft.companyportalmac":              "Microsoft Entra ID",
                        "com.okta.mobile.auth-service-extension":      "Okta",
                        "com.okta.mobile":                             "Okta",
                        "com.google.cloudcompanion":                   "Google Workspace",
                        "com.jamf.connect.sso":                        "Jamf Connect (PSSO)",
                        "com.beyondidentity.endpoint":                 "Beyond Identity",
                    }
                    _idp = _idp_map.get(_ext_id.lower()) or _ext_id or "Unknown IdP"
                    psso_profiles.append({
                        "id":              pid,
                        "name":            profile_name,
                        "extension_id":    _ext_id,
                        "team_id":         _team,
                        "auth_method":     _auth_method,
                        "psso_subblock":   _pso_sub if isinstance(_pso_sub, dict) else {},
                        "idp":             _idp,
                        "target_groups":   list(target_groups),
                        "all_computers":   bool(_all_macs_profile),
                    })

            flattened: list[tuple[str, str]] = []
            flatten_value(payload, "", flattened)

            # Any key whose name starts with "Payload" is config-profile
            # plumbing (PayloadType, PayloadUUID, PayloadVersion, etc.) — never
            # an actual Mac preference. The remaining set catches a handful of
            # non-Payload structural keys that show up in specific payload types
            # (e.g. PPPC/TCC entries, Passcode hints, Dock tile plumbing).
            _structural_non_payload = {
                # PPPC / TCC / Passcode plumbing
                "RetriesUntilHint", "Comment", "GroupingType",
                "CodeRequirement", "IdentifierType", "StaticCode",
                # Dock payload plumbing — visual/behavioural defaults that
                # don't represent meaningful per-tenant settings.
                "autohide", "contents-immutable", "largesize",
                "launchanim", "launchanim-immutable",
                "magnification", "magnify-immutable", "magsize-immutable",
                "mineffect", "mineffect-immutable",
                "minimize-to-application", "minimize-to-application-immutable",
                "orientation", "position-immutable",
                "show-process-indicators", "show-process-indicators-immutable",
                "size-immutable", "mcx_typehint",
                "_CFURLString", "_CFURLStringType",
                "file-label", "tile-type", "static-only", "tilesize",
            }

            # Keys that carry an app/bundle id. Normalised to "Identifier" on
            # output and deduped against _seen_identifiers (and the domain) so
            # com.adobe.Photoshop only appears once per profile.
            _identifier_keys = {"Identifier", "BundleIdentifier"}

            for key_path, value in flattened:
                setting_key = short_key_from_path(key_path)
                if setting_key.startswith("Payload") or setting_key in _structural_non_payload:
                    continue

                if setting_key in _identifier_keys:
                    val_str = str(value).strip()
                    if not val_str:
                        continue
                    # Skip if we've already emitted this id for this profile,
                    # or if it matches the payload domain (which is already
                    # shown in the payload_type column).
                    if val_str in _seen_identifiers or val_str == payload_type:
                        continue
                    _seen_identifiers.add(val_str)
                    setting_key = "Identifier"

                settings_rows.append([
                    profile_name, payload_type, payload_display_name,
                    setting_key, value, included_str, excluded_str,
                ])
                settings_row_ids.append(int(pid) if isinstance(pid, int) else None)

    # ── Ollama setup (shared by catalog matching, Scripts, EAs, Config Profiles) ──
    _use_ollama = _setup_ollama()
    if _use_ollama:
        print("  ✦ Ollama ready — AI descriptions enabled",
              file=sys.stderr, flush=True)

    # ── Jamf Auto Update catalog ──────────────────────────────────────────────
    # The catalog feeds the Version column on macOS - Apps - Scope (matches
    # Auto-Update policy names to current app versions). No iOS sheet uses
    # it, so we skip the download + embedding-index build when the user
    # hasn't selected the macOS Apps - Scope sheet. Saves ~5-15 seconds on
    # iOS-only or non-Apps runs.
    _need_catalog = (
        ("macOS - Apps - Scope" in selected_sheets)
        if fmt in (FMT_XLSX, FMT_CSV)
        else (terminal_dataset == "apps-scope")
    )
    _au_versions: dict[str, str] = {}
    if _need_catalog:
        _section_start("Fetching Jamf Auto Update catalog")
        _catalog_csv = _fetch_auto_update_catalog()
        _au_versions = (
            _load_auto_update_versions(_catalog_csv) if _catalog_csv else {}
        )
        _section_done("Auto Update catalog entries", len(_au_versions) // 2)

        # Build embedding index for fuzzy catalog matching (requires nomic-embed-text)
        if _use_ollama and OLLAMA_EMBED_MODEL and _au_versions:
            _build_catalog_embed_index(_au_versions)

    # ── Policies ─────────────────────────────────────────────────────────────
    _section_start("Fetching policy list")
    policies = list_policies(args.profile) if _have_macos_fleet else []
    _section_done("Policies found", len(policies))
    policy_rows: list[list] = []
    # Parallel id list — same length as policy_rows. Used to build
    # Name-column hyperlinks on the Apps - Scope sheet.
    policy_row_ids: list[int | None] = []

    # Active-script tracking (independent of the name-filter applied to
    # policy_rows below). Keyed by script id → {name, policies: [policy_name]}.
    # Active = referenced by a policy with general.enabled == true.
    script_usage: dict[int, dict[str, Any]] = {}
    policy_script_links: list[list[Any]] = []
    # Printer-policy capture — populated inside the policy loop below for any
    # policy whose name contains "Printer" (case-insensitive). One entry per
    # (policy, attached pkg-or-script). Empty list → Printers sheet's
    # "Policies" section is dropped; if Configured Printers is also empty,
    # the whole sheet is omitted.
    printer_policy_rows: list[list[Any]] = []
    printer_policy_row_ids: list[int | None] = []
    # Parallel list of (policy_id, script_id) tuples — same length as
    # policy_script_links. Used to build Name-column hyperlinks on the
    # Scripts sheet (policy name → policy URL, script name → script URL).
    policy_script_link_ids: list[tuple[int | None, int | None]] = []

    # Orphan-meta lists (policy_meta, profile_meta, macapp_meta, rs_meta,
    # used_groups, used_scripts) are initialised above the config-profile
    # loop earlier in main() — see the "Orphan-detection capture" block.

    if policies:
        _section_start("Fetching policy details")
    for _pi, p in enumerate(policies, 1):
        pid = p.get("id")
        if not isinstance(pid, int):
            try:
                pid = int(pid)
            except Exception:
                continue

        fallback_name = str(p.get("name") or f"Policy {pid}")
        _progress(_pi, len(policies), fallback_name)
        # One API call per policy, not three.
        #
        # `get_policy_json` already returns the whole policy record, scope
        # subtree included, so the scope comes straight off pjson rather than
        # from a second identical fetch. And the raw XML is only ever needed
        # as a fallback when the JSON path yields nothing, so it goes behind a
        # memoised lazy callable instead of being fetched up front. See
        # _lazy_raw_xml and get_policy_scope_json for the history.
        pjson = get_policy_json(pid, args.profile)
        pxml = _lazy_raw_xml(get_policy_raw_xml, pid, args.profile)
        pscope = pjson.get("scope") if isinstance(pjson, dict) else None
        if not isinstance(pscope, dict):
            pscope = {}
        pname = policy_name_from_json(pjson, fallback_name)

        # ── Orphan capture — done BEFORE the name filter below ───────────────
        # JSDE/Maintenance/Fix/Test policies are exactly the kind that end up
        # orphaned, so they need to be visible on the Orphans sheet even
        # though they're suppressed from the curated Scripts / Apps - Scope
        # sheets. We extract scope here once and reuse it further down.
        _orphan_targets, _orphan_lims, _orphan_excls = extract_scope_groups(pscope, pxml)
        _orphan_all_macs = scope_targets_all(pscope)
        _orphan_pgen = pjson.get("general", {}) if isinstance(pjson, dict) else {}
        policy_meta.append({
            "id": pid,
            "name": pname,
            "enabled": bool(_orphan_pgen.get("enabled")),
            "target_groups": list(_orphan_targets),
            "limitation_groups": list(_orphan_lims),
            "excluded_groups": list(_orphan_excls),
            "all_computers": _orphan_all_macs,
        })
        used_groups.update(_orphan_targets)
        used_groups.update(_orphan_lims)
        used_groups.update(_orphan_excls)
        # Track scripts referenced by ANY policy (broader than script_usage
        # which only counts enabled+scoped policies passing the name filter).
        for _s in extract_policy_scripts(pjson, pxml):
            _sid = _s.get("id")
            if isinstance(_sid, int):
                used_scripts.add(_sid)

        # Track packages referenced by ANY policy. The Classic API typically
        # returns these under `package_configuration.packages` as either a
        # list of dicts or a {"package": [...]} wrapper. We parse both shapes
        # and stash both id and name so the orphan check can match either
        # (some pre-modern policies record packages by name only).
        if isinstance(pjson, dict):
            _pcfg = pjson.get("package_configuration") or {}
            _pkgs = _pcfg.get("packages") if isinstance(_pcfg, dict) else None
            if isinstance(_pkgs, dict):
                _pkg_items = _pkgs.get("package") or []
                if isinstance(_pkg_items, dict):
                    _pkg_items = [_pkg_items]
            elif isinstance(_pkgs, list):
                _pkg_items = _pkgs
            else:
                _pkg_items = []
            for _pk in _pkg_items:
                if not isinstance(_pk, dict):
                    continue
                _pkid = _pk.get("id")
                if isinstance(_pkid, int):
                    used_packages.add(_pkid)
                else:
                    try:
                        used_packages.add(int(_pkid))
                    except (TypeError, ValueError):
                        pass
                _pkname = str(_pk.get("name") or "").strip()
                if _pkname:
                    used_package_names.add(_pkname)

        # ── Printer policy capture ───────────────────────────────────────────
        # Done BEFORE the name filter / Apps-Scope filter below so printer-
        # related policies appear on the Printers sheet even if they'd
        # otherwise be filtered out (e.g. "Printer Maintenance — Fix").
        # Match any policy with "printer" anywhere in the name, case-insensitive.
        if "printer" in pname.lower():
            # Reuse _pkg_items parsed above (already handles dict/list shapes).
            _printer_pkg_names: list[str] = []
            if isinstance(pjson, dict):
                _ppcfg = pjson.get("package_configuration") or {}
                _ppkgs = _ppcfg.get("packages") if isinstance(_ppcfg, dict) else None
                if isinstance(_ppkgs, dict):
                    _ppkg_items = _ppkgs.get("package") or []
                    if isinstance(_ppkg_items, dict):
                        _ppkg_items = [_ppkg_items]
                elif isinstance(_ppkgs, list):
                    _ppkg_items = _ppkgs
                else:
                    _ppkg_items = []
                for _pk in _ppkg_items:
                    if not isinstance(_pk, dict):
                        continue
                    _nm = str(_pk.get("name") or "").strip()
                    if _nm:
                        _printer_pkg_names.append(_nm)

            _printer_scripts = extract_policy_scripts(pjson, pxml)

            # Emit one row per attachment so packages and script parameters
            # each get their own line. If a policy has neither a package
            # nor a script, still emit one row so the policy itself is
            # visible (you'd otherwise lose orphan "Printer Cleanup" policies
            # that are just configuration changes with nothing attached).
            #
            # Row shape mirrors the macOS - Scripts sheet for script rows:
            # [policy, attachment_type, package, script, p4, p5, p6, p7,
            #  p8, p9, p10] — 11 columns total. Package / empty rows pad
            # the parameter slots with "".
            _empty_params = ["", "", "", "", "", "", ""]
            _emitted = False
            for _nm in _printer_pkg_names:
                printer_policy_rows.append([
                    pname, "Package", _nm, "", *_empty_params,
                ])
                printer_policy_row_ids.append(int(pid) if isinstance(pid, int) else None)
                _emitted = True
            for _s in _printer_scripts:
                _params = list(_s.get("parameters") or [])
                # Pad/truncate to exactly 7 slots (Parameter 4..Parameter 10).
                _params = (_params + _empty_params)[:7]
                _params = [str(_p) if str(_p).strip() else "" for _p in _params]
                printer_policy_rows.append([
                    pname, "Script", "", str(_s.get("name") or ""), *_params,
                ])
                printer_policy_row_ids.append(int(pid) if isinstance(pid, int) else None)
                _emitted = True
            if not _emitted:
                printer_policy_rows.append([pname, "", "", "", *_empty_params])
                printer_policy_row_ids.append(int(pid) if isinstance(pid, int) else None)

        pname_l = pname.strip().lower()
        _exact_omit = {
            "install - assets",
            "jsde - deployment - finalise setup",
            "auto-update - template",
            "jamf auto-update - template",
            "jamf auto update - template",
        }
        # Whole-word keyword filter. "Update" was removed from this list —
        # policies containing "Update" (Auto-Update, Software Update Cleanup,
        # Java Update Reset, etc.) all survive this check. The active-policy
        # gate (enabled + scoped) added later filters out inactive ones
        # without relying on name patterns.
        _keyword_hit = bool(
            re.search(r'\b(JSDE|Remove|Maintenance|Fix|Deployment)\b',
                      pname, flags=re.IGNORECASE)
        )
        # "Policy - " prefix used to be filtered as a legacy/stale-naming
        # signal, but with the active-policy gate (enabled + scoped) added
        # later, inactive Policy-* entries are already excluded. Legitimately
        # active ones (e.g. "Policy - Update Safari") now survive.
        if (
            "#" in pname
            or re.match(r'^[!#@*$%&]', pname.lstrip())
            or pname_l.endswith(" copy")
            or "uninstall" in pname_l
            or re.search(r'\btest(ing)?\b', pname_l)
            or re.search(r' OLD\b', pname)
            or pname_l.startswith("managed updates")
            or pname_l in _exact_omit
            or _is_sensitive_name(pname)
            or _keyword_hit
        ):
            continue

        # ── Scope extraction (done once, reused below for Apps - Scope) ──
        # We pull this BEFORE the script-tracking block so we can gate script
        # tracking on "policy has an effective scope". An enabled policy with
        # no scope and no all_computers flag doesn't actually run anywhere —
        # those are the "ghost" policies the customer sometimes spots in the
        # report.
        target_groups, limitation_groups, excluded_groups = extract_scope_groups(pscope, pxml)
        _all_computers = scope_targets_all(pscope)
        _has_scope = bool(target_groups) or _all_computers

        # ── Collect script links for surviving (enabled, name-allowed, scoped)
        # policies. Placed AFTER the name filter so JSDE / Remove / Maintenance
        # / Fix / Deployment / Update / leading-punctuation policies don't
        # leak into the script reports.
        _pgen = pjson.get("general", {}) if isinstance(pjson, dict) else {}
        if bool(_pgen.get("enabled")) and _has_scope:
            # Jamf Pro auto-fills the name of an un-renamed policy with a
            # timestamp template: "2016-01-12 at 4:30 PM | mcharles | 1 Computer".
            # These tell you nothing about what the policy does — but the
            # attached script usually does. Substitute a friendlier label for
            # the policy-script reports while preserving the creation date.
            _ts_default = re.match(
                r"^\s*(\d{4}-\d{1,2}-\d{1,2})\s+at\s+\d{1,2}:\d{2}\s*(?:AM|PM)?"
                r"\s*\|\s*\S+\s*\|\s*\d+\s+Computers?\s*$",
                pname, flags=re.IGNORECASE,
            )

            for s in extract_policy_scripts(pjson, pxml):
                sid = s["id"]
                # If this policy has a default timestamp name, swap it for a
                # readable label that uses the attached script as the intent
                # hint. Stored back to script_usage too so the Used By column
                # downstream is also friendlier.
                if _ts_default and s["name"]:
                    display_pname = (
                        f"Untitled policy ({_ts_default.group(1)})"
                        f" - runs {s['name']}"
                    )
                else:
                    display_pname = pname

                rec = script_usage.setdefault(sid, {
                    "id":       sid,
                    "name":     s["name"],
                    "policies": [],
                })
                # Prefer a non-empty name if a later policy supplied one.
                if not rec["name"] and s["name"]:
                    rec["name"] = s["name"]
                rec["policies"].append(display_pname)

                # Stored as: [policy_name, script_name, p4, p5, ..., p11].
                # Description and Policy Count are added after the loop, in
                # the final sheet-build step.
                policy_script_links.append([
                    display_pname, s["name"],
                    *s["parameters"],
                ])
                _sid_int = sid if isinstance(sid, int) else None
                _pid_int = pid if isinstance(pid, int) else None
                policy_script_link_ids.append((_pid_int, _sid_int))

        # dataJAR renamed the "Auto-Update" category to "Jamf Auto Update";
        # policies created/renamed since then use a "Jamf Auto Update - "
        # (or "Jamf Auto-Update - ") prefix instead of the old bare
        # "Auto-Update - ". Match either, with a hyphen or en-dash
        # separator, so both eras of policy naming are recognised.
        _au_prefix_m = re.match(
            r'^(?:Jamf\s+)?Auto[\s-]?Update\s*[-–]\s*', pname, flags=re.IGNORECASE,
        )
        if _au_prefix_m:
            policy_type = "Jamf Auto Update"
            pname = pname[_au_prefix_m.end():]
        elif pname.startswith("Install - "):
            policy_type = "Manually Packaged"
            pname = pname[len("Install - "):]
        else:
            policy_type = ""

        # Deployment style: " - Self Service" suffix = Self Service,
        # "Ongoing" trigger or no Self Service marker = Install Automatically.
        pgeneral = pjson.get("general", {}) if isinstance(pjson, dict) else {}
        trigger = str(pgeneral.get("trigger") or "").strip().lower()
        if "self service" in pname.lower():
            deployment_style = "Self Service"
        elif trigger == "ongoing" or policy_type in ("Jamf Auto Update", "Manually Packaged"):
            deployment_style = "Install Automatically"
        else:
            deployment_style = ""

        # target_groups / limitation_groups / excluded_groups were computed
        # above (before script tracking) — reuse them here.
        #
        # The Apps - Scope sheet shows APPLICATION TITLES only — not generic
        # policies (printer fixes, AD bind, OS updates, etc.). Filter to:
        #   * Auto-Update - X policies   → policy_type == "Jamf Auto Update"
        #   * Install - X policies       → policy_type == "Manually Packaged"
        # All other policies are dropped from this sheet. Their scripts still
        # appear in the macOS - Scripts sheet (tracked upstream of this
        # filter).
        if policy_type not in ("Jamf Auto Update", "Manually Packaged"):
            continue

        # Apps - Scope is a CURRENT deployment picture. Drop policies that
        # are disabled or parked in the Retired category — they're not
        # actually shipping software to anyone right now. They remain
        # visible in the Orphans sheet via policy_meta (captured upstream).
        if not bool(pgeneral.get("enabled")):
            continue
        _policy_category = category_from_json(pjson)
        if _policy_category.strip().lower() == "retired":
            continue

        # Require an effective scope. All Computers counts the same as a
        # named group here so that an "Install - Slack" policy scoped to
        # All Computers still appears in Apps - Scope.
        if not target_groups and not _all_computers:
            continue

        _targets_str = (
            ";\n".join(target_groups) if target_groups
            else ("All Computers" if _all_computers else "")
        )

        # Version lookup: Auto-Update → catalog CSV; Manually Packaged → regex
        _version = ""
        if policy_type == "Jamf Auto Update":
            # Strip "Auto-Update - " prefix, then trailing policy suffixes
            # like " - Ongoing", " - Self Service", " - Silent", etc.
            _lookup_name = re.sub(
                r'^(?:Jamf\s+)?Auto[\s-]?Update\s*[-–]\s*', '', pname, flags=re.IGNORECASE,
            ).strip()
            _lookup_name = re.sub(
                r'\s*[-–]\s*(ongoing|self\s*service|silent|automatic|manual|auto)\s*$',
                '', _lookup_name, flags=re.IGNORECASE,
            ).strip()
            # 1. Exact string match
            _version = (
                _au_versions.get(_lookup_name.lower())
                or _au_versions.get(pname.strip().lower())
                or ""
            )
            # 2. Embedding similarity fallback (nomic-embed-text)
            if not _version:
                _version = _catalog_version_fuzzy(_lookup_name)
        elif policy_type == "Manually Packaged":
            _vm = re.search(r'\b(\d+[\d.]+\d)\b', pname)
            if _vm:
                _version = _vm.group(1)

        policy_rows.append([
            pname, policy_type, _version, deployment_style,
            _targets_str,
            ";\n".join(limitation_groups) if limitation_groups else "-",
            ";\n".join(excluded_groups),
        ])
        policy_row_ids.append(int(pid) if isinstance(pid, int) else None)

    # ── Classic Printers (Jamf Pro-configured printers) ─────────────────────
    # Fetched once after the policy loop so the Printers sheet can combine
    # printer-named policies with printer objects in one place. Best-effort
    # — failures are silent (the noun isn't shipped in all jamf-cli builds).
    classic_printer_rows: list[list[Any]] = []
    classic_printer_row_ids: list[int | None] = []
    if _have_macos_fleet:
        _section_start("Fetching Jamf Pro printers")
        try:
            _printer_list = list_classic_printers(args.profile)
        except Exception as _perr:
            print(f"WARNING: classic-printers list failed: {_perr}", file=sys.stderr)
            _printer_list = []
        _section_done("Printers found", len(_printer_list))

        if _printer_list:
            _section_start("Fetching printer details")
        for _i_pr, _pr in enumerate(_printer_list, 1):
            _prid = _pr.get("id")
            if not isinstance(_prid, int):
                continue
            _progress(_i_pr, len(_printer_list), str(_pr.get("name") or ""))
            _detail = get_classic_printer_json(_prid, args.profile)
            if not isinstance(_detail, dict):
                _detail = {}
            classic_printer_rows.append([
                str(_detail.get("name") or _pr.get("name") or ""),
                str(_detail.get("model")    or ""),
                str(_detail.get("location") or ""),
                str(_detail.get("uri")      or ""),
                str(_detail.get("CUPS_name") or _detail.get("cups_name") or ""),
                "Yes" if _truthy(_detail.get("make_default")) else "",
            ])
            classic_printer_row_ids.append(_prid)

    # ── Managed Apps ─────────────────────────────────────────────────────────
    mac_app_rows: list[dict[str, Any]] = []

    _section_start("Fetching managed app list")
    if not _have_macos_fleet:
        mac_app_list = []
    else:
        try:
            mac_app_list = list_mac_apps(args.profile)
        except Exception as err:
            print(f"WARNING: classic-mac-apps list failed: {err}", file=sys.stderr)
            mac_app_list = []
    _section_done("Managed apps found", len(mac_app_list))

    if mac_app_list:
        _section_start("Fetching managed app details")
    for _ai, entry in enumerate(mac_app_list, 1):
        app_id = entry.get("id")
        if not isinstance(app_id, int):
            try:
                app_id = int(app_id)
            except Exception:
                continue
        _progress(_ai, len(mac_app_list), str(entry.get("name") or ""))

        # One API call per app, not two. The raw XML is only consumed by
        # extract_mac_app_scope()'s fallback branch, which fires only when the
        # JSON scope walk finds nothing, so it goes behind a memoised lazy
        # callable (see _lazy_raw_xml).
        app_json = get_mac_app_json(app_id, args.profile)
        raw_xml = _lazy_raw_xml(get_mac_app_raw_xml, app_id, args.profile)
        scope_json = app_json.get("scope", {}) if isinstance(app_json, dict) else {}
        general = app_json.get("general", {}) if isinstance(app_json, dict) else {}

        app_name = str(general.get("name") or entry.get("name") or "")
        bundle_id = str(general.get("bundle_id") or general.get("bundleId") or "")

        deployment_type = str(general.get("deployment_type") or "").strip().lower()
        if deployment_type in ("make available in self service", "make_available_in_self_service"):
            deployment_style = "Self Service"
        elif deployment_type in ("install automatically", "install_automatically"):
            deployment_style = "Install Automatically"
        else:
            deployment_style = "Install Automatically"

        tgt, lim, exc = extract_mac_app_scope(scope_json, raw_xml)
        scope_block = scope_json if isinstance(scope_json, dict) else {}
        all_computers = scope_targets_all(scope_block)
        target_str = "All Computers" if (not tgt and all_computers) else ";\n".join(tgt)

        # ── Orphan capture (Mac Apps) ────────────────────────────────────────
        # Recorded BEFORE the "no scope → skip" filter below so the Orphans
        # sheet can list Mac Apps that exist but aren't scoped anywhere.
        macapp_meta.append({
            "id": app_id,
            "name": app_name,
            "bundle_id": bundle_id,
            "target_groups": list(tgt),
            "limitation_groups": list(lim),
            "excluded_groups": list(exc),
            "all_computers": all_computers,  # already a clean bool from scope_targets_all
        })
        used_groups.update(tgt)
        used_groups.update(lim)
        used_groups.update(exc)

        # Volume Purchased apps with no Target scope aren't being deployed to
        # anyone — omit them from the report rather than show empty rows.
        if not target_str.strip():
            continue

        _vpp_version = str(general.get("version") or "").strip()
        mac_app_rows.append({
            "id": app_id,
            "app_name": app_name,
            "bundle_id": bundle_id,
            "version": _vpp_version,
            "policy_type": "Volume Purchased",
            "deployment_style": deployment_style,
            "target_groups": target_str,
            "limitation_groups": ";\n".join(lim),
            "exclusion_groups": ";\n".join(exc),
        })

    # The VPP fallback path (used when the modern vpp-locations endpoint is
    # the only source available) doesn't supply scope information. Under the
    # rule "Volume Purchased apps with no Target are excluded", every fallback
    # entry would be dropped, so we don't bother calling it.

    managed_app_rows = [
        [r["app_name"], r["bundle_id"], r["version"], r["policy_type"],
         r["deployment_style"], r["target_groups"], r["limitation_groups"],
         r["exclusion_groups"]]
        for r in mac_app_rows
    ]

    # Merge policies + managed apps into unified App Scope list.
    # policy row:      [name, policy_type, version, deployment_style, targets, lims, excls]
    # managed app row: [name, bundle_id, version, policy_type, deployment_style, targets, lims, excls]
    # Unified:         [name, policy_type, version, deployment_style, targets, lims, excls]
    #
    # app_scope_row_link_info tracks per-row link info so the Name column
    # can be made clickable later. Each entry is (kind, id) where kind is
    # "policy" or "macapp", or None for rows that have no deep link. URL
    # builders run at sheet-spec time (further down main()).
    app_scope_rows: list[list] = []
    app_scope_row_link_info: list[tuple[str, int] | None] = []
    for _i, row in enumerate(policy_rows):
        # row: [name, policy_type, version, deployment_style, targets, lims, excls]
        app_scope_rows.append([row[0], row[1], row[2], row[3], row[4], row[5], row[6]])
        _pid_for_url = policy_row_ids[_i] if _i < len(policy_row_ids) else None
        app_scope_row_link_info.append(("policy", _pid_for_url) if isinstance(_pid_for_url, int) else None)
    for _i, r_dict in enumerate(mac_app_rows):
        row = managed_app_rows[_i]
        # row: [name, bundle_id, version, policy_type, deployment_style, targets, lims, excls]
        # drop bundle_id (index 1)
        app_scope_rows.append([row[0], row[3], row[2], row[4], row[5], row[6], row[7]])
        _app_id = r_dict.get("id")
        app_scope_row_link_info.append(("macapp", _app_id) if isinstance(_app_id, int) else None)


    # ── Restricted Software ───────────────────────────────────────────────────
    _section_start("Fetching restricted software list")
    rs_list = list_restricted_software(args.profile) if _have_macos_fleet else []
    _section_done("Restricted software entries found", len(rs_list))
    restricted_rows: list[list] = []
    # Parallel id list — same length as restricted_rows. Used to build
    # Name-column hyperlinks on the Restricted Software sheet.
    restricted_row_ids: list[int | None] = []

    if rs_list:
        _section_start("Fetching restricted software details")
    for _ri, rs in enumerate(rs_list, 1):
        rs_id = rs.get("id")
        if rs_id is None:
            continue
        _progress(_ri, len(rs_list), str(rs.get("name") or ""))
        full = get_restricted_software_json(int(rs_id), args.profile)
        general = full.get("general", {}) if isinstance(full, dict) else {}
        scope = full.get("scope", {}) if isinstance(full, dict) else {}

        tgt, lim, exc = extract_mac_app_scope(scope, "")
        scope_block = scope if isinstance(scope, dict) else {}
        all_computers = scope_targets_all(scope_block)
        target_str = "All Computers" if (not tgt and all_computers) else ";\n".join(tgt)

        # ── Orphan capture (Restricted Software) ─────────────────────────────
        rs_meta.append({
            "id": int(rs_id),
            "name": str(general.get("name") or ""),
            "process_name": str(general.get("process_name") or ""),
            "target_groups": list(tgt),
            "limitation_groups": list(lim),
            "excluded_groups": list(exc),
            "all_computers": all_computers,
        })
        used_groups.update(tgt)
        used_groups.update(lim)
        used_groups.update(exc)

        restricted_rows.append([
            str(general.get("name") or ""),
            str(general.get("process_name") or ""),
            "Yes" if general.get("kill_process") else "No",
            "Yes" if general.get("match_exact_process_name") else "No",
            "Yes" if general.get("delete_executable") else "No",
            "Yes" if general.get("send_notification") else "No",
            str(general.get("display_message") or ""),
            target_str,
            ";\n".join(exc),
        ])
        restricted_row_ids.append(int(rs_id))

    # ── Computer Prestages ────────────────────────────────────────────────────
    _section_start("Fetching computer prestage list")
    ps_list = list_computer_prestages(args.profile) if _have_macos_fleet else []
    _section_done("Prestages found", len(ps_list))
    # Prestage matrices: rows are settings, columns are prestage names.
    # _ps_general_fields / _ps_acct_fields define row order.
    _ps_general_fields = [
        ("Default Prestage",              lambda p: "Yes" if p.get("defaultPrestage") else "No"),
        ("Mandatory",                     lambda p: "Yes" if p.get("mandatory") else "No"),
        ("MDM Removable",                 lambda p: "Yes" if p.get("mdmRemovable") else "No"),
        ("Require Authentication",        lambda p: "Yes" if p.get("requireAuthentication") else "No"),
        ("Auto Advance Setup",            lambda p: "Yes" if p.get("autoAdvanceSetup") else "No"),
        ("Install Profiles During Setup", lambda p: "Yes" if p.get("installProfilesDuringSetup") else "No"),
        ("Prevent Activation Lock",       lambda p: "Yes" if p.get("preventActivationLock") else "No"),
        ("Device-Based Activation Lock",  lambda p: "Yes" if p.get("enableDeviceBasedActivationLock") else "No"),
        ("Enable Recovery Lock",          lambda p: "Yes" if p.get("enableRecoveryLock") else "No"),
        ("Recovery Lock Type",            lambda p: str(p.get("recoveryLockPasswordType") or "")),
        ("PSSO Enabled",                  lambda p: "Yes" if p.get("pssoEnabled") else "No"),
        ("PSSO App Bundle ID",            lambda p: str(p.get("platformSsoAppBundleId") or "")),
        ("Department",                    lambda p: str(p.get("department") or "")),
        ("Support Email",                 lambda p: str(p.get("supportEmailAddress") or "")),
        ("Support Phone",                 lambda p: str(p.get("supportPhoneNumber") or "")),
        ("Min OS Enforcement",            lambda p: str(p.get("prestageMinimumOsTargetVersionType") or "")),
        ("Min OS Version",                lambda p: str(p.get("minimumOsSpecificVersion") or "")),
    ]

    _ps_acct_fields = [
        ("Local Admin Enabled",           lambda a: "Yes" if a.get("localAdminAccountEnabled") else "No"),
        ("Admin Username",                lambda a: str(a.get("adminUsername") or "")),
        ("Hidden Admin Account",          lambda a: "Yes" if a.get("hiddenAdminAccount") else "No"),
        ("User Account Type",             lambda a: str(a.get("userAccountType") or "")),
        ("Prefill Account Info Enabled",  lambda a: "Yes" if a.get("prefillPrimaryAccountInfoFeatureEnabled") else "No"),
        ("Prefill Type",                  lambda a: str(a.get("prefillType") or "")),
        ("Prefill Full Name",             lambda a: str(a.get("prefillAccountFullName") or "")),
        ("Prefill Username",              lambda a: str(a.get("prefillAccountUserName") or "")),
        ("Prevent Prefill Modification",  lambda a: "Yes" if a.get("preventPrefillInfoFromModification") else "No"),
        ("Local User Managed",            lambda a: "Yes" if a.get("localUserManaged") else "No"),
    ]

    # Collect per-prestage data — build matrices after loop.
    _ps_data: list[dict] = []

    if ps_list:
        _section_start("Fetching prestage details")
    for _psi, ps_entry in enumerate(ps_list, 1):
        ps_id = ps_entry.get("id")
        ps_name = str(ps_entry.get("displayName") or ps_id or "")
        _progress(_psi, len(ps_list), ps_name)
        ps = get_computer_prestage_json(str(ps_id), args.profile)
        if not ps:
            ps = ps_entry

        _ps_data.append(ps)

    # ── Build matrix rows from collected prestage data ────────────────────────
    ps_names = [str(p.get("displayName") or p.get("id") or "") for p in _ps_data]

    # General matrix: col 0 = "Setting", then one col per prestage name
    prestage_general_rows: list[list] = []
    for label, fn in _ps_general_fields:
        row = [label] + [fn(p) for p in _ps_data]
        prestage_general_rows.append(row)

    # Setup assistant matrix: col 0 = "Setup Item", then one col per prestage
    # Collect union of all item keys in consistent order
    _setup_keys: list[str] = []
    for p in _ps_data:
        skip = p.get("skipSetupItems") or {}
        for k in skip:
            if k not in _setup_keys:
                _setup_keys.append(k)
    prestage_setup_rows: list[list] = []
    for item in _setup_keys:
        row = [item]
        for p in _ps_data:
            skip = p.get("skipSetupItems") or {}
            val = skip.get(item)
            row.append("Skip" if val else "Show")
        prestage_setup_rows.append(row)

    # Account settings matrix
    prestage_account_rows: list[list] = []
    for label, fn in _ps_acct_fields:
        row = [label]
        for p in _ps_data:
            acct = p.get("accountSettings") or {}
            row.append(fn(acct))
        prestage_account_rows.append(row)

    # Device counts per prestage — cross-reference inventory enrollmentMethod
    # We build the count map here; it's used when rendering the Prestages sheet.
    _ps_device_counts: dict[str, int] = {name: 0 for name in ps_names}

    # Column headers for all three: "Setting" + prestage names
    _ps_matrix_headers = ["Setting"] + ps_names

    # ── Health Check ──────────────────────────────────────────────────────────
    from datetime import timezone as _tz

    # Fleet-wide PSSO scope flag — set when ANY PSSO config profile is scoped
    # to All Computers, meaning every Mac in the tenant is expected to be
    # PSSO-registered. Used by the Health Check loop below to decide whether
    # an unregistered-PSSO row should be added per Mac. We deliberately only
    # fire on All Computers (rather than resolving per-group membership) to
    # avoid extra API calls and false positives on Macs that aren't actually
    # scoped to a narrower PSSO group.
    _psso_all_macs_scoped = any(
        p.get("all_computers") for p in psso_profiles
    )

    _section_start("Fetching computer inventory for health check")
    _need_fv    = "macOS - FileVault Recovery Keys" in selected_sheets
    _need_fleet = "macOS - Managed Macs"            in selected_sheets
    _need_msu_macos = "macOS - Software Updates"    in selected_sheets
    # DISK_ENCRYPTION section is intentionally NOT requested even when FV is
    # selected — it only carries encryption state, not the recovery key. The
    # dedicated FV endpoint (list_filevault_inventory) is the real source.
    # USER_AND_LOCATION feeds the assigned-user column on FV + Fleet.
    # EXTENSION_ATTRIBUTES is needed for the Managed Macs / Software Updates
    # sheets so Machine Role comes through populated on every row.
    if _have_macos_fleet:
        computers = list_computers_inventory(
            args.profile,
            include_disk_encryption=False,
            include_user_and_location=(_need_fv or _need_fleet or _need_msu_macos),
            include_extension_attributes=(_need_fleet or _need_msu_macos),
        )
    else:
        computers = []
    _section_done("Computers found", len(computers))
    health_rows: list[list] = []
    # Serial numbers that landed in health_rows — used by the Managed Macs
    # sheet to flag "In Health Check" without duplicating the issue logic.
    _health_serials: set[str] = set()

    _cutoff = datetime.now(_tz.utc).timestamp() - (180 * 86400)

    def _parse_dt(s: str | None) -> float | None:
        if not s:
            return None
        s = s.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        try:
            from datetime import datetime as _dt
            d = _dt.fromisoformat(s)
            if d.tzinfo is None:
                d = d.replace(tzinfo=_tz.utc)
            return d.timestamp()
        except Exception:
            return None

    def _data_partition_pct_used(storage: dict) -> tuple[int | None, float | None]:
        """Return (percentUsed, availableGB) for the Data partition."""
        for disk in (storage.get("disks") or []):
            for part in (disk.get("partitions") or []):
                if str(part.get("name") or "").strip().lower() == "data":
                    pct = part.get("percentUsed")
                    avail_mb = part.get("availableMegabytes")
                    avail_gb = round(avail_mb / 1024, 1) if avail_mb is not None else None
                    return (int(pct) if pct is not None else None, avail_gb)
        return (None, None)

    def _macos_major(version_str: str | None) -> int:
        if not version_str:
            return 0
        try:
            return int(str(version_str).split(".")[0])
        except Exception:
            return 0

    for comp in computers:
        general   = comp.get("general") or {}
        hardware  = comp.get("hardware") or {}
        os_info   = comp.get("operatingSystem") or {}
        storage   = comp.get("storage") or {}
        security  = comp.get("security") or {}

        comp_name    = str(general.get("name") or "")
        serial       = str(hardware.get("serialNumber") or "")
        model        = str(hardware.get("model") or "")
        os_version   = str(os_info.get("version") or "")

        # Helper: find first non-empty value from a named EA across general + hardware
        def _ea_val(name: str) -> str:
            name_l = name.strip().lower()
            for section_obj in (general, hardware):
                for ea in (section_obj.get("extensionAttributes") or []):
                    if str(ea.get("name") or "").strip().lower() == name_l:
                        vals = [v for v in (ea.get("values") or []) if v not in (None, "", [])]
                        return str(vals[0]) if vals else ""
            return ""

        role             = _ea_val("Machine Role")
        jsde_raw         = _ea_val("JSDE Setup")
        jsde_installed   = (jsde_raw.strip() == "1")
        jcl_version      = _ea_val("Jamf Connect Login Version")

        # ── Platform SSO registration state ─────────────────────────────
        # The community-canonical approach is an EA that runs
        # `/usr/bin/app-sso platform -s` and parses the JSON. We tolerate a
        # few common EA names. Treat the value as "not registered" only
        # when the EA exists AND clearly indicates an unregistered state.
        # When no EA is present we don't fire — we have no signal.
        _psso_ea_value = ""
        for _candidate in (
            "Platform SSO Registration", "Platform SSO Status",
            "Platform SSO State", "PSSO Status",
            "PlatformSSO Registration", "PSSO Registration",
        ):
            _psso_ea_value = _ea_val(_candidate)
            if _psso_ea_value:
                break
        _psso_ea_lower = _psso_ea_value.strip().lower()
        _psso_not_registered = bool(_psso_ea_lower) and (
            "not registered"   in _psso_ea_lower
            or "unregistered"  in _psso_ea_lower
            or _psso_ea_lower in ("disabled", "off", "missing", "none", "no", "false")
        )

        # Enrollment method / prestage
        enroll = general.get("enrollmentMethod") or {}
        enroll_type = str(enroll.get("objectType") or "")
        enroll_name = str(enroll.get("objectName") or "")
        if "user" in enroll_type.lower() and "initiated" in enroll_type.lower():
            enroll_display = "User-Initiated Enrollment"
        elif enroll_name:
            enroll_display = enroll_name
        else:
            enroll_display = enroll_type

        # Flags
        supervised       = general.get("supervised", None)
        last_contact_ts  = _parse_dt(general.get("lastContactTime"))
        mdm_expiry_ts    = _parse_dt(general.get("mdmProfileExpiration"))
        now_ts           = datetime.now(_tz.utc).timestamp()

        mdm_expired      = (mdm_expiry_ts is not None and mdm_expiry_ts < now_ts)
        stale            = (last_contact_ts is not None and last_contact_ts < _cutoff)
        unsupervised     = (supervised is False)
        # ── OS support tier ───────────────────────────────────────────────
        _os_major = _macos_major(os_version)
        _macos_names = {
            11: "Big Sur", 12: "Monterey", 13: "Ventura",
            14: "Sonoma", 15: "Sequoia", 26: "Tahoe",
        }
        # datajar N-2 support policy (as of Jun 2026):
        # Recommended:      26.x (Tahoe), 15.x (Sequoia)
        # Minimum Support:  14.x (Sonoma) - flagged for proactive planning
        # Untested:         13.x and earlier
        if _os_major in (26, 15):
            os_support_tier = None      # Recommended - no flag
            os_action_hint  = None
        elif _os_major == 14:
            os_support_tier = f"Minimum support - macOS {os_version} (Sonoma)"
            os_action_hint  = "Plan upgrade to macOS 15 or 26 before October 2026"
        elif _os_major > 0:
            _mn = _macos_names.get(_os_major, "")
            _mn_str = f" ({_mn})" if _mn else ""
            os_support_tier = f"Unsupported - macOS {os_version}{_mn_str}"
            os_action_hint  = "Schedule OS upgrade to macOS 15 or 26"
        else:
            os_support_tier = None
            os_action_hint  = None
        old_os = os_support_tier is not None
        bootstrap_ok = (str(security.get("bootstrapTokenEscrowedStatus") or "")).upper() == "ESCROWED"

        # ── Disk space: 5-tier check based on absolute GB free on Data ────
        # Healthy threshold matches macOS's own low-storage warning behaviour:
        #   50+ GB free       healthy (no flag)
        #   20-50 GB free     monitor closely (acceptable but tight for updates)
        #   15-20 GB free     macOS starts showing low-storage warnings
        #   <15 GB free       danger zone - perf degrades, updates may fail
        #   <5  GB free       critical - crashes / data-loss risk
        _data_pct, data_avail_gb = _data_partition_pct_used(storage)
        disk_issue: str | None = None
        disk_action: str | None = None
        if data_avail_gb is not None:
            if data_avail_gb < 5:
                disk_issue  = f"Disk critical ({data_avail_gb} GB free)"
                disk_action = "Free space urgently - crashes and data-loss risk"
            elif data_avail_gb < 15:
                disk_issue  = f"Disk danger zone ({data_avail_gb} GB free)"
                disk_action = "Run cleanup policy - performance degrading, updates may fail"
            elif data_avail_gb < 20:
                disk_issue  = f"Disk low ({data_avail_gb} GB free)"
                disk_action = "Free space - macOS will show low-storage warnings"
            elif data_avail_gb < 50:
                disk_issue  = f"Disk borderline ({data_avail_gb} GB free)"
                disk_action = "Monitor closely - updates may be tight"

        # Flag Jamf Connect Login v2 on macOS 26+ (requires v3+)
        jcl_v2_on_26 = (
            _macos_major(os_version) >= 26
            and jcl_version.strip().startswith("2.")
        )

        no_role = not role.strip()

        # ── FileVault recovery key escrow ─────────────────────────────────
        # Only check Macs whose Data partition is ENCRYPTED. If the key
        # field is missing from the payload entirely (API-role-driven
        # privacy default) we cannot tell - assume escrowed.
        fv_key_missing = False
        for _disk in (storage.get("disks") or []):
            for _part in (_disk.get("partitions") or []):
                if str(_part.get("name") or "").strip().lower() == "data":
                    if str(_part.get("fileVault2State") or "").upper() == "ENCRYPTED":
                        if "personalRecoveryKey" in _part:
                            _key = str(_part.get("personalRecoveryKey") or "").strip()
                            if not _key:
                                fv_key_missing = True
                    break

        # SIP - flag only explicit DISABLED. "NOT_COLLECTED" is an inventory
        # gap, not a SIP problem, so don't flag it.
        _sip_state = str(security.get("sipStatus") or "").upper()
        sip_disabled = (_sip_state and _sip_state != "ENABLED" and _sip_state != "NOT_COLLECTED")

        # Pending OS updates (requires SOFTWARE_UPDATES inventory section)
        _updates = comp.get("softwareUpdates")
        pending_update_count = len(_updates) if isinstance(_updates, list) else 0
        pending_updates = pending_update_count > 0

        # User-Approved MDM. Default to True if the field is absent so we
        # don't false-flag pre-supervised devices that don't carry the flag.
        user_approved_mdm = general.get("userApprovedMdm")
        user_approved_missing = (user_approved_mdm is False)

        # MDM-capable. The schema returns {"capable": bool, "capableUsers": [...]}.
        # Older schemas return a plain bool. Default-True on absent field.
        _mdm_cap = general.get("mdmCapable")
        if isinstance(_mdm_cap, dict):
            mdm_capable = bool(_mdm_cap.get("capable", True))
        elif isinstance(_mdm_cap, bool):
            mdm_capable = _mdm_cap
        else:
            mdm_capable = True
        not_mdm_capable = (mdm_capable is False)

        # Missing management ID
        _mgmt_id = str(general.get("managementId") or "").strip()
        missing_mgmt_id = not _mgmt_id

        # ── Battery health (laptops only) ─────────────────────────────────
        # Skip desktops - battery state is not relevant.
        _model_l = model.lower()
        _is_laptop = "macbook" in _model_l
        # Three signals; ANY of them flags the Mac:
        #   1. macOS condition label says "Service Recommended"
        #   2. Maximum capacity % below 80
        #   3. Cycle count at or above 1,000
        battery_problem = False
        battery_reasons: list[str] = []
        if _is_laptop:
            # Condition label - field name has varied across Jamf Pro versions.
            _bat_condition = ""
            for _k in ("batteryHealth", "batteryConditionLabel", "batteryCondition"):
                _v = hardware.get(_k)
                if _v:
                    _bat_condition = str(_v).strip()
                    break
            if "service" in _bat_condition.lower() and "recommended" in _bat_condition.lower():
                battery_problem = True
                battery_reasons.append("Service Recommended")

            # Maximum capacity %
            _bat_raw = hardware.get("batteryCapacityPercent")
            try:
                _battery_pct = int(_bat_raw) if _bat_raw is not None else None
            except (TypeError, ValueError):
                _battery_pct = None
            if _battery_pct is not None and _battery_pct < 80:
                battery_problem = True
                battery_reasons.append(f"{_battery_pct}% capacity")

            # Cycle count
            _bat_cycles_raw = hardware.get("batteryCycleCount")
            try:
                _battery_cycles = int(_bat_cycles_raw) if _bat_cycles_raw is not None else None
            except (TypeError, ValueError):
                _battery_cycles = None
            if _battery_cycles is not None and _battery_cycles >= 1000:
                battery_problem = True
                battery_reasons.append(f"{_battery_cycles} cycles")

        # Intel Mac detection - prefer hardware.appleSilicon when present,
        # else infer from processorArchitecture. If neither field is
        # available, assume Apple Silicon (don't false-flag).
        _apple_si = hardware.get("appleSilicon")
        if isinstance(_apple_si, bool):
            is_apple_silicon = _apple_si
        else:
            _arch = str(hardware.get("processorArchitecture") or "").lower()
            if _arch in ("arm64", "apple silicon", "aarch64"):
                is_apple_silicon = True
            elif _arch and ("intel" in _arch or "x86" in _arch):
                is_apple_silicon = False
            else:
                is_apple_silicon = True  # default - don't flag unknown
        intel_mac = not is_apple_silicon

        # ── Build (issue, action) pairs ────────────────────────────────────
        # Same order as the report should display them.
        issues_and_actions: list[tuple[str, str]] = []

        if no_role:
            issues_and_actions.append((
                "No role assigned",
                "Assign Machine Role EA in Jamf Pro inventory",
            ))
        if mdm_expired:
            issues_and_actions.append((
                "MDM Expired",
                "Re-enrol the Mac",
            ))
        if stale:
            _days_since = (
                int((now_ts - last_contact_ts) / 86400)
                if last_contact_ts is not None else 180
            )
            issues_and_actions.append((
                f"No check-in for {_days_since} days",
                "Verify device is online; archive if retired",
            ))
        if unsupervised:
            issues_and_actions.append((
                "Unsupervised",
                "Re-enrol via ADE / Apple Business Manager",
            ))
        if old_os:
            issues_and_actions.append((os_support_tier, os_action_hint or ""))
        if disk_issue:
            issues_and_actions.append((disk_issue, disk_action or ""))
        if not bootstrap_ok:
            issues_and_actions.append((
                "Bootstrap token not escrowed",
                "Re-enrol device to escrow bootstrap token",
            ))
        if jcl_v2_on_26:
            issues_and_actions.append((
                f"Jamf Connect Login {jcl_version} incompatible with macOS {os_version} (requires v3+)",
                "Update Jamf Connect Login to v3+ via Auto-Update policy",
            ))
        if fv_key_missing:
            issues_and_actions.append((
                "FileVault recovery key not escrowed",
                "Push FileVault Personal Recovery Key configuration profile",
            ))
        if sip_disabled:
            issues_and_actions.append((
                "SIP disabled",
                "Boot to recovery and re-enable System Integrity Protection",
            ))
        if pending_updates:
            issues_and_actions.append((
                f"Pending OS updates ({pending_update_count})",
                "Push DDM software-update enforcement",
            ))
        if user_approved_missing:
            issues_and_actions.append((
                "User-Approved MDM missing",
                "Walk user through MDM approval in System Settings",
            ))
        if not_mdm_capable:
            issues_and_actions.append((
                "Not MDM-capable",
                "Re-enrol via ADE; verify supervision",
            ))
        if missing_mgmt_id:
            issues_and_actions.append((
                "Missing managementId",
                "Reset MDM profile; re-enrol if persistent",
            ))
        if battery_problem:
            _reason_str = ", ".join(battery_reasons) if battery_reasons else "battery"
            issues_and_actions.append((
                f"Battery health ({_reason_str})",
                "Potential Battery Problem - Escalate to Apple",
            ))
        if intel_mac:
            issues_and_actions.append((
                "Intel Mac - refresh candidate",
                "Plan hardware refresh to Apple Silicon",
            ))
        # PSSO not registered — only fires when the tenant has a PSSO
        # profile scoped to All Computers AND a PSSO-status EA exists on
        # this Mac AND its value indicates unregistered. Silent when the
        # EA isn't deployed (no false positives on tenants without the EA).
        if _psso_all_macs_scoped and _psso_not_registered:
            issues_and_actions.append((
                f"Platform SSO not registered ({_psso_ea_value or 'unknown'})",
                "Have the user complete Platform SSO registration from "
                "System Settings → Users & Groups (or via Self Service if "
                "you ship a guided registration policy).",
            ))

        if not issues_and_actions:
            continue

        issues_str  = ";\n".join(i for i, _ in issues_and_actions)
        actions_str = ";\n".join(a for _, a in issues_and_actions if a)

        health_rows.append([
            comp_name,
            serial,
            model,
            os_version,
            issues_str,
            actions_str,
        ])
        _health_serials.add(serial.strip().lower())

    # ── Fleet stats for the Jamf MSP Summary ──────────────────────────────────
    # Two derived counts computed from the inventory we already fetched:
    #   * computers without FileVault enabled on their Data partition
    #   * computers that haven't checked in within the last 30 days
    _stale_30d_cutoff = datetime.now(_tz.utc).timestamp() - (30 * 86400)
    fleet_stale_30d = 0
    fleet_filevault_disabled = 0
    for _c in computers:
        _gen = _c.get("general") or {}
        _stg = _c.get("storage") or {}

        # Stale (30d)
        _lc = _parse_dt(_gen.get("lastContactTime"))
        if _lc is None or _lc < _stale_30d_cutoff:
            fleet_stale_30d += 1

        # FileVault: only count Macs whose Data partition isn't ENCRYPTED.
        # If the inventory doesn't expose the state at all, we don't count
        # it as disabled — better to under-report than alarm on missing data.
        _fv_known = False
        _fv_encrypted = False
        for _disk in (_stg.get("disks") or []):
            for _part in (_disk.get("partitions") or []):
                if str(_part.get("name") or "").strip().lower() == "data":
                    _state = str(_part.get("fileVault2State") or "").strip().upper()
                    if _state:
                        _fv_known = True
                        if _state == "ENCRYPTED":
                            _fv_encrypted = True
                    break
        if _fv_known and not _fv_encrypted:
            fleet_filevault_disabled += 1

    # Populate prestage device counts from inventory
    for comp in computers:
        _enroll = (comp.get("general") or {}).get("enrollmentMethod") or {}
        _obj_name = str(_enroll.get("objectName") or "")
        if _obj_name in _ps_device_counts:
            _ps_device_counts[_obj_name] += 1

    # Add device count rows to the General prestage matrix
    _total_in_prestages = sum(_ps_device_counts.values())
    _total_computers    = len(computers)
    _unassigned         = _total_computers - _total_in_prestages
    prestage_general_rows = (
        [["Devices Enrolled"] + [str(_ps_device_counts.get(n, 0)) for n in ps_names]]
        + [["Devices NOT in Prestage"] + [str(_unassigned)] + [""] * (len(ps_names) - 1)]
        + prestage_general_rows
    )

    # ── FileVault Personal Recovery Keys ──────────────────────────────────
    # The PRK is NOT returned by the bulk computers-inventory list endpoint
    # (even with --section DISK_ENCRYPTION, which only carries the encryption
    # state, not the key itself). Pull from the dedicated FileVault endpoint
    # `pro computers-inventory filevault --all`, then join to the inventory
    # we already have on computerId so we get name / serial / assigned user.
    fv_rows: list[list[Any]] = []
    if _need_fv and _have_macos_fleet:
        _section_start("Fetching FileVault recovery keys")
        _fv_records = list_filevault_inventory(args.profile)
        _section_done("FileVault records", len(_fv_records))

        # Index the inventory we already pulled for join lookups: by id, and
        # also by name as a backstop (FV endpoint sometimes carries name-only).
        _inv_by_id: dict[str, dict[str, Any]] = {}
        for _c in computers:
            _cid = str(_c.get("id") or (_c.get("general") or {}).get("id") or "").strip()
            if _cid:
                _inv_by_id[_cid] = _c

        # FV state, when not present in the FV record, gets a fallback from the
        # STORAGE section of the inventory we already have (Data partition's
        # fileVault2State).
        def _fv_state_from_inventory(comp: dict[str, Any]) -> str:
            for _disk in (comp.get("storage") or {}).get("disks") or []:
                for _part in (_disk.get("partitions") or []):
                    if str(_part.get("name") or "").strip().lower() == "data":
                        return str(_part.get("fileVault2State") or "").strip()
            return ""

        for _fv in _fv_records:
            _cid       = str(_fv.get("computerId") or _fv.get("id") or "").strip()
            _comp      = _inv_by_id.get(_cid, {})
            _gen       = _comp.get("general") or {}
            _user      = _comp.get("userAndLocation") or {}
            _hw        = _comp.get("hardware") or {}

            _comp_name = (str(_fv.get("name") or "").strip()
                          or str(_gen.get("name") or "").strip())
            _serial    = str(_hw.get("serialNumber")
                             or _gen.get("serialNumber") or "").strip()
            _assigned  = (str(_user.get("realname") or "").strip()
                          or str(_user.get("username") or "").strip())
            _email     = str(_user.get("email") or "").strip()

            _prk = str(_fv.get("personalRecoveryKey") or "").strip()

            # Encryption state comes from the FV record's bootPartitionEncryptionDetails
            # if present, else from the inventory's STORAGE section.
            _boot = _fv.get("bootPartitionEncryptionDetails") or {}
            _fv_state = ""
            if isinstance(_boot, dict):
                _fv_state = str(_boot.get("partitionFileVault2State") or "").strip()
            if not _fv_state:
                _fv_state = _fv_state_from_inventory(_comp)

            # Skip Macs whose Data partition isn't encrypted — they're noise
            # in a recovery-key handover sheet. UNKNOWN passes through so we
            # don't silently hide records the user might want to investigate.
            _fv_state_u = _fv_state.upper()
            if _fv_state_u in ("UNENCRYPTED", "DECRYPTED", "INELIGIBLE", ""):
                # If state is empty AND no key exists, skip — nothing useful.
                if not _prk:
                    continue

            if not _prk:
                # The endpoint returned a record but with no PRK. This is
                # either a Mac with FileVault on whose key wasn't escrowed,
                # or an institutional-only configuration. The
                # individualRecoveryKeyValidityStatus field tells us which.
                _validity = str(_fv.get("individualRecoveryKeyValidityStatus") or "").strip().upper()
                if _validity == "NOT_APPLICABLE":
                    _prk_display = "Institutional key only (no personal recovery key)"
                elif _validity in ("INVALID", "UNKNOWN"):
                    _prk_display = f"Not escrowed (status: {_validity.title()})"
                else:
                    _prk_display = "Not escrowed"
            else:
                _prk_display = _prk

            _last_inv = str(_gen.get("reportDate") or "").strip()
            if "T" in _last_inv:
                _last_inv = _last_inv.split("T", 1)[0]

            fv_rows.append([
                _comp_name, _serial, _assigned, _email,
                _fv_state.title() if _fv_state else "-",
                _prk_display, _last_inv,
            ])
        fv_rows.sort(key=lambda r: str(r[0]).lower())
        _section_done("FileVault recovery key rows", len(fv_rows))

    # ── LAPS Accounts — REMOVED ──────────────────────────────────────────────
    # The per-device LAPS account discovery loop has been dropped entirely.
    # We never want to risk triggering a password rotation (which viewing
    # a LAPS password does), and the handover-snapshot use case is better
    # served by retrieving credentials per device at cutover time on
    # demand. LAPS settings still appear on the Jamf MSP Summary when the
    # tenant has LAPS auto-deploy turned on.

    # ── Managed Macs (fleet inventory) ────────────────────────────────────
    # One row per Mac — the full managed fleet, not just unhealthy ones.
    # Columns ordered identity → ownership → hardware/OS → network → enrolment
    # → recency → handover-relevant flags. The final "In Health Check" column
    # cross-references the Health Check sheet so the reader can scan which
    # rows have outstanding issues without flipping between sheets.
    fleet_rows: list[list[Any]] = []
    if _need_fleet:
        _section_start("Building Managed Macs fleet sheet")

        def _ea_value(comp: dict[str, Any], ea_name: str) -> str:
            """First non-empty value of a named EA across general/hardware/userAndLocation."""
            name_l = ea_name.strip().lower()
            for section in ("general", "hardware", "userAndLocation"):
                obj = comp.get(section) or {}
                for ea in (obj.get("extensionAttributes") or []):
                    if str(ea.get("name") or "").strip().lower() == name_l:
                        vals = [v for v in (ea.get("values") or []) if v not in (None, "", [])]
                        if vals:
                            return str(vals[0])
            return ""

        def _short_date(s: str) -> str:
            if not s:
                return "-"
            s = str(s).strip()
            return s.split("T", 1)[0] if "T" in s else s

        for _c in computers:
            _gen   = _c.get("general") or {}
            _hw    = _c.get("hardware") or {}
            _os    = _c.get("operatingSystem") or {}
            _ulc   = _c.get("userAndLocation") or {}

            _name    = str(_gen.get("name") or "").strip()
            _serial  = str(_hw.get("serialNumber") or _gen.get("serialNumber") or "").strip()
            _model   = str(_hw.get("model") or "").strip()
            _osver   = str(_os.get("version") or "").strip()
            _user    = (str(_ulc.get("realname") or "").strip()
                        or str(_ulc.get("username") or "").strip())
            _role    = _ea_value(_c, "Machine Role")
            _enrolled_dt = _short_date(_gen.get("lastEnrolledDate"))
            _last_seen   = _short_date(_gen.get("lastContactTime"))

            # Enrolment method — prefer the prestage objectName; fall back to
            # "User-Initiated Enrollment" when the objectType says so; else
            # whatever Jamf returned.
            _enroll      = _gen.get("enrollmentMethod") or {}
            _enroll_type = str(_enroll.get("objectType") or "").strip()
            _enroll_name = str(_enroll.get("objectName") or "").strip()
            if "user" in _enroll_type.lower() and "initiated" in _enroll_type.lower():
                _enroll_display = "User-Initiated Enrollment"
            elif _enroll_name:
                _enroll_display = _enroll_name
            else:
                _enroll_display = _enroll_type or "-"

            _hc_pending = "Yes" if _serial.lower() in _health_serials else "No"

            fleet_rows.append([
                _name,
                _serial,
                _user,
                _role,
                _model,
                _osver,
                _enroll_display,
                _enrolled_dt,
                _last_seen,
                _hc_pending,
            ])

        fleet_rows.sort(key=lambda r: str(r[0]).lower())
        _section_done("Managed Macs rows", len(fleet_rows))

    # Ollama setup moved earlier (before catalog) — see below

    # ── Script metadata: description per script ────────────────────────────
    # Computed once per script, then merged into every row of the
    # macOS - Scripts sheet that references that script.
    _section_start("Fetching script descriptions")
    script_list = list_scripts(args.profile) if _have_macos_fleet else []
    _section_done("Scripts found", len(script_list))
    script_meta: dict[str, dict[str, Any]] = {}   # keyed by script name
    if script_list:
        _section_start("Summarising scripts")
    for _si, scr in enumerate(script_list, 1):
        scr_name = str(scr.get("name") or "")
        _progress(_si, len(script_list), scr_name)
        _scr_l = scr_name.strip().lower()
        if (
            "#" in scr_name
            or re.search(r' OLD\b', scr_name)
            or re.search(r'\btesting\b', _scr_l)
        ):
            continue
        _ai_generated = False
        override = SCRIPT_SUMMARY_OVERRIDES.get(scr_name.lower())
        if override:
            summary = override
        else:
            body  = str(scr.get("body") or "")
            notes = str(scr.get("notes") or "")
            if not body:
                body = get_script_body(scr_name, args.profile)
            if _use_ollama:
                ai_result = _ollama_describe_script(scr_name, body)
                if ai_result:
                    summary = ai_result
                    _ai_generated = True
                else:
                    summary = _summarise_script(body, notes=notes)
            else:
                summary = _summarise_script(body, notes=notes)

        script_meta[scr_name] = {"description": summary, "ai_generated": _ai_generated}
    if script_list:
        print(file=sys.stderr)

    # ── Extension Attributes ──────────────────────────────────────────────────
    _section_start("Fetching extension attributes")
    ea_list = list_computer_eas(args.profile) if _have_macos_fleet else []
    _section_done("Extension attributes found", len(ea_list))

    _ea_needing_ai = [
        ea for ea in ea_list
        if not str(ea.get("description") or "").strip()
        and str(ea.get("inputType") or "").upper() == "SCRIPT"
        and str(ea.get("name") or "").strip().lower() not in EA_DESCRIPTION_OVERRIDES
        and not str(ea.get("name") or "").strip().lower().startswith("license - ")
    ]
    _ea_ai_total = len(_ea_needing_ai) if _use_ollama else 0

    ea_rows: list[list[Any]] = []
    # Parallel id list — same length as ea_rows. Used to build Name-column
    # hyperlinks on the Extension Attributes sheet.
    ea_row_ids: list[int | None] = []
    _ea_ai_count = 0
    for ea in sorted(ea_list, key=lambda e: str(e.get("name") or "").lower()):
        ea_name   = str(ea.get("name") or "")
        ea_name_l = ea_name.strip().lower()
        ea_desc   = str(ea.get("description") or "").strip()

        # 1. Exact-name overrides (case-insensitive)
        if ea_name_l in EA_DESCRIPTION_OVERRIDES:
            ea_desc = EA_DESCRIPTION_OVERRIDES[ea_name_l]

        # 2. "License - <App Name>" pattern
        elif ea_name_l.startswith("license - "):
            app_name = ea_name[len("License - "):].strip()
            ea_desc = f"Assigns scope to install {app_name}"

        # 3. No description — try Ollama first, then fall back to script analysis
        _ai_generated = False
        if not ea_desc and str(ea.get("inputType") or "").upper() == "SCRIPT":
            script_body = str(ea.get("scriptContents") or "")
            if _use_ollama:
                _ea_ai_count += 1
                _progress(_ea_ai_count, _ea_ai_total, f"AI: {ea_name}")
                ai_result = _ollama_describe_ea(ea_name, script_body)
                if ai_result:
                    ea_desc = ai_result
                    _ai_generated = True
            if not ea_desc:
                ea_desc = _summarise_script(script_body)

        # 4. Discard useless single-word "String" placeholders
        if ea_desc.strip().lower() == "string":
            ea_desc = ""

        # Normalise inputType: the Jamf classic API returns "SCRIPT",
        # "POP_UP_MENU", "TEXT_FIELD", "LDAP_MAPPING". Convert to a
        # human-readable label for display.
        _ea_input_raw = str(ea.get("inputType") or "").strip().upper()
        _ea_input_label = {
            "SCRIPT":       "Script",
            "POP_UP_MENU":  "Pop-up Menu",
            "TEXT_FIELD":   "Text Field",
            "LDAP_MAPPING": "LDAP Mapping",
        }.get(_ea_input_raw, _ea_input_raw.title().replace("_", " ") or "-")

        ea_rows.append([
            ea_name,
            _ea_input_label,
            ea_desc if ea_desc else "[ No notes ]",
        ])
        ea_row_ids.append(ea.get("id") if isinstance(ea.get("id"), int) else None)

    if _use_ollama and _ea_ai_total > 0:
        print(file=sys.stderr)

    # ── AI: Config Profile summaries ──────────────────────────────────────────
    # Build a plain-text settings block per profile from settings_rows,
    # ask Ollama for a one-sentence summary, append to each scope_row.
    _profile_ai_summaries: dict[str, tuple[str, bool]] = {}
    if _use_ollama and scope_rows:
        _section_start("Generating AI config profile summaries")
        _profile_kv: dict[str, list[str]] = {}
        for _row in settings_rows:
            _pn, _key, _val = str(_row[0]), str(_row[3]), str(_row[4])
            if _pn not in _profile_kv:
                _profile_kv[_pn] = []
            if _key and _key not in ("payload_parse_status",):
                _profile_kv[_pn].append(f"{_key}: {_val}")
        for _cpi, _srow in enumerate(scope_rows, 1):
            _pname = str(_srow[0])
            _progress(_cpi, len(scope_rows), f"AI: {_pname}")
            _kv_text = "\n".join(_profile_kv.get(_pname, [])[:60])
            _summary = _ollama_summarise_profile(_pname, _kv_text) if _kv_text else ""
            _profile_ai_summaries[_pname] = (_summary, bool(_summary))
        print(file=sys.stderr)

    scope_rows = [
        row + [
            _profile_ai_summaries.get(str(row[0]), ("", False))[0],
        ]
        for row in scope_rows
    ]

    # Health Check suggested actions are pre-written static text — no AI.

    # ── Jamf MSP Summary ──────────────────────────────────────────────────────
    _section_start("Fetching instance summary")
    # Overview drives the rest of the summary (ADE/VPP tokens, certificates,
    # check-in frequency, etc.) — fetched here, not as part of the fleet probe.
    _overview     = fetch_instance_overview(args.profile)
    _jp_version   = fetch_jamf_pro_version(args.profile)
    # LAPS: only pull settings; we no longer query per-device passwords.
    # If the settings call comes back with auto-deploy disabled, we skip
    # the LAPS summary rows entirely so the report doesn't carry rows for
    # a feature the tenant isn't using.
    _laps         = fetch_laps_settings(args.profile)
    _sso          = fetch_sso_settings(args.profile)
    _cloud_ldaps  = fetch_cloud_ldap_servers(args.profile)
    # Jamf Connect Deployments row removed — `fetch_jamf_connect_deployments`
    # counted Jamf Pro-side config-profile entries, NOT the Jamf Connect Login
    # agents actually installed on Macs. Without a reliable per-Mac install
    # count, the figure was misleading, so the row is dropped from the
    # summary. If you ever want to add it back, build the count from the
    # macOS - Managed Macs inventory by looking for the Jamf Connect Login
    # bundle id in installed applications.
    _active_alerts = fetch_active_alerts(args.profile)
    _protect      = fetch_jamf_protect_status(args.profile)
    _failover_url = fetch_sso_failover(args.profile, _sso)
    _user_accts   = fetch_user_accounts(args.profile)

    def _ov(key: str) -> str:
        return _overview.get(key, "-")

    # Strip https:// and trailing slash from URL
    _raw_url = _ov("Server URL")
    _url_clean = _raw_url.replace("https://", "").replace("http://", "").rstrip("/")         if _raw_url != "-" else "-"

    # ── Jamf Pro UI deep-link builders ───────────────────────────────────────
    # Used across multiple sheet specs (Orphans, Scripts, EAs, Policies,
    # Profiles, Apps - Scope, Restricted Software). Returns "" when the
    # base URL is missing so the generic hyperlink pass simply skips those
    # cells (a hyperlink with no URL is omitted).
    _ui_base = _raw_url.rstrip("/") if isinstance(_raw_url, str) and _raw_url != "-" else ""

    def _url_policy(pid: int | None) -> str:
        return f"{_ui_base}/policies.html?id={pid}" if (_ui_base and pid is not None) else ""

    def _url_profile(pid: int | None) -> str:
        return f"{_ui_base}/OSXConfigurationProfiles.html?id={pid}" if (_ui_base and pid is not None) else ""

    def _url_script(sid: int | None) -> str:
        return f"{_ui_base}/view/settings/computer-management/scripts/{sid}" if (_ui_base and sid is not None) else ""

    def _url_ea(eid: int | None) -> str:
        return f"{_ui_base}/computerExtensionAttributes.html?id={eid}" if (_ui_base and eid is not None) else ""

    def _url_smart_group(gid: int | None) -> str:
        return f"{_ui_base}/smartComputerGroups.html?id={gid}&o=r" if (_ui_base and gid is not None) else ""

    def _url_static_group(gid: int | None) -> str:
        return f"{_ui_base}/staticComputerGroups.html?id={gid}&o=r" if (_ui_base and gid is not None) else ""

    def _url_mac_app(aid: int | None) -> str:
        return f"{_ui_base}/macApps.html?id={aid}" if (_ui_base and aid is not None) else ""

    def _url_restricted(rid: int | None) -> str:
        return f"{_ui_base}/restrictedSoftware.html?id={rid}" if (_ui_base and rid is not None) else ""

    def _url_package(pkid: int | None) -> str:
        return f"{_ui_base}/packages.html?id={pkid}&o=r" if (_ui_base and pkid is not None) else ""

    def _url_printer(prid: int | None) -> str:
        return f"{_ui_base}/printers.html?id={prid}&o=r" if (_ui_base and prid is not None) else ""

    def _url_computer(cid: int | str | None) -> str:
        # Classic Jamf Pro UI path for a single computer's inventory record.
        return f"{_ui_base}/computers.html?id={cid}&o=r" if (_ui_base and cid not in (None, "")) else ""

    # iOS deep links (classic + modern UI paths). Note: the iOS app page
    # is /mobileDeviceApps.html, NOT /iOSApps.html — the latter redirects
    # to the Jamf Pro landing page.
    def _url_ios_app(aid: int | None) -> str:
        return f"{_ui_base}/mobileDeviceApps.html?id={aid}&o=r" if (_ui_base and aid is not None) else ""

    def _url_ios_profile(pid: int | None) -> str:
        return f"{_ui_base}/iOSConfigurationProfiles.html?id={pid}" if (_ui_base and pid is not None) else ""

    def _url_ios_device(did: int | str | None) -> str:
        return f"{_ui_base}/mobileDevices.html?id={did}&o=r" if (_ui_base and did not in (None, "")) else ""

    def _url_ios_smart_group(gid: int | None) -> str:
        return f"{_ui_base}/smartMobileDeviceGroups.html?id={gid}&o=r" if (_ui_base and gid is not None) else ""

    def _url_ios_static_group(gid: int | None) -> str:
        return f"{_ui_base}/staticMobileDeviceGroups.html?id={gid}&o=r" if (_ui_base and gid is not None) else ""

    # Days remaining on ADE / VPP tokens — parse "Name — Mon DD, YYYY" format
    def _days_remaining(date_str: str) -> str:
        """Parse 'Label — Mon DD, YYYY' and return days remaining string."""
        if not date_str or date_str == "-":
            return "-"
        import re as _re
        # Find the date portion after the last "—" or "—"
        match = _re.search(r'[—\-]\s*([A-Za-z]{3}\s+\d{1,2},?\s+\d{4})\s*$', date_str)
        if not match:
            return date_str  # return as-is if we can't parse
        try:
            from datetime import datetime as _dt, timezone as _tz2
            dt = _dt.strptime(match.group(1).replace(",", ""), "%b %d %Y")
            days = (dt - _dt.now()).days
            status = "EXPIRED" if days < 0 else (f"{days} days remaining" if days < 90 else f"{days} days")
            return f"{dt.strftime('%d %b %Y')}  ({status})"
        except Exception:
            return date_str

    # Managed vs unmanaged
    _managed_mac   = _ov("Managed Computers")
    _unmanaged_mac = _ov("Unmanaged Computers")
    _managed_mob   = _ov("Managed Devices")
    _unmanaged_mob = _ov("Unmanaged Devices")

    try:
        _total_mac = int(_managed_mac) + int(_unmanaged_mac)
    except Exception:
        _total_mac = 0

    _total_mac_str = str(_total_mac) if _total_mac else "-"

    _section_done("Instance summary", 1)

    # ── Identity / SSO / Companion product derived values ──────────────────
    def _yesno(v: Any) -> str:
        if isinstance(v, bool):
            return "Yes" if v else "No"
        if v in (None, "", "-"):
            return "-"
        s = str(v).strip().lower()
        if s in ("true", "yes", "on", "enabled"):  return "Yes"
        if s in ("false", "no", "off", "disabled"): return "No"
        return str(v)

    def _seconds_to_human(v: Any) -> str:
        """Format seconds as 'N days' / 'N hours' / 'N minutes' for LAPS values."""
        try:
            secs = int(v)
        except (TypeError, ValueError):
            return "-"
        if secs <= 0:
            return "-"
        days, rem = divmod(secs, 86400)
        hours, rem = divmod(rem, 3600)
        mins = rem // 60
        parts: list[str] = []
        if days:  parts.append(f"{days}d")
        if hours: parts.append(f"{hours}h")
        if mins and not days: parts.append(f"{mins}m")
        return " ".join(parts) or f"{secs}s"

    # SSO is enabled when the get-call payload reports ssoEnabled=true (or
    # equivalent on older Pro versions). Provider string varies by Jamf
    # version — try a few common keys.
    _sso_enabled = _yesno(
        _sso.get("ssoEnabled") if "ssoEnabled" in _sso else _sso.get("enabled")
    )
    _sso_provider = (
        _sso.get("idpProviderType")
        or _sso.get("identityProvider")
        or _sso.get("ssoForMacOsManagementMode")
        or "-"
    )
    if _sso_enabled == "No":
        _sso_provider = "-"

    # SSO Configuration Type — SAML vs OIDC. Jamf Pro's payload uses different
    # keys across versions; check the common ones and fall back to "SAML" if
    # we see a SAML-specific field populated.
    _sso_config_type = str(
        _sso.get("configurationType")
        or _sso.get("ssoConfigurationType")
        or _sso.get("type")
        or ""
    ).strip().upper() or "-"
    if _sso_config_type == "-" and _sso.get("samlMetadata"):
        _sso_config_type = "SAML"
    if _sso_enabled == "No":
        _sso_config_type = "-"

    # Pull common overview keys defensively — Jamf renames these across
    # versions. _try_overview returns the first non-empty match.
    def _try_overview(*keys: str) -> str:
        for k in keys:
            v = _overview.get(k)
            if v and str(v).strip() not in ("", "-"):
                return str(v).strip()
        return "-"

    # PKI / external CA / SCEP / ADCS — Jamf surfaces these in the overview
    # output on recent versions. Key names vary, so we try several.
    _external_ca_enroll = _try_overview(
        "External CA Enabled for Enrollment",
        "External CA enabled for enrollment",
        "External CA for Enrollment",
    )
    _scep_proxy_cfg     = _try_overview(
        "Jamf Pro SCEP Proxy for Config Profile",
        "Jamf Pro Scep Proxy for Config Profile",
        "SCEP Proxy for Configuration Profiles",
        "SCEP Proxy",
    )
    _adcs               = _try_overview("ADCS", "AD CS", "Active Directory Certificate Services")

    # Intune integration — appears in overview on tenants where macOS
    # conditional access is set up. If absent, the macro returns "-".
    _intune_enabled = _try_overview(
        "macOS Intune Integration Enabled",
        "Microsoft Intune Integration",
        "Intune Integration",
        "Conditional Access (macOS)",
    )

    # Account counts — derived from the user-accounts payload. We never list
    # local account names — only counts. LDAP accounts have a populated
    # ldapServerId / directoryUserId; everything else is "local".
    _total_accts = len(_user_accts)
    _ldap_accts  = 0
    _local_accts = 0
    for _a in _user_accts:
        if not isinstance(_a, dict):
            continue
        _is_ldap = bool(
            _a.get("ldapServerId")
            or _a.get("directoryUserId")
            or str(_a.get("accessLevel") or "").lower() in ("ldap", "ldap account")
            or str(_a.get("userType") or "").upper() in ("LDAP", "CLOUD_LDAP")
        )
        if _is_ldap:
            _ldap_accts += 1
        else:
            _local_accts += 1

    # LDAP / Cloud IdP summary: count of configured cloud IdPs, plus the
    # first provider name if exactly one. The full list of LDAP servers is
    # out of scope (privacy: server URLs / bind DNs can be sensitive).
    if not _cloud_ldaps:
        _ldap_summary = "Not configured"
    elif len(_cloud_ldaps) == 1:
        _name = (_cloud_ldaps[0].get("displayName")
                 or _cloud_ldaps[0].get("provider")
                 or "Configured")
        _ldap_summary = f"1 server ({_name})"
    else:
        _ldap_summary = f"{len(_cloud_ldaps)} servers configured"

    # Jamf Protect: presence of the integration record means enabled.
    _protect_enabled = _yesno(bool(_protect) and bool(
        _protect.get("apiClientId") or _protect.get("registrationId")
        or _protect.get("protectUrl")
    ))

    # LAPS: keys differ across Jamf Pro versions; try the common ones.
    _laps_enabled    = _yesno(_laps.get("autoDeployEnabled")
                              or _laps.get("autoLapsEnabled"))
    _laps_auto_rot   = _yesno(_laps.get("autoRotateEnabled"))
    _laps_rot_time   = _seconds_to_human(
        _laps.get("passwordRotationTime") or _laps.get("autoRotateExpirationTime")
    )
    _laps_exp_time   = _seconds_to_human(_laps.get("autoExpirationTime"))

    # App Policies = sum of Auto-Update + Manually Installed (both in
    # policy_rows) + VPP (mac_app_rows). Replaces the old "App Installers"
    # count from `pro overview`, which referenced the Jamf-built-in App
    # Installers feature this MSP doesn't use.
    _app_policy_count = (
        (len(policy_rows) if isinstance(policy_rows, list) else 0)
        + (len(mac_app_rows) if isinstance(mac_app_rows, list) else 0)
    )

    # Active Alerts → one row per alert (label includes type + params).
    # When there are no alerts, show a single "-" row (auto-pruned).
    if _active_alerts:
        _alert_rows = [["Active Alerts", _active_alerts[0]]] + [
            ["", a] for a in _active_alerts[1:]
        ]
    else:
        _alert_rows = [["Active Alerts", "None"]]

    # ── Platform SSO summary metrics ─────────────────────────────────────────
    # Derived from the psso_profiles list populated during the config-profile
    # payload scan above. Aggregated to four operator-meaningful values:
    #   * configured? — at least one PSSO profile exists with scope
    #   * IdP        — distinct IdPs detected (most fleets have one)
    #   * active     — number of PSSO profiles with at least one target
    #   * coverage   — "All Computers" vs N targeted groups
    # Tenants with no PSSO profiles end up with all rows = "-", which the
    # auto-pruner drops along with the section header.
    _psso_active = [
        p for p in psso_profiles
        if p.get("target_groups") or p.get("all_computers")
    ]
    if _psso_active:
        _psso_configured = "Yes"
        _psso_idps = sorted({str(p.get("idp") or "-") for p in _psso_active})
        _psso_idp_str = ", ".join(i for i in _psso_idps if i and i != "-") or "-"
        _psso_count_str = str(len(_psso_active))
        _psso_all_macs = any(p.get("all_computers") for p in _psso_active)
        if _psso_all_macs:
            _psso_scope_str = "All Computers"
        else:
            _scope_groups = sorted({
                g for p in _psso_active for g in (p.get("target_groups") or [])
            })
            _psso_scope_str = (
                f"{len(_scope_groups)} computer group{'s' if len(_scope_groups) != 1 else ''}"
                if _scope_groups else "-"
            )
        # Auth method: distinguish modern (UserSecureEnclaveKey / DDM PSSO)
        # from legacy SAML/Kerberos extensiblesso. We only flag a profile as
        # PSSO if one of those modern signals fires, so the value here is
        # almost always a Yes summary; surface it explicitly anyway so the
        # admin can confirm.
        _auth_methods = sorted({
            (p.get("auth_method") or "").strip() or "UserSecureEnclaveKey"
            for p in _psso_active
        })
        _psso_auth_str = ", ".join(_auth_methods) or "-"
    else:
        _psso_configured = "No"
        _psso_idp_str    = "-"
        _psso_count_str  = "-"
        _psso_scope_str  = "-"
        _psso_auth_str   = "-"

    # Build vertical summary rows: [Setting, Value]
    summary_rows: list[list] = [
        ["Jamf Pro Instance",         _url_clean],
        ["Failover URL",              _failover_url or "-"],
        ["Jamf Pro Version",          _jp_version or _ov("Jamf Pro Version")],
        ["Report Generated",          datetime.now().strftime("%d %B %Y %H:%M")],
        ["", ""],
        # macOS Fleet section only appears when there are managed Macs.
        *([
            ["+ macOS Fleet +",          ""],
            ["Managed Computers",         _managed_mac],
            ["Unmanaged Computers",       _unmanaged_mac],
            ["Total macOS Devices",       _total_mac_str],
            ["Macs Without FileVault",    str(fleet_filevault_disabled)],
            ["Not Reporting (30 days)",   str(fleet_stale_30d)],
            ["", ""],
        ] if _have_macos_fleet else []),
        # Mobile Fleet section only appears when there are managed iOS devices.
        *([
            ["+ Mobile Fleet +",         ""],
            ["Managed Mobile Devices",    _managed_mob],
            ["Unmanaged Mobile Devices",  _unmanaged_mob],
            ["", ""],
        ] if _have_ios_fleet else []),
        ["+ Enrollment & Certificates +",  ""],
        ["ADE Instances",             _ov("ADE Instances")],
        ["ADE Token Expires",         _days_remaining(_ov("ADE Token Expires"))],
        ["ADE Sync Status",           _ov("ADE Sync Status")],
        ["VPP Locations",             _ov("VPP Locations")],
        ["VPP Token Expires",         _days_remaining(_ov("VPP Token Expires"))],
        ["APNs Certificate Expires",  _days_remaining(
            _ov("Push Certificate Expires")
            if _ov("Push Certificate Expires") != "-"
            else _ov("APNs Certificate Expires")
        )],
        ["Built-In CA Expires",       _days_remaining(_ov("Built-In CA Expires"))],
        ["Tomcat SSL Cert Expires",   _days_remaining(
            _ov("Tomcat SSL Certificate Expires")
            if _ov("Tomcat SSL Certificate Expires") != "-"
            else _ov("SSL Certificate Expires")
        )],
        # MDM Auto Renew rows dropped — auto-renew is the default and not
        # actionable information.
        ["", ""],
        ["+ Configuration +",         ""],
        ["Policies",                  _ov("Policies")],
        ["macOS Config Profiles",     _ov("macOS Config Profiles")],
        ["iOS Config Profiles",       _ov("iOS Config Profiles")],
        ["Packages",                  _ov("Packages")],
        ["Scripts",                   _ov("Scripts")],
        # App Policies replaces the old App Installers row. Counts the
        # macOS app-deployment policies the customer actually uses:
        # Auto-Update, Manually Installed, and Volume Purchased (VPP).
        ["App Policies (Auto-Update / Manually Installed / VPP)",
                                      str(_app_policy_count) if _app_policy_count else "-"],
        ["Check-In Frequency",        _ov("Check-In Frequency")],
        ["", ""],
        ["+ PKI / Certificates +",    ""],
        ["External CA for Enrollment",        _external_ca_enroll],
        ["Jamf Pro SCEP Proxy (Config Profiles)", _scep_proxy_cfg],
        ["AD CS",                              _adcs],
        ["", ""],
        ["+ SSO / Integrations +",    ""],
        ["LDAP / Cloud IdP",          _ldap_summary],
        ["SSO Enabled",               _sso_enabled],
        ["SSO Configuration Type",    _sso_config_type],
        ["SAML Identity Provider",
            (str(_sso_provider) if _sso_config_type == "SAML"
             and _sso_provider not in ("", "-") else "-")],
        ["macOS Intune Integration Enabled",  _intune_enabled],
        # Jamf Connect Deployments row dropped — see _active_alerts fetch
        # site for the reason.
        ["Jamf Protect Enabled",      _protect_enabled],
        ["", ""],
        # Platform SSO — derived from extensiblesso config-profile payloads
        # in the macOS Config Profiles scan. All "-" values cause the
        # section to auto-prune for tenants that haven't configured PSSO.
        ["+ Platform SSO +",                ""],
        ["Platform SSO Configured",         _psso_configured],
        ["Detected IdP(s)",                 _psso_idp_str],
        ["Active PSSO Profiles",            _psso_count_str],
        ["PSSO Scope",                      _psso_scope_str],
        ["Authentication Method",           _psso_auth_str],
        ["", ""],
        ["+ Jamf Pro Accounts +",     ""],
        ["Total Accounts",            str(_total_accts) if _total_accts else "-"],
        ["LDAP Accounts",             str(_ldap_accts)  if _total_accts else "-"],
        ["Local Accounts",            str(_local_accts) if _total_accts else "-"],
        ["", ""],
        # LAPS section appears ONLY when the tenant has LAPS auto-deploy on.
        # Tenants that don't use LAPS at all see no LAPS rows in the summary.
        *([
            ["+ Local Admin Password (LAPS) +", ""],
            ["LAPS Auto-Deploy Enabled",  _laps_enabled],
            ["LAPS Auto-Rotate Enabled",  _laps_auto_rot],
            ["LAPS Rotation Time",        _laps_rot_time],
            ["LAPS Auto Expiration",      _laps_exp_time],
            ["", ""],
        ] if _laps_enabled == "Yes" else []),
        ["+ Health +",                ""],
        ["Health Status",             _ov("Health Status")],
        # Active Alerts: one row per alert; if there are none we show a
        # single "None" row so the section header survives the auto-prune.
        *_alert_rows,
        ["", ""],
    ]

    # ── Filter out empty / dash-only rows from the summary ──────────────────
    # A row is considered empty if its value is blank or "-". Section headers
    # (the "+ ... +" rows with no value) are also dropped if no value-rows
    # under them survive, so we don't end up with stranded headers.
    def _is_header(row: list) -> bool:
        label = str(row[0] or "")
        value = str(row[1] or "")
        return label.startswith("+ ") and label.endswith(" +") and value == ""

    def _is_blank_spacer(row: list) -> bool:
        return str(row[0] or "") == "" and str(row[1] or "") == ""

    def _has_value(row: list) -> bool:
        value = str(row[1] or "").strip()
        return value not in ("", "-")

    # Pass 1: keep header + spacer rows, drop empty-value data rows.
    _kept: list[list] = []
    for r in summary_rows:
        if _is_header(r) or _is_blank_spacer(r) or _has_value(r):
            _kept.append(r)

    # Pass 2: drop headers whose section has no value rows after them.
    _final: list[list] = []
    i = 0
    while i < len(_kept):
        r = _kept[i]
        if _is_header(r):
            # Look ahead until next header or end. If no _has_value rows in
            # between, skip this header.
            j = i + 1
            has_content = False
            while j < len(_kept) and not _is_header(_kept[j]):
                if _has_value(_kept[j]):
                    has_content = True
                    break
                j += 1
            if not has_content:
                # Skip the header AND any spacer immediately after it.
                i += 1
                while i < len(_kept) and _is_blank_spacer(_kept[i]):
                    i += 1
                continue
        _final.append(r)
        i += 1

    # Pass 3: collapse runs of consecutive spacers into a single spacer.
    summary_rows = []
    last_was_spacer = False
    for r in _final:
        if _is_blank_spacer(r):
            if last_was_spacer:
                continue
            last_was_spacer = True
        else:
            last_was_spacer = False
        summary_rows.append(r)
    # Trim trailing spacer.
    while summary_rows and _is_blank_spacer(summary_rows[-1]):
        summary_rows.pop()

        # ── Dispatch to output handler ───────────────────────────────────────────

    # ── Hybrid Users matrix ─────────────────────────────────────────────────
    _section_start("Fetching account groups for hybrid users")
    all_groups = fetch_account_groups(args.profile)
    _section_done("Account groups found", len(all_groups))

    hybrid_groups = [g for g in all_groups if "hybrid" in str(g.get("name") or "").lower()]
    _hg_names = [str(g.get("name") or "") for g in hybrid_groups]

    _hg_users: dict[str, dict] = {}
    for grp in hybrid_groups:
        for m in (grp.get("members") or []):
            uname = str(m.get("username") or "")
            if uname and uname not in _hg_users:
                _hg_users[uname] = {
                    "username": uname,
                    "email":    str(m.get("email") or ""),
                    "display":  str(m.get("realname") or "") or uname,
                }

    hybrid_rows: list[list] = []
    for uname, udata in sorted(_hg_users.items(), key=lambda x: x[1]['display'].lower()):
        row = [udata["display"], udata["username"], udata["email"]]
        for grp in hybrid_groups:
            members_in_grp = {str(m.get("username") or "") for m in (grp.get("members") or [])}
            if uname in members_in_grp:
                access = str(grp.get("accessLevel") or "")
                priv   = str(grp.get("privilegeLevel") or "")
                row.append(f"{access} / {priv}")
            else:
                row.append("-")
        hybrid_rows.append(row)

    hybrid_headers = ["Display Name", "Username", "Email"] + _hg_names

    # ── Policy-script links: sort for the macOS - Scripts sheet ─────────────
    # The Scripts sheet (built earlier) already covers the "which scripts are
    # used by which policies" angle. This sheet drills into the per-link
    # parameters and is kept separate.
    #
    # Sort by SCRIPT name first, then policy name — Scripts sheet is now
    # script-centric (Script Name is the leftmost column / clickable link).
    # The internal raw row layout coming in here is still:
    #   [policy_name, script_name, p4, p5, p6, p7, p8, p9, p10, p11]
    # The parallel (policy_id, script_id) list is sorted in lock-step so
    # downstream Name-column hyperlinks point at the right rows.
    _ps_combined = list(zip(policy_script_links, policy_script_link_ids))
    _ps_combined.sort(key=lambda pair: (str(pair[0][1]).lower(), str(pair[0][0]).lower()))
    policy_script_links     = [pair[0] for pair in _ps_combined]
    policy_script_link_ids  = [pair[1] for pair in _ps_combined]

    # Only keep parameter columns that have at least one non-empty value across
    # all rows — a sea of empty Parameter 8/9/10/11 columns is just noise.
    # Parameter slots live at raw row indexes 2..9 (p4..p11).
    _param_used = [
        any(str(r[2 + i]).strip() for r in policy_script_links)
        for i in range(8)
    ]
    _param_headers = [f"Parameter {4 + i}" for i, used in enumerate(_param_used) if used]

    # New column order (user-requested): Script Name | Linked to Policy |
    # Notes | Parameters. _enrich() reorders the raw row into this shape.
    policy_script_link_headers = [
        "Script Name", "Linked to Policy", "Notes",
    ] + _param_headers

    def _enrich(r: list[Any]) -> list[Any]:
        # Raw r is [policy_name, script_name, p4..p11]. Output reorders to
        # [script_name, policy_name, notes, *params].
        pname, sname = str(r[0]), str(r[1])
        meta  = script_meta.get(sname)
        desc  = meta["description"]  if meta is not None else ""
        params = [r[2 + i] for i, used in enumerate(_param_used) if used]
        return [sname, pname, desc] + params

    policy_script_links = [_enrich(r) for r in policy_script_links]

    datestamp_display = datetime.now().strftime("%d %B %Y")

    # Sheets are inserted in the order the customer reads them.
    # Jamf MSP Summary first (cross-platform), then the macOS-specific group
    # in the order requested. Jamf Pro Accounts (cross-platform) appears
    # at the end and only when the tenant has hybrid admin groups. When iOS
    # reporting is added later it will sit in its own "iOS - …" group between
    # the macOS group and the cross-platform extras.
    all_sheets: dict[str, dict[str, Any]] = {}

    all_sheets["Jamf MSP Summary"] = {
        "title": f"Jamf MSP Summary",
        "headers": ["Setting", "Value"],
        "rows": summary_rows,
        "summary_style": True,
    }

    # Reference sheet — explains each Health Check flag and why it matters.
    # Static content, defined alongside the checks at module level. The
    # Reference column pulls from HEALTH_CHECK_REFERENCES (a static URL cache
    # at module top) so we never go out to the network at runtime.
    all_sheets["macOS - Health Check Key"] = {
        "title": f"macOS  |  Health Check Definitions",
        "headers": ["Check", "What it flags", "Why it matters", "Reference"],
        "rows": [
            list(row) + [HEALTH_CHECK_REFERENCES.get(row[0], "-")]
            for row in HEALTH_CHECK_DEFINITIONS
        ],
        # Sheet-level styling overrides — only this sheet gets 50%-grey
        # vertical separators between columns and character-count-based row
        # auto-height so the "Why it matters" copy wraps cleanly.
        "vertical_grid_50pct": True,
        "autoheight_wrap": True,
        # Shared blue tab colour pairs this Key with its Health Check sheet.
        "tab_color": _TAB_HC_MACOS,
    }

    all_sheets["macOS - Health Check"] = {
        "title": f"macOS  |  Health Check",
        "headers": [
            "Computer Name", "Serial Number", "Model",
            "macOS Version", "Issues", "Suggested Actions",
        ],
        "rows": health_rows,
        # Same tab colour as the Key sheet + hover tooltips on each flagged
        # issue (pulls "why it matters" from the macOS definitions).
        "tab_color": _TAB_HC_MACOS,
        "issue_comment_platform": "macos",
    }

    if _need_fleet:
        all_sheets["macOS - Managed Macs"] = {
            "title": f"macOS  |  Managed Macs",
            "headers": [
                "Computer Name", "Serial Number", "Username",
                "Machine Role", "Model", "macOS Version",
                "Enrolment Method", "Enrolled Date", "Last Check-In",
                "Health Check Pending",
            ],
            "rows": fleet_rows,
        }

    all_sheets["macOS - Prestages"] = {
        "title": f"macOS  |  Prestages",
        "headers": _ps_matrix_headers,
        "rows": (
            [["+ General +"] + [""] * len(ps_names)]
            + prestage_general_rows
            + [["", ""] if len(_ps_matrix_headers) <= 2 else [""] + [""] * len(ps_names)]
            + [["+ Setup Assistant +"] + [""] * len(ps_names)]
            + prestage_setup_rows
            + [[""] + [""] * len(ps_names)]
            + [["+ Account Settings +"] + [""] * len(ps_names)]
            + prestage_account_rows
        ),
        "summary_style": True,
    }

    # ── Build Name-column hyperlink maps per sheet ──────────────────────────
    # Each map: {(data_row_idx_0based, name_col_idx_0based): url}. Empty
    # URLs (missing item id, missing base URL) are silently skipped by the
    # generic hyperlink pass inside build_workbook.
    _settings_hyperlinks = {
        (i, 0): _url_profile(settings_row_ids[i])
        for i in range(min(len(settings_rows), len(settings_row_ids)))
        if settings_row_ids[i] is not None
    }
    _scope_hyperlinks = {
        (i, 0): _url_profile(scope_row_ids[i])
        for i in range(min(len(scope_rows), len(scope_row_ids)))
        if scope_row_ids[i] is not None
    }
    _app_scope_hyperlinks: dict[tuple[int, int], str] = {}
    for _i, info in enumerate(app_scope_row_link_info):
        if info is None:
            continue
        _kind, _id = info
        _u = _url_policy(_id) if _kind == "policy" else _url_mac_app(_id)
        if _u:
            _app_scope_hyperlinks[(_i, 0)] = _u

    # Scripts sheet: column order is now Script Name (col 0) | Linked to
    # Policy (col 1) | Notes | Parameters. Hyperlink mapping mirrors the
    # column swap — script URL on col 0, policy URL on col 1.
    _scripts_hyperlinks: dict[tuple[int, int], str] = {}
    for _i, (_pid_x, _sid_x) in enumerate(policy_script_link_ids):
        if _sid_x is not None:
            _su = _url_script(_sid_x)
            if _su:
                _scripts_hyperlinks[(_i, 0)] = _su
        if _pid_x is not None:
            _pu = _url_policy(_pid_x)
            if _pu:
                _scripts_hyperlinks[(_i, 1)] = _pu

    _ea_hyperlinks = {
        (i, 0): _url_ea(ea_row_ids[i])
        for i in range(min(len(ea_rows), len(ea_row_ids)))
        if ea_row_ids[i] is not None
    }
    _rs_hyperlinks = {
        (i, 0): _url_restricted(restricted_row_ids[i])
        for i in range(min(len(restricted_rows), len(restricted_row_ids)))
        if restricted_row_ids[i] is not None
    }

    all_sheets["macOS - Config Profiles"] = {
        "title": f"macOS  |  Config Profiles",
        "headers": [
            "Profile Name", "Payload Type",
            "Payload Display Name", "Setting Key", "Value",
            "Targets", "Exclusions",
        ],
        "rows": settings_rows,
        "hyperlinks": _settings_hyperlinks,
    }

    all_sheets["macOS - Config Profiles - Scope"] = {
        "title": f"macOS  |  Config Profiles - Scope",
        "headers": ["Profile Name", "Category", "Targets", "Limitations",
                    "Exclusions", "Notes"],
        "rows": scope_rows,
        "hyperlinks": _scope_hyperlinks,
    }

    all_sheets["macOS - Apps - Scope"] = {
        "title": f"macOS  |  Apps - Scope",
        "headers": [
            "App / Policy Name", "Policy Type", "Version",
            "Deployment Style", "Targets", "Limitations", "Exclusions",
        ],
        "rows": app_scope_rows,
        "hyperlinks": _app_scope_hyperlinks,
    }

    # Scripts sheet — per-link parameter4..11 values plus the per-script
    # description / summary. One row per (policy, script) attachment.
    all_sheets["macOS - Scripts"] = {
        "title": f"macOS  |  Scripts",
        "headers": policy_script_link_headers,
        "rows": policy_script_links,
        "hyperlinks": _scripts_hyperlinks,
    }

    all_sheets["macOS - Extension Attributes"] = {
        "title": f"macOS  |  Extension Attributes",
        "headers": ["Name", "Input Type", "Notes"],
        "rows": ea_rows,
        "hyperlinks": _ea_hyperlinks,
    }

    all_sheets["macOS - Restricted Software"] = {
        "title": f"macOS  |  Restricted Software",
        "headers": [
            "Name", "Process Name", "Kill Process", "Match Exact Name",
            "Delete Executable", "Send Notification", "Display Message",
            "Targets", "Exclusions",
        ],
        "rows": restricted_rows,
        "hyperlinks": _rs_hyperlinks,
    }

    # ── Printers sheet ───────────────────────────────────────────────────────
    # Two sections in one sheet:
    #   1) Policies that look printer-related (any policy with "Printer" in
    #      the name) along with the pkg/dmg they attach and any scripts +
    #      parameter values.
    #   2) Printer objects configured under Jamf Pro Settings → Computer
    #      Management → Printers.
    # Empty sections are dropped. If both are empty, the sheet is omitted.
    _printer_section_rows: list[list[Any]] = []
    _printer_hyperlinks: dict[tuple[int, int], str] = {}

    # Sheet uses 11 columns total — same shape as macOS - Scripts:
    # [Policy/Printer, Attachment Type, Package, Script, Parameter 4..10].
    # Section banners and configured-printer rows pad to this width.
    _PRINTER_COLS = 11
    _printer_pad = [""] * (_PRINTER_COLS - 1)

    if printer_policy_rows:
        _printer_section_rows.append(["+ Policies +", *_printer_pad])
        for _row, _rpid in zip(printer_policy_rows, printer_policy_row_ids):
            _data_idx = len(_printer_section_rows)
            # Already 11-wide from the policy-capture loop above.
            _printer_section_rows.append(list(_row))
            _u = _url_policy(_rpid)
            if _u:
                _printer_hyperlinks[(_data_idx, 0)] = _u

    if classic_printer_rows:
        if _printer_section_rows:
            _printer_section_rows.append([""] * _PRINTER_COLS)
        _printer_section_rows.append(
            ["+ Configured Printers +", *_printer_pad]
        )
        # Column-header row inside the sheet — keeps the printer block
        # readable now that the columns mean something different from the
        # policy block above. Treated as a normal data row (just styled
        # by content).
        _printer_section_rows.append(
            ["Name", "Model", "Location", "URI", "CUPS Name",
             *[""] * (_PRINTER_COLS - 5)]
        )
        for _row, _rid in zip(classic_printer_rows, classic_printer_row_ids):
            _data_idx = len(_printer_section_rows)
            # Map detail row → first 5 cols (Name | Model | Location | URI |
            # CUPS Name), then pad to 11 to match the Policies block above.
            _printer_section_rows.append([
                _row[0], _row[1], _row[2], _row[3], _row[4],
                *[""] * (_PRINTER_COLS - 5),
            ])
            _u = _url_printer(_rid)
            if _u:
                _printer_hyperlinks[(_data_idx, 0)] = _u

    if _printer_section_rows:
        all_sheets["macOS - Printers"] = {
            "title": f"macOS  |  Printers",
            "headers": [
                "Policy / Printer",
                "Attachment Type",
                "Package",
                "Script",
                "Parameter 4",
                "Parameter 5",
                "Parameter 6",
                "Parameter 7",
                "Parameter 8",
                "Parameter 9",
                "Parameter 10",
            ],
            "rows": _printer_section_rows,
            "summary_style": True,
            "hyperlinks": _printer_hyperlinks,
        }

    if _need_fv:
        all_sheets["macOS - FileVault Recovery Keys"] = {
            "title": f"macOS  |  FileVault Personal Recovery Keys",
            "headers": [
                "Computer Name", "Serial Number", "Assigned User", "Email",
                "FileVault State", "Personal Recovery Key", "Last Inventory",
            ],
            "rows": fv_rows,
        }

    # ── Software Updates: shared data fetch ─────────────────────────────────
    # MSU plans and update-status-failures are tenant-wide and cover both
    # platforms, so we fetch once and let the macOS + iOS sheet builders
    # consume the same indexes. Gate on either sheet being selected so we
    # don't pay for the call when both are deselected.
    _need_msu_ios   = "iOS - Software Updates" in selected_sheets
    _need_msu_any   = _need_msu_macos or _need_msu_ios

    _msu_plans_by_device: dict[str, list[dict[str, Any]]] = {}
    _failures_by_id:     dict[str, list[dict[str, Any]]] = {}
    _failures_by_serial: dict[str, list[dict[str, Any]]] = {}
    _now_ts = datetime.now(_tz.utc).timestamp()

    def _norm_id(v: Any) -> str:
        return str(v).strip() if v not in (None, "") else ""

    if _need_msu_any:
        _section_start("Fetching MSU plans (macOS+iOS)")
        _all_msu_plans = list_msu_plans(args.profile)
        _section_done("MSU plans found", len(_all_msu_plans))

        _section_start("Fetching update-status failures (--scan-failures)")
        _update_failures = report_update_status_failures(args.profile)
        _section_done("Update-status failure rows", len(_update_failures))

        # MSU plans: group by deviceId; each device may have multiple plans.
        for _pl in _all_msu_plans:
            if not isinstance(_pl, dict):
                continue
            _dev = (_pl.get("device") or {}) if isinstance(_pl.get("device"), dict) else {}
            _did = _norm_id(
                _dev.get("deviceId")
                or _pl.get("deviceId")
                or _pl.get("computerId")
                or _pl.get("mobileDeviceId")
            )
            if _did:
                _msu_plans_by_device.setdefault(_did, []).append(_pl)

        # Failures: index by both deviceId and serial — different jamf-cli
        # versions surface different identifiers on this report.
        for _f in _update_failures:
            if not isinstance(_f, dict):
                continue
            _did = _norm_id(_f.get("deviceId") or _f.get("computerId") or _f.get("id"))
            _ser = _norm_id(_f.get("serialNumber") or _f.get("serial"))
            if _did:
                _failures_by_id.setdefault(_did, []).append(_f)
            if _ser:
                _failures_by_serial.setdefault(_ser.lower(), []).append(_f)

    # ── macOS - Software Updates ────────────────────────────────────────────
    # Per-device snapshot of update health. Inclusion is curated, not "every
    # Mac" — a Mac only earns a row when something is worth saying about it:
    #
    #   * has an active MSU plan (regardless of state),
    #   * shows up on `pro report update-status --scan-failures`,
    #   * has an expired MDM profile (which silently kills updates),
    #   * has at least one invalid DDM declaration on its Blueprint.
    #
    # Devices that are silent + current + healthy are deliberately omitted.
    # See the user clarification on 2026-06-25.
    # Shared helpers used by both macOS and iOS MSU builders.
    def _msu_short_date(s: Any) -> str:
        if not s:
            return "-"
        s = str(s).strip()
        return s.split("T", 1)[0] if "T" in s else s

    if _need_msu_any:
        def _msu_collect_issues(
            mdm_expired: bool,
            plans: list[dict[str, Any]],
            failures: list[dict[str, Any]],
            blueprint_invalid: bool,
            recent_failed_commands: list[dict[str, Any]],
        ) -> tuple[str, str, str]:
            """Build (update_status, issues_joined, remediation_joined).

            issues_joined / remediation_joined are newline-separated so the
            cell shows one issue per line in Excel.
            """
            issues: list[str] = []
            fixes:  list[str] = []
            update_state = ""

            # Expired MDM profile — surface this first, it dwarfs everything
            # else (no MDM = no updates).
            if mdm_expired:
                issues.append("MDM enrollment profile expired")
                fixes.append(lookup_msu_remediation("mdm expired") or "Re-enrol the device.")

            # Plan-level signals. A plan's state is usually a plain string
            # ("PENDING", "COMPLETED"), but some jamf-cli versions nest a status
            # object under `state`/`status`, e.g.
            #   {"state": "PlanFailed",
            #    "errorReasons": ["SPECIFIC_VERSION_UNAVAILABLE_FOR_DEVICE_MODEL"]}
            # Unwrap that and render it as a single human-readable line
            #   "PlanFailed: SPECIFIC_VERSION_UNAVAILABLE_FOR_DEVICE_MODEL"
            # rather than dumping the raw dict into the Update Status cell.
            _active_states: list[str] = []
            for pl in plans:
                _raw_state = pl.get("state") or pl.get("status") or ""
                _nested_errs: list = []
                if isinstance(_raw_state, dict):
                    _nested_errs = (_raw_state.get("errorReasons")
                                    or _raw_state.get("errors") or [])
                    _pure_state = str(_raw_state.get("state")
                                      or _raw_state.get("status") or "").strip()
                else:
                    _pure_state = str(_raw_state).strip()

                _errs = (pl.get("errorReasons") or pl.get("errors")
                         or _nested_errs or [])
                if isinstance(_errs, str):
                    _errs = [_errs]
                _errs = [str(e).strip() for e in _errs if str(e).strip()]

                if _pure_state:
                    # One clean line: "State: reason1, reason2" (no braces/quotes).
                    _active_states.append(
                        f"{_pure_state}: {', '.join(_errs)}" if _errs else _pure_state
                    )

                for err_s in _errs:
                    issues.append(f"Plan error: {err_s}")
                    fixes.append(
                        lookup_msu_remediation(err_s)
                        or _ollama_query(
                            "Write one short sentence of remediation advice "
                            "for this Jamf Pro Managed Software Update error: "
                            f"\"{err_s}\". Be specific and actionable."
                        )
                        or "Inspect the plan in Jamf Pro for further detail."
                    )
            if _active_states:
                # Pick the most informative state — "Failed" beats "Pending".
                # Match on the leading state token (before any ": reasons") and
                # ignore case/underscores so "PlanFailed" == "PLAN_FAILED".
                _state_priority = {
                    "FAILED": 5, "PLAN_FAILED": 5, "ERROR": 5, "ERRORED": 5,
                    "FORCE_INSTALL": 4, "INSTALLING": 3, "DOWNLOADING": 3,
                    "PENDING": 2, "PLAN_CREATED": 2,
                    "SCHEDULED": 2, "COMPLETED": 1, "DONE": 1,
                }
                _norm_priority = {
                    k.replace("_", ""): v for k, v in _state_priority.items()
                }

                def _state_rank(s: str) -> int:
                    head = (s.split(":", 1)[0].strip().upper()
                            .replace(" ", "").replace("_", ""))
                    return _norm_priority.get(head, 0)

                update_state = max(_active_states, key=_state_rank)

            # report update-status failure rows — usually richer error text.
            for f in failures:
                _err = str(
                    f.get("error") or f.get("errorMessage")
                    or f.get("failureReason") or f.get("reason") or ""
                ).strip()
                if _err:
                    issues.append(f"Update status: {_err}")
                    fixes.append(
                        lookup_msu_remediation(_err)
                        or _ollama_query(
                            "Write one short sentence of remediation advice "
                            "for this Jamf Pro software update issue: "
                            f"\"{_err}\". Be specific and actionable."
                        )
                        or "Check the device's MDM command history for context."
                    )
                else:
                    _flg = str(f.get("status") or f.get("state") or "").strip()
                    if _flg and _flg.upper() not in ("OK", "SUCCESS", "INSTALLED"):
                        issues.append(f"Update status: {_flg}")
                        fixes.append("Inspect the device in Jamf Pro for full detail.")

            # DDM/blueprint signal — invalid declarations are an active fail.
            if blueprint_invalid:
                issues.append("Blueprint has one or more invalid declarations")
                fixes.append(lookup_msu_remediation("declaration invalid")
                             or "Re-deploy the blueprint.")

            # Event-store enrichment: include the most recent FAILED MDM
            # command's reason if it adds something not already covered.
            for cmd in recent_failed_commands[:1]:
                _cn = str(cmd.get("commandType") or cmd.get("command") or "").strip()
                _ce = str(cmd.get("errorChain") or cmd.get("error") or cmd.get("result") or "").strip()
                if _cn or _ce:
                    issues.append(
                        f"Recent failed MDM command: {_cn or '(unknown)'}"
                        + (f" — {_ce}" if _ce else "")
                    )
                    fixes.append(
                        lookup_msu_remediation(_ce or _cn)
                        or "Flush failed commands and re-issue: `pro computers flush-commands --id <id> --status FAILED`."
                    )

            return (
                update_state or "-",
                "\n".join(issues) if issues else "-",
                "\n".join(fixes) if fixes else "-",
            )

    if _need_msu_macos and _have_macos_fleet:
        _section_start("Building macOS Software Updates rows")
        msu_macos_rows: list[list[Any]] = []
        msu_macos_hyperlinks: dict[tuple[int, int], str] = {}
        for _c in computers:
            _gen   = _c.get("general") or {}
            _hw    = _c.get("hardware") or {}
            _osblk = _c.get("operatingSystem") or {}

            _name    = str(_gen.get("name") or "").strip()
            _serial  = str(_hw.get("serialNumber") or _gen.get("serialNumber") or "").strip()
            _model   = str(_hw.get("model") or "").strip()
            _osver   = str(_osblk.get("version") or "").strip()
            _mgmt_id = str(_gen.get("managementId") or "").strip()
            _last_seen = _msu_short_date(_gen.get("lastContactTime"))

            # Machine Role from EA — same EA name as the Health Check sheet.
            def _ea_v(comp: dict[str, Any], ea_name: str) -> str:
                name_l = ea_name.strip().lower()
                for section in ("general", "hardware", "userAndLocation"):
                    obj = comp.get(section) or {}
                    for ea in (obj.get("extensionAttributes") or []):
                        if str(ea.get("name") or "").strip().lower() == name_l:
                            vals = [v for v in (ea.get("values") or []) if v not in (None, "", [])]
                            if vals:
                                return str(vals[0])
                return ""
            _role = _ea_v(_c, "Machine Role")

            # Pre-filter signals (cheap — no extra API calls).
            _mdm_exp_ts = _parse_dt(_gen.get("mdmProfileExpiration"))
            _mdm_expired = (_mdm_exp_ts is not None and _mdm_exp_ts < _now_ts)
            _device_id   = str(_gen.get("id") or _c.get("id") or "").strip()
            _plans       = _msu_plans_by_device.get(_device_id, [])
            _failures    = (_failures_by_id.get(_device_id, [])
                            or _failures_by_serial.get(_serial.lower(), []))
            _has_signal  = (_mdm_expired or bool(_plans) or bool(_failures))

            if not _has_signal:
                continue   # silent + current + healthy → skip

            # On-demand: blueprint status + recent failed MDM commands.
            _bp_items = get_ddm_status_items(_mgmt_id, args.profile) if _mgmt_id else []
            _bp_summary, _bp_invalid = summarise_blueprint_status(_bp_items)
            _recent_failed_cmds = (
                list_mdm_command_failures_for_device(_mgmt_id, args.profile, limit=3)
                if _mgmt_id else []
            )

            _update_state, _issues_text, _remed_text = _msu_collect_issues(
                _mdm_expired, _plans, _failures, _bp_invalid, _recent_failed_cmds,
            )

            msu_macos_rows.append([
                _name or "-",
                _serial or "-",
                _model or "-",
                _role or "-",
                _osver or "-",
                _last_seen,
                _bp_summary,
                _update_state,
                _issues_text,
                _remed_text,
            ])
            # Hyperlink on the Name column.
            try:
                _did_int = int(_device_id) if _device_id else None
            except (TypeError, ValueError):
                _did_int = None
            _u = _url_computer(_did_int) if _did_int else ""
            if _u:
                msu_macos_hyperlinks[(len(msu_macos_rows) - 1, 0)] = _u

        msu_macos_rows.sort(key=lambda r: str(r[0]).lower())
        _section_done("macOS Software Updates rows", len(msu_macos_rows))

        if msu_macos_rows:
            all_sheets["macOS - Software Updates"] = {
                "title": f"macOS  |  Software Updates",
                "headers": [
                    "Name", "Serial Number", "Model", "Machine Role",
                    "macOS Version", "Last Check-In",
                    "Blueprint Status", "Update Status",
                    "Issues", "Remediation",
                ],
                "rows": msu_macos_rows,
                "hyperlinks": msu_macos_hyperlinks,
            }

    # macOS - LAPS Accounts sheet removed — see LAPS Accounts block above.

    if hybrid_groups:
        all_sheets["Jamf Pro Accounts"] = {
            "title": (f"Jamf Pro Accounts  |  Hybrid LDAP / Cloud-IdP "
                      f"group membership (local accounts excluded by design)"),
            "headers": hybrid_headers,
            "rows": hybrid_rows,
            "matrix_style": True,
        }

    # ── Jamf Protect sheet ────────────────────────────────────────────────────
    # Instance-level (not macOS/iOS). Only built when the tenant actually has the
    # Jamf Protect integration set up (or synced Plans); otherwise omitted so it
    # never appears as an empty sheet. Fetch is gated on selection.
    if "Jamf Protect" in selected_sheets:
        _section_start("Fetching Jamf Protect settings")
        try:
            _jp_status = fetch_jamf_protect_status(args.profile)
            _jp_plans = fetch_jamf_protect_plans(args.profile)
        except Exception as _jperr:
            print(f"WARNING: Jamf Protect fetch failed: {_jperr}", file=sys.stderr)
            _jp_status, _jp_plans = {}, []
        _jp_spec = build_jamf_protect_sheet(_jp_status, _jp_plans)
        if _jp_spec is not None:
            all_sheets["Jamf Protect"] = _jp_spec
            _section_done("Jamf Protect plans", len(_jp_plans))
        else:
            print("  - Jamf Protect: not configured - sheet omitted",
                  file=sys.stderr, flush=True)

    # ── Orphans sheet ─────────────────────────────────────────────────────────
    # Lists items that exist in the tenant but aren't actively doing anything:
    # policies/profiles/apps/restricted-software with no scope, EAs that are
    # disabled, scripts not attached to any policy, and groups not referenced
    # anywhere as scope/limitation/exclusion. Each row links back to the item
    # in Jamf Pro and carries a checklist cell so a tech can tick them off as
    # they audit / clean up.
    #
    # Detection rules (per user clarification 2026-06-17):
    #   * Restricted Software → hashtag in name OR not scoped (broader net)
    #   * Smart/Static Groups → not referenced anywhere as scope/excl/lim
    #   * No on-device AI on this sheet
    _section_start("Fetching computer groups")
    if not _have_macos_fleet:
        all_computer_groups = []
    else:
        try:
            all_computer_groups = list_computer_groups(args.profile)
        except Exception as _gerr:
            print(f"WARNING: computer-groups list failed: {_gerr}", file=sys.stderr)
            all_computer_groups = []
    _section_done("Computer groups found", len(all_computer_groups))

    # Packages — every .pkg/.dmg/etc. registered in Jamf Pro. We cross-
    # reference against the per-policy `used_packages` set collected during
    # the policy loop above to find packages with zero policy references.
    _section_start("Fetching packages")
    if not _have_macos_fleet:
        all_packages = []
    else:
        try:
            all_packages = list_packages(args.profile)
        except Exception as _perr:
            print(f"WARNING: packages list failed: {_perr}", file=sys.stderr)
            all_packages = []
    _section_done("Packages found", len(all_packages))

    # ── iOS data fetch (gated by sheet selection) ────────────────────────────
    # Only hit the iOS endpoints if at least one iOS sheet is in the user's
    # selection. This keeps Mac-only runs from incurring the extra API cost
    # on tenants that have no mobile management.
    _ios_sheet_names = {
        "iOS - Apps - Scope",
        "iOS - Config Profiles - Scope",
        "iOS - Config Profiles",
        "iOS - Devices",
        "iOS - Health Check",
        "iOS - Orphaned Items",
        "iOS - Software Updates",
    }
    _need_ios_by_selection = bool(selected_sheets & _ios_sheet_names) if fmt in (FMT_XLSX, FMT_CSV) else (
        # Terminal mode: only fetch iOS if the chosen dataset is iOS-related.
        isinstance(terminal_dataset, str) and terminal_dataset.startswith("ios-")
    )
    # Combine sheet-selection gate with fleet-existence gate. If there are
    # no managed iOS devices, skip all iOS API calls even if iOS sheets
    # were picked — those sheets will just render empty.
    _need_ios = _need_ios_by_selection and _have_ios_fleet
    if _need_ios_by_selection and not _have_ios_fleet:
        print("Note: iOS sheets requested but zero managed iOS devices — "
              "skipping iOS data fetches.", file=sys.stderr)

    ios_devices: list[dict[str, Any]] = []
    ios_apps_full: list[dict[str, Any]] = []     # raw get-app-json per app
    ios_profiles_full: list[dict[str, Any]] = []  # raw get-profile-json per profile
    ios_groups: list[dict[str, Any]] = []
    ios_used_groups: set[str] = set()
    # Meta lists for orphan detection (similar shape to macOS policy_meta).
    ios_app_meta: list[dict[str, Any]] = []
    ios_profile_meta: list[dict[str, Any]] = []

    if _need_ios:
        _section_start("Fetching iOS mobile devices")
        try:
            ios_devices = list_mobile_devices(args.profile)
        except Exception as _err:
            print(f"WARNING: mobile-devices list failed: {_err}", file=sys.stderr)
        _section_done("iOS devices found", len(ios_devices))

        _section_start("Fetching iOS device groups")
        try:
            ios_groups = list_mobile_device_groups(args.profile)
        except Exception as _err:
            print(f"WARNING: mobile-device-groups list failed: {_err}", file=sys.stderr)
        _section_done("iOS groups found", len(ios_groups))

        _section_start("Fetching iOS apps")
        try:
            _ios_app_list = list_mobile_apps(args.profile)
        except Exception as _err:
            print(f"WARNING: mobile-apps list failed: {_err}", file=sys.stderr)
            _ios_app_list = []
        _section_done("iOS apps found", len(_ios_app_list))

        if _ios_app_list:
            _section_start("Fetching iOS app details")
        for _ai, app in enumerate(_ios_app_list, 1):
            aid = app.get("id")
            try:
                aid_int = int(aid) if aid is not None else None
            except (TypeError, ValueError):
                aid_int = None
            if aid_int is None:
                continue
            _progress(_ai, len(_ios_app_list), str(app.get("name") or ""))
            full = get_mobile_app_json(aid_int, args.profile)
            if not isinstance(full, dict):
                continue
            ios_apps_full.append(full)

            general = full.get("general", {}) if isinstance(full, dict) else {}
            scope_block = full.get("scope", {}) if isinstance(full, dict) else {}
            tgt, lim, exc = extract_mobile_scope(scope_block)
            _all_devs = scope_targets_all(scope_block)
            # Normalise Jamf's raw deployment_type strings to shorter forms
            # that match how techs talk about them:
            #   "Install Automatically/Prompt Users to Install" → "Install Automatically"
            #   "Make Available in Self Service"                → "Self Service"
            _dep = str(general.get("deployment_type") or "")
            if _dep.startswith("Install Automatically"):
                _dep = "Install Automatically"
            elif _dep == "Make Available in Self Service":
                _dep = "Self Service"
            ios_app_meta.append({
                "id":               aid_int,
                "name":             str(general.get("name") or app.get("name") or ""),
                "bundle_id":        str(general.get("bundle_id") or ""),
                "version":          str(general.get("version") or ""),
                "deployment_type":  _dep,
                "free":             bool(general.get("free")),
                "internal_app":     bool(general.get("internal_app")),
                "target_groups":    tgt,
                "limitation_groups": lim,
                "excluded_groups":  exc,
                "all_devices":      _all_devs,
            })
            ios_used_groups.update(tgt)
            ios_used_groups.update(exc)

        _section_start("Fetching iOS config profiles")
        try:
            _ios_prof_list = list_mobile_config_profiles(args.profile)
        except Exception as _err:
            print(f"WARNING: mobile-config-profiles list failed: {_err}", file=sys.stderr)
            _ios_prof_list = []
        _section_done("iOS profiles found", len(_ios_prof_list))

        if _ios_prof_list:
            _section_start("Fetching iOS profile details")
        for _pi, prof in enumerate(_ios_prof_list, 1):
            ppid = prof.get("id")
            try:
                ppid_int = int(ppid) if ppid is not None else None
            except (TypeError, ValueError):
                ppid_int = None
            if ppid_int is None:
                continue
            _progress(_pi, len(_ios_prof_list), str(prof.get("name") or ""))
            full = get_mobile_config_profile_json(ppid_int, args.profile)
            if not isinstance(full, dict):
                continue
            ios_profiles_full.append(full)

            general = full.get("general", {}) if isinstance(full, dict) else {}
            scope_block = full.get("scope", {}) if isinstance(full, dict) else {}
            tgt, lim, exc = extract_mobile_scope(scope_block)
            _all_devs = scope_targets_all(scope_block)
            ios_profile_meta.append({
                "id":              ppid_int,
                "name":            str(general.get("name") or prof.get("name") or ""),
                "description":     str(general.get("description") or ""),
                "category":        category_from_json(full),
                "deployment":      str(general.get("deployment_method") or ""),
                "level":           str(general.get("level") or ""),
                "uuid":            str(general.get("uuid") or ""),
                "payloads_xml":    str(general.get("payloads") or ""),
                "target_groups":   tgt,
                "limitation_groups": lim,
                "excluded_groups": exc,
                "all_devices":     _all_devs,
            })
            ios_used_groups.update(tgt)
            ios_used_groups.update(exc)

    # URL builders (_url_policy, _url_profile, ...) are defined earlier in
    # main() alongside _raw_url so they can be shared with other sheet
    # specs that also build Name-column hyperlinks.

    # Collect orphan rows by section. Each row: [Name, Jamf Pro ID, Reason]
    # The Name column is clickable (hyperlink → Jamf Pro item page).
    # The Jamf Pro ID column carries the numeric ID for cross-reference.
    # The URL itself is not displayed; it lives in the orphan_hyperlinks map
    # used by build_workbook's generic hyperlink pass.
    orphan_rows: list[list] = []
    orphan_hyperlinks: dict[tuple[int, int], str] = {}  # (data-row, col) → url

    def _add_section(title: str, count: int) -> None:
        orphan_rows.append([f"+ {title} ({count}) +", "", ""])

    def _add_orphan(name: str, item_id: int | str, url: str, reason: str) -> None:
        orphan_rows.append([name, str(item_id) if item_id is not None else "-", reason])
        if url:
            # Hyperlink attaches to the Name cell (col index 0). Build_workbook's
            # generic hyperlink pass picks this up via the "hyperlinks" spec key.
            orphan_hyperlinks[(len(orphan_rows) - 1, 0)] = url

    # 1. Policies — no scope (no targets AND not all_computers).
    _orphan_policies = [
        p for p in policy_meta
        if not p["target_groups"] and not p["all_computers"]
    ]
    _orphan_policies.sort(key=lambda p: p["name"].lower())
    _add_section("Policies — no scope", len(_orphan_policies))
    for p in _orphan_policies:
        _reason = "No scope" + ("" if p["enabled"] else " · disabled")
        _add_orphan(p["name"], p["id"], _url_policy(p["id"]), _reason)
    orphan_rows.append(["", "", ""])

    # 2. Config Profiles — no scope.
    _orphan_profiles = [
        p for p in profile_meta
        if not p["target_groups"] and not p["all_computers"]
    ]
    _orphan_profiles.sort(key=lambda p: p["name"].lower())
    _add_section("Configuration Profiles — no scope", len(_orphan_profiles))
    for p in _orphan_profiles:
        _add_orphan(p["name"], p["id"], _url_profile(p["id"]), "No scope")
    orphan_rows.append(["", "", ""])

    # 3. Mac Apps — no scope.
    _orphan_macapps = [
        a for a in macapp_meta
        if not a["target_groups"] and not a["all_computers"]
    ]
    _orphan_macapps.sort(key=lambda a: a["name"].lower())
    _add_section("Mac Apps — no scope", len(_orphan_macapps))
    for a in _orphan_macapps:
        _label = f"{a['name']}" + (f"  ({a['bundle_id']})" if a.get("bundle_id") else "")
        _add_orphan(_label, a["id"], _url_mac_app(a["id"]), "No scope")
    orphan_rows.append(["", "", ""])

    # 4. Restricted Software — hashtag in name OR not scoped (per user spec).
    _orphan_rs: list[tuple[dict, str]] = []
    for r in rs_meta:
        # All Computers is a valid scope — restricted-software items using
        # it are never orphans, hashtag in name or not.
        if r["all_computers"]:
            continue
        _has_hash = "#" in (r.get("name") or "")
        _no_scope = not r["target_groups"]
        if _has_hash or _no_scope:
            if _has_hash and _no_scope:
                _why = "Has '#' in name · no scope"
            elif _has_hash:
                _why = "Has '#' in name"
            else:
                _why = "No scope"
            _orphan_rs.append((r, _why))
    _orphan_rs.sort(key=lambda t: (t[0]["name"] or "").lower())
    _add_section("Restricted Software — hashtag or no scope", len(_orphan_rs))
    for r, _why in _orphan_rs:
        _add_orphan(r["name"], r["id"], _url_restricted(r["id"]), _why)
    orphan_rows.append(["", "", ""])

    # 5. Scripts — not attached to any policy.
    _orphan_scripts = [
        s for s in script_list
        if isinstance(s.get("id"), int) and s["id"] not in used_scripts
    ]
    _orphan_scripts.sort(key=lambda s: str(s.get("name") or "").lower())
    _add_section("Scripts — not attached to any policy", len(_orphan_scripts))
    for s in _orphan_scripts:
        _add_orphan(str(s["name"]), int(s["id"]), _url_script(int(s["id"])), "Not attached to any policy")
    orphan_rows.append(["", "", ""])

    # 6. Packages — not linked to any policy.
    # used_packages was populated from every policy seen (regardless of
    # enabled state / name filter). Match by id, with a fallback name
    # match for older policies that only carry package names.
    _orphan_packages = [
        p for p in all_packages
        if (p["id"] not in used_packages)
        and (p["name"] not in used_package_names)
    ]
    _orphan_packages.sort(key=lambda p: p["name"].lower())
    _add_section("Packages — not linked to any policy", len(_orphan_packages))
    for p in _orphan_packages:
        _label = p["name"] or p["filename"] or f"Package {p['id']}"
        _add_orphan(_label, p["id"], _url_package(p["id"]),
                    "Not referenced by any policy")
    orphan_rows.append(["", "", ""])

    # 8. Extension Attributes — disabled.
    _orphan_eas = [ea for ea in ea_list if not ea.get("enabled", True)]
    _orphan_eas.sort(key=lambda ea: str(ea.get("name") or "").lower())
    _add_section("Extension Attributes — disabled", len(_orphan_eas))
    for ea in _orphan_eas:
        _add_orphan(str(ea.get("name") or ""), int(ea["id"]), _url_ea(int(ea["id"])), "Disabled")
    orphan_rows.append(["", "", ""])

    # 9. Smart Groups — not referenced anywhere as scope/limitation/exclusion.
    _smart_orphans = [
        g for g in all_computer_groups
        if g["is_smart"] and g["name"] not in used_groups
    ]
    _smart_orphans.sort(key=lambda g: g["name"].lower())
    _add_section("Smart Groups — not referenced anywhere", len(_smart_orphans))
    for g in _smart_orphans:
        _add_orphan(g["name"], g["id"], _url_smart_group(g["id"]),
                    "Not referenced as scope/limitation/exclusion")
    orphan_rows.append(["", "", ""])

    # 10. Static Groups — not referenced anywhere.
    _static_orphans = [
        g for g in all_computer_groups
        if (not g["is_smart"]) and g["name"] not in used_groups
    ]
    _static_orphans.sort(key=lambda g: g["name"].lower())
    _add_section("Static Groups — not referenced anywhere", len(_static_orphans))
    for g in _static_orphans:
        _add_orphan(g["name"], g["id"], _url_static_group(g["id"]),
                    "Not referenced as scope/limitation/exclusion")

    _orphan_total = (
        len(_orphan_policies) + len(_orphan_profiles) + len(_orphan_macapps)
        + len(_orphan_rs) + len(_orphan_scripts) + len(_orphan_packages)
        + len(_orphan_eas) + len(_smart_orphans) + len(_static_orphans)
    )

    all_sheets["macOS - Orphaned Items"] = {
        "title": f"macOS  |  Orphaned Items  ({_orphan_total} total)",
        "headers": ["Name", "Jamf Pro ID", "Reason"],
        "rows": orphan_rows,
        # summary_style renders the "+ Section +" rows as bold section
        # headers and leaves the data rows clean.
        "summary_style": True,
        # Generic hyperlink mechanism (build_workbook applies these).
        "hyperlinks": orphan_hyperlinks,
        # Skip the blank-row/col trim so the (data-row → Excel-row) index
        # mapping stays stable for the hyperlink pass.
        "skip_trim": True,
    }

    # ── iOS sheets ───────────────────────────────────────────────────────────
    # Only built when _need_ios is true (i.e. user selected at least one iOS
    # sheet). When `selected_sheets` filters later, untouched specs are
    # dropped automatically so we never write empty iOS sheets to the file.
    if _need_ios:
        # ── iOS - Apps - Scope ───────────────────────────────────────────────
        # Note: dropped the per-app "Type" column. The `internal_app` field
        # in classic-mobile-apps doesn't reliably indicate "in-house vs App
        # Store" — observed App Store apps with internal_app=true. Use the
        # deployment_type field instead, which mirrors the Jamf Pro UI.
        ios_apps_scope_rows: list[list] = []
        ios_apps_scope_hyperlinks: dict[tuple[int, int], str] = {}
        for _i, app in enumerate(sorted(ios_app_meta, key=lambda a: a["name"].lower())):
            _targets = (";\n".join(app["target_groups"]) if app["target_groups"]
                        else ("All Mobile Devices" if app["all_devices"] else "-"))
            ios_apps_scope_rows.append([
                app["name"],
                app["bundle_id"] or "-",
                app["version"] or "-",
                app["deployment_type"] or "-",
                _targets,
                ";\n".join(app["limitation_groups"]) if app["limitation_groups"] else "-",
                ";\n".join(app["excluded_groups"]) if app["excluded_groups"] else "-",
            ])
            _u = _url_ios_app(app["id"])
            if _u:
                ios_apps_scope_hyperlinks[(_i, 0)] = _u

        all_sheets["iOS - Apps - Scope"] = {
            "title": "iOS  |  Apps - Scope",
            "headers": [
                "App Name", "Bundle ID", "Version", "Deployment Style",
                "Targets", "Limitations", "Exclusions",
            ],
            "rows": ios_apps_scope_rows,
            "hyperlinks": ios_apps_scope_hyperlinks,
        }

        # ── iOS - Config Profiles - Scope ────────────────────────────────────
        ios_prof_scope_rows: list[list] = []
        ios_prof_scope_hyperlinks: dict[tuple[int, int], str] = {}
        for _i, prof in enumerate(sorted(ios_profile_meta, key=lambda p: p["name"].lower())):
            _targets = (";\n".join(prof["target_groups"]) if prof["target_groups"]
                        else ("All Mobile Devices" if prof["all_devices"] else "-"))
            ios_prof_scope_rows.append([
                prof["name"],
                prof.get("category") or "-",
                prof["level"] or "-",
                prof["deployment"] or "-",
                _targets,
                ";\n".join(prof["limitation_groups"]) if prof["limitation_groups"] else "-",
                ";\n".join(prof["excluded_groups"]) if prof["excluded_groups"] else "-",
            ])
            _u = _url_ios_profile(prof["id"])
            if _u:
                ios_prof_scope_hyperlinks[(_i, 0)] = _u

        all_sheets["iOS - Config Profiles - Scope"] = {
            "title": "iOS  |  Config Profiles - Scope",
            "headers": [
                "Profile Name", "Category", "Level", "Deployment Method",
                "Targets", "Limitations", "Exclusions",
            ],
            "rows": ios_prof_scope_rows,
            "hyperlinks": ios_prof_scope_hyperlinks,
        }

        # ── iOS - Config Profiles (settings, flattened from payload XML) ────
        # iOS profile payloads have the same plist-in-XML envelope as macOS
        # profiles, so we reuse the same helpers (get_payload_xml_string,
        # parse_payload_plist, flatten_value, short_key_from_path).
        ios_settings_rows: list[list] = []
        ios_settings_hyperlinks: dict[tuple[int, int], str] = {}
        for prof in sorted(ios_profile_meta, key=lambda p: p["name"].lower()):
            # Skip profiles with no target scope. They still appear in the
            # "iOS - Config Profiles - Scope" sheet, but are omitted here.
            if not prof["target_groups"] and not prof["all_devices"]:
                continue
            pname = prof["name"]
            ppid  = prof["id"]
            _u = _url_ios_profile(ppid)
            _scope_str = (";\n".join(prof["target_groups"]) if prof["target_groups"]
                          else ("All Mobile Devices" if prof["all_devices"] else "-"))
            _excl_str = ";\n".join(prof["excluded_groups"]) if prof["excluded_groups"] else "-"

            # iOS profile payloads are stored as the plist XML directly in
            # general.payloads (no <payloads> wrapper element like macOS).
            # JSON-decoding has already unescaped < → <, so the string
            # is ready to feed into plistlib. Falling back to the macOS
            # wrapper-stripping path if the direct parse fails handles
            # tenants that happen to return the wrapper form.
            _ios_payload_str = prof["payloads_xml"] or ""
            payload_plist = parse_payload_plist(_ios_payload_str)
            if payload_plist is None and _ios_payload_str:
                payload_plist = parse_payload_plist(
                    get_payload_xml_string(_ios_payload_str)
                )

            if not isinstance(payload_plist, dict):
                ios_settings_rows.append([
                    pname, "", "", "payload_parse_status",
                    "unable_to_parse_payload", _scope_str, _excl_str,
                ])
                if _u:
                    ios_settings_hyperlinks[(len(ios_settings_rows) - 1, 0)] = _u
                continue

            payload_content = payload_plist.get("PayloadContent", [])
            if not isinstance(payload_content, list):
                payload_content = []

            if not payload_content:
                ios_settings_rows.append([
                    pname, "", "", "payload_parse_status",
                    "no_payload_content", _scope_str, _excl_str,
                ])
                if _u:
                    ios_settings_hyperlinks[(len(ios_settings_rows) - 1, 0)] = _u
                continue

            for idx, payload in enumerate(payload_content):
                if not isinstance(payload, dict):
                    ios_settings_rows.append([
                        pname, "", "", f"PayloadContent_{idx}",
                        str(payload), _scope_str, _excl_str,
                    ])
                    if _u:
                        ios_settings_hyperlinks[(len(ios_settings_rows) - 1, 0)] = _u
                    continue
                ptype = str(payload.get("PayloadType") or "")
                pdisp = str(
                    payload.get("PayloadDisplayName")
                    or payload.get("PayloadIdentifier")
                    or ptype or ""
                )
                flattened: list[tuple[str, str]] = []
                flatten_value(payload, "", flattened)
                for key_path, value in flattened:
                    setting_key = short_key_from_path(key_path)
                    if setting_key.startswith("Payload"):
                        continue
                    ios_settings_rows.append([
                        pname, ptype, pdisp, setting_key, value,
                        _scope_str, _excl_str,
                    ])
                    if _u:
                        ios_settings_hyperlinks[(len(ios_settings_rows) - 1, 0)] = _u

        all_sheets["iOS - Config Profiles"] = {
            "title": "iOS  |  Config Profiles",
            "headers": [
                "Profile Name", "Payload Type",
                "Payload Display Name", "Setting Key", "Value",
                "Targets", "Exclusions",
            ],
            "rows": ios_settings_rows,
            "hyperlinks": ios_settings_hyperlinks,
        }

        # ── iOS - Health Check ───────────────────────────────────────────────
        # Per-device row with one or more flagged signals. Devices with no
        # flags are omitted (matches the macOS Health Check pattern).
        #
        # Signals derived from `general` + `hardware` (both populated in the
        # list response — no per-device fetch needed). Security-section
        # signals (jailbreak, lost mode, activation lock) live in
        # `security: null` on the list response and require a separate
        # --section SECURITY fetch; left as a follow-up.
        #
        # Thresholds (tune in code):
        #   STALE_DAYS              = 30   — stale inventory
        #   IOS_MIN_MAJOR           = 18   — iOS 17.x and older = unsupported
        #   STORAGE_MIN_MB_UPDATE   = 6000 — iOS major updates need ~6 GB free
        #   STORAGE_MIN_PCT         = 10   — overall low-storage warning
        #   MDM_EXPIRY_WARN_DAYS    = 90   — MDM cert about to expire
        from datetime import datetime as _dt, timedelta as _td, timezone as _tz
        STALE_DAYS            = 30
        IOS_MIN_MAJOR         = 18
        STORAGE_MIN_MB_UPDATE = 6000
        STORAGE_MIN_PCT       = 10
        MDM_EXPIRY_WARN_DAYS  = 90
        _now_utc = _dt.now(_tz.utc)
        ios_health_rows: list[list] = []
        ios_health_hyperlinks: dict[tuple[int, int], str] = {}
        # Serial numbers that ended up on the iOS Health Check sheet — used by
        # the iOS - Devices fleet sheet's "Health Check Pending" cross-reference
        # column. Mirrors the macOS pattern (_health_serials → Managed Macs).
        _ios_health_serials: set[str] = set()

        def _parse_iso(s: str) -> "_dt | None":
            if not s or not isinstance(s, str):
                return None
            try:
                # Tolerate both "...Z" and "...+00:00" forms.
                if s.endswith("Z"):
                    s = s[:-1] + "+00:00"
                return _dt.fromisoformat(s)
            except (ValueError, TypeError):
                return None

        for dev in ios_devices:
            if not isinstance(dev, dict):
                continue
            general = dev.get("general") or {}
            hardware = dev.get("hardware") or {}
            issues: list[str] = []
            actions: list[str] = []

            # Stale check-in
            last_inv = _parse_iso(general.get("lastInventoryUpdateDate") or "")
            if last_inv:
                age_days = (_now_utc - last_inv).days
                if age_days > STALE_DAYS:
                    issues.append(f"Stale check-in ({age_days}d)")
                    actions.append(
                        "Force inventory update or contact user — device may be "
                        "offline or unmanaged in practice."
                    )
            else:
                issues.append("No inventory date recorded")
                actions.append("Verify device is still enrolled; force update-inventory.")

            # Unmanaged
            if general.get("managed") is False:
                issues.append("Unmanaged (MDM channel inactive)")
                actions.append("Re-enrol via Apple Configurator or DEP/ADE.")

            # Unsupervised (only meaningful for institutional ownership)
            ownership = str(general.get("deviceOwnershipType") or "").lower()
            if (general.get("supervised") is False
                    and ownership in ("institutional", "company-owned", "corporate")):
                issues.append("Unsupervised institutional device")
                actions.append(
                    "Re-enrol through ADE so the device becomes supervised — "
                    "many MDM commands (lost mode, app removal, restrictions) "
                    "require supervision."
                )

            # iOS version — tiered support policy (no CLI-send-updates advice;
            # we only plan, never push OS updates from this report).
            # Tiers (as of Jun 2026, shifts when iOS 27 ships):
            #   Recommended:     iOS 26.x, iOS 18.x        → no flag
            #   Minimum support: iOS 17.x                  → plan upgrade
            #   Unsupported:     iOS 16.x and earlier      → schedule upgrade
            dev_type = str(dev.get("deviceType") or "").lower()
            if dev_type in ("ios", "ipados", "ipad", "iphone"):
                os_ver = str(general.get("osVersion") or "")
                _major_match = re.match(r"^(\d+)", os_ver)
                if _major_match:
                    _major = int(_major_match.group(1))
                    if _major in (18, 26):
                        pass  # Recommended — no flag
                    elif _major == 17:
                        issues.append(
                            f"Minimum support - iOS {os_ver}"
                        )
                        actions.append(
                            "Plan upgrade to iOS 18 or 26 before iOS 27 ships."
                        )
                    elif _major > 0 and _major < 17:
                        issues.append(
                            f"Unsupported - iOS {os_ver}"
                        )
                        actions.append(
                            "Schedule OS upgrade to iOS 18 or 26."
                        )

            # Storage for OS updates. Display convention across all storage
            # values: GB by default with up to 2 decimal places; switch to MB
            # only when the value is below 1.0 GB so the magnitude stays
            # readable. The column header on this sheet carries "(GB)" so a
            # naked number means GB; any "MB" inline marks the rare exception.
            #
            # Remediation amount is computed per device: we aim to leave the
            # device with STORAGE_TARGET_GB free after cleanup (= the iOS-
            # update minimum + a 0.5 GB safety buffer). So a device with
            # 4.39 GB free is told to free at least 2.11 GB (4.39 + 2.11 = 6.5).
            avail = hardware.get("availableSpaceMb")
            cap = hardware.get("capacityMb")
            STORAGE_TARGET_GB = (STORAGE_MIN_MB_UPDATE / 1000.0) + 0.5  # e.g. 6.5
            if isinstance(avail, (int, float)):
                if avail < STORAGE_MIN_MB_UPDATE:
                    # GB integers only (no decimal places). Sub-1 GB → MB.
                    _free_disp = (f"{int(avail / 1000)} GB" if avail >= 1000
                                  else f"{int(avail)} MB")
                    issues.append(f"No space for iOS update ({_free_disp} free)")
                    # Round UP so the advice never undershoots the target.
                    import math as _math
                    _need_to_free_gb = max(
                        1,
                        _math.ceil(STORAGE_TARGET_GB - (avail / 1000.0)),
                    )
                    actions.append(
                        f"Free up a minimum of {_need_to_free_gb} GB by "
                        f"deleting unused apps or saved data."
                    )
                if isinstance(cap, (int, float)) and cap > 0:
                    pct_free = (avail / cap) * 100
                    if pct_free < STORAGE_MIN_PCT:
                        issues.append(f"Low storage ({pct_free:.0f}% free)")
                        # Avoid double-stacking the same remediation when the
                        # absolute-MB rule already fired (which already gave
                        # a specific GB number).
                        if not (actions and actions[-1].startswith("Free up a minimum")):
                            actions.append(
                                "Free up storage by deleting unused apps "
                                "or saved data."
                            )

            # MDM profile expiry
            exp = _parse_iso(general.get("mdmProfileExpirationDate") or "")
            if exp:
                days_until = (exp - _now_utc).days
                if days_until < 0:
                    issues.append(f"MDM profile EXPIRED ({-days_until}d ago)")
                    actions.append("Re-enrol device immediately.")
                elif days_until < MDM_EXPIRY_WARN_DAYS:
                    issues.append(f"MDM profile expires in {days_until}d")
                    actions.append(
                        f"Refresh MDM enrolment within {days_until} days to "
                        "avoid losing management."
                    )

            # BYOD / Personal ownership note (informational, not strictly orphan)
            if ownership == "personal":
                issues.append("Personal / BYOD ownership")
                actions.append(
                    "Limited MDM capabilities apply — restrictions, lost mode, "
                    "and app removal are restricted on personally-owned devices."
                )

            # "No assigned user" flag intentionally OMITTED for iOS for now —
            # the signal is too noisy for shared / institutional fleets and
            # the user prefers it off. To re-enable, restore the iOS-family +
            # non-Shared-prestage gating that previously lived here.

            # Shared iPad mode is NOT an issue — it's the intended deployment
            # for SHARED-<serial> devices coming through the Shared Personalised
            # prestage. Suppressed entirely (was previously surfaced as context).

            if not issues:
                continue

            # Build the row.
            dev_id = dev.get("mobileDeviceId") or general.get("id") or ""
            name = str(general.get("displayName") or "")
            serial = str(hardware.get("serialNumber") or "")
            model = str(hardware.get("model") or "")
            os_ver = str(general.get("osVersion") or "")
            last_inv_str = (last_inv.astimezone().strftime("%Y-%m-%d")
                            if last_inv else "-")
            # Storage Free column: integer GB when ≥ 1 GB; sub-1 GB shows MB
            # with explicit unit. Header for this column carries "(GB)".
            if isinstance(avail, (int, float)):
                if avail >= 1000:
                    avail_str = f"{int(avail / 1000)}"
                else:
                    avail_str = f"{int(avail)} MB"
            else:
                avail_str = "-"

            ios_health_rows.append([
                name or "-", serial or "-", model or "-",
                os_ver or "-", last_inv_str, avail_str,
                "\n".join(issues), "\n".join(actions),
            ])
            if serial:
                _ios_health_serials.add(serial.lower())
            _u = _url_ios_device(dev_id)
            if _u:
                ios_health_hyperlinks[(len(ios_health_rows) - 1, 0)] = _u

        # iOS Health Check Key — the iOS counterpart to the macOS Health
        # Check Key. Static reference content explaining each iOS flag. Built
        # here (inside the iOS block) so it only exists when the tenant has an
        # iOS fleet; placed directly after its Health Check sheet by the sheet
        # ordering pass. Shares the green tab colour with iOS - Health Check.
        all_sheets["iOS - Health Check Key"] = {
            "title": "iOS  |  Health Check Definitions",
            "headers": ["Check", "What it flags", "Why it matters", "Reference"],
            "rows": [
                list(row) + [IOS_HEALTH_CHECK_REFERENCES.get(row[0], "-")]
                for row in IOS_HEALTH_CHECK_DEFINITIONS
            ],
            "vertical_grid_50pct": True,
            "autoheight_wrap": True,
            "tab_color": _TAB_HC_IOS,
        }

        all_sheets["iOS - Health Check"] = {
            "title": "iOS  |  Health Check",
            "headers": [
                "Device Name", "Serial", "Model", "iOS Version",
                "Last Inventory", "Storage Free (GB)", "Issues", "Suggested Actions",
            ],
            "rows": ios_health_rows,
            "hyperlinks": ios_health_hyperlinks,
            # Same green tab colour as its Key sheet + hover tooltips pulling
            # "why it matters" from the iOS definitions.
            "tab_color": _TAB_HC_IOS,
            "issue_comment_platform": "ios",
        }

        # ── iOS - Devices (full fleet inventory) ─────────────────────────────
        # One row per managed iOS/iPadOS device — the full fleet, not just
        # unhealthy ones. Mirrors the macOS - Managed Macs sheet's column
        # order (identity → ownership → hardware/OS → enrolment → recency →
        # cross-reference) so an admin reading both platforms gets a
        # consistent shape. The final "Health Check Pending" column
        # cross-references the iOS Health Check sheet.
        #
        # Field sources (mobile-devices LIST response — general + hardware
        # are the only populated sections):
        #   Device Name           general.displayName
        #   Serial Number         hardware.serialNumber
        #   Username              general.username / userAndLocation.username
        #                         (often blank — list endpoint omits the
        #                         userAndLocation section)
        #   Ownership             general.deviceOwnershipType
        #                         (Personal / Institutional / Company-Owned)
        #   Model                 hardware.model
        #   iOS Version           general.osVersion
        #   Enrolment Method      general.enrollmentMethod.objectName / objectType
        #                         (often blank on iOS — list endpoint may omit)
        #   Enrolled Date         general.lastEnrollmentDate /
        #                         lastEnrollmentTimestamp
        #   Last Inventory        general.lastInventoryUpdateDate
        #   Health Check Pending  cross-reference to _ios_health_serials
        ios_fleet_rows: list[list[Any]] = []
        ios_fleet_hyperlinks: dict[tuple[int, int], str] = {}

        def _ios_short_date(s: Any) -> str:
            if not s:
                return "-"
            s = str(s).strip()
            return s.split("T", 1)[0] if "T" in s else (s or "-")

        for dev in ios_devices:
            if not isinstance(dev, dict):
                continue
            _gen = dev.get("general") or {}
            _hw  = dev.get("hardware") or {}
            # userAndLocation usually isn't populated on the list response,
            # but check just in case a future Jamf release starts including it.
            _ulc = dev.get("userAndLocation") or {}

            _name   = str(_gen.get("displayName") or _gen.get("name") or "").strip()
            _serial = str(_hw.get("serialNumber") or "").strip()
            _model  = str(_hw.get("model") or "").strip()
            _osver  = str(_gen.get("osVersion") or "").strip()

            # Username — try the most likely sources in order. Often blank
            # on iOS list responses; render "-" when nothing is found.
            _user = (
                str(_ulc.get("realname") or "").strip()
                or str(_ulc.get("username") or "").strip()
                or str(_gen.get("username") or "").strip()
            )

            # Ownership — analogous to macOS "Machine Role" column. Personal
            # vs Institutional/Company-Owned is the most useful axis on iOS.
            _own_raw = str(_gen.get("deviceOwnershipType") or "").strip()
            _ownership = {
                "personal":       "Personal",
                "institutional":  "Institutional",
                "company-owned":  "Company-Owned",
                "corporate":      "Corporate",
            }.get(_own_raw.lower(), _own_raw or "-")

            # Enrolment method — prefer enrollmentMethod.objectName if Jamf
            # returns the structured form on iOS; fall back to objectType,
            # then to a plain string field if one exists.
            _enroll = _gen.get("enrollmentMethod") or {}
            if isinstance(_enroll, dict):
                _enroll_type = str(_enroll.get("objectType") or "").strip()
                _enroll_name = str(_enroll.get("objectName") or "").strip()
                if "user" in _enroll_type.lower() and "initiated" in _enroll_type.lower():
                    _enroll_display = "User-Initiated Enrollment"
                elif _enroll_name:
                    _enroll_display = _enroll_name
                elif _enroll_type:
                    _enroll_display = _enroll_type
                else:
                    _enroll_display = "-"
            else:
                _enroll_display = str(_enroll or "-").strip() or "-"

            # Enrolled date — try the modern then the timestamp variant.
            _enrolled_dt = _ios_short_date(
                _gen.get("lastEnrollmentDate")
                or _gen.get("lastEnrollmentTimestamp")
                or _gen.get("lastEnrolledDate")
            )
            _last_inv = _ios_short_date(_gen.get("lastInventoryUpdateDate"))

            _hc_pending = "Yes" if _serial.lower() in _ios_health_serials else "No"

            ios_fleet_rows.append([
                _name or "-",
                _serial or "-",
                _user or "-",
                _ownership,
                _model or "-",
                _osver or "-",
                _enroll_display,
                _enrolled_dt,
                _last_inv,
                _hc_pending,
            ])
            # Hyperlink on Device Name cell — same UI deep link the Health
            # Check sheet uses.
            _dev_id = dev.get("mobileDeviceId") or _gen.get("id") or ""
            _u = _url_ios_device(_dev_id)
            if _u:
                ios_fleet_hyperlinks[(len(ios_fleet_rows) - 1, 0)] = _u

        ios_fleet_rows.sort(key=lambda r: str(r[0]).lower())

        all_sheets["iOS - Devices"] = {
            "title": "iOS  |  Devices",
            "headers": [
                "Device Name", "Serial Number", "Username",
                "Ownership", "Model", "iOS Version",
                "Enrolment Method", "Enrolled Date", "Last Inventory",
                "Health Check Pending",
            ],
            "rows": ios_fleet_rows,
            "hyperlinks": ios_fleet_hyperlinks,
        }

        # ── iOS - Software Updates ──────────────────────────────────────────
        # Mirror of the macOS sheet — same column layout, same inclusion
        # rules (active plan / failure / expired MDM / invalid blueprint).
        # iOS lacks a reliable mdmProfileExpiration field on all schema
        # versions, so we defer to whatever the inventory returns; absence
        # is treated as "not expired" rather than raising a false flag.
        msu_ios_rows: list[list[Any]] = []
        msu_ios_hyperlinks: dict[tuple[int, int], str] = {}
        if _need_msu_ios:
            _section_start("Building iOS Software Updates rows")
            for dev in ios_devices:
                if not isinstance(dev, dict):
                    continue
                _gen = dev.get("general") or {}
                _hw  = dev.get("hardware") or {}

                _name    = str(_gen.get("displayName") or _gen.get("name") or "").strip()
                _serial  = str(_hw.get("serialNumber") or "").strip()
                _model   = str(_hw.get("model") or "").strip()
                _osver   = str(_gen.get("osVersion") or "").strip()
                _mgmt_id = str(_gen.get("managementId") or "").strip()
                _last_seen = _msu_short_date(
                    _gen.get("lastInventoryUpdateDate")
                    or _gen.get("lastContactTime")
                )

                # iOS doesn't have a Machine Role EA in the same way; use
                # ownership (Personal / Institutional / Company-Owned) as
                # the closest analogue per the existing iOS Devices sheet.
                _own_raw = str(_gen.get("deviceOwnershipType") or "").strip()
                _role = {
                    "personal":      "Personal",
                    "institutional": "Institutional",
                    "company-owned": "Company-Owned",
                    "corporate":     "Corporate",
                }.get(_own_raw.lower(), _own_raw or "-")

                # Pre-filter signals — iOS-side.
                _mdm_exp_ts = _parse_dt(_gen.get("mdmProfileExpiration"))
                _mdm_expired = (_mdm_exp_ts is not None and _mdm_exp_ts < _now_ts)
                _device_id   = str(
                    dev.get("mobileDeviceId")
                    or _gen.get("id") or dev.get("id") or ""
                ).strip()
                _plans       = _msu_plans_by_device.get(_device_id, [])
                _failures    = (_failures_by_id.get(_device_id, [])
                                or _failures_by_serial.get(_serial.lower(), []))
                _has_signal  = (_mdm_expired or bool(_plans) or bool(_failures))

                if not _has_signal:
                    continue

                # On-demand: blueprint status + recent failed MDM commands.
                _bp_items = get_ddm_status_items(_mgmt_id, args.profile) if _mgmt_id else []
                _bp_summary, _bp_invalid = summarise_blueprint_status(_bp_items)
                _recent_failed_cmds = (
                    list_mdm_command_failures_for_device(_mgmt_id, args.profile, limit=3)
                    if _mgmt_id else []
                )

                _update_state, _issues_text, _remed_text = _msu_collect_issues(
                    _mdm_expired, _plans, _failures, _bp_invalid, _recent_failed_cmds,
                )

                msu_ios_rows.append([
                    _name or "-",
                    _serial or "-",
                    _model or "-",
                    _role or "-",
                    _osver or "-",
                    _last_seen,
                    _bp_summary,
                    _update_state,
                    _issues_text,
                    _remed_text,
                ])
                _u = _url_ios_device(_device_id) if _device_id else ""
                if _u:
                    msu_ios_hyperlinks[(len(msu_ios_rows) - 1, 0)] = _u

            msu_ios_rows.sort(key=lambda r: str(r[0]).lower())
            _section_done("iOS Software Updates rows", len(msu_ios_rows))

            if msu_ios_rows:
                all_sheets["iOS - Software Updates"] = {
                    "title": "iOS  |  Software Updates",
                    "headers": [
                        "Name", "Serial Number", "Model", "Ownership",
                        "iOS Version", "Last Check-In",
                        "Blueprint Status", "Update Status",
                        "Issues", "Remediation",
                    ],
                    "rows": msu_ios_rows,
                    "hyperlinks": msu_ios_hyperlinks,
                }

        # ── iOS - Orphaned Items ─────────────────────────────────────────────
        # Same shape as macOS Orphans: Name | Jamf Pro ID | Reason.
        # Sections: Apps no-scope, Profiles no-scope, Smart Groups unused,
        # Static Groups unused. Hashtag-in-name signal applies to apps and
        # profiles (matching the macOS pattern).
        #
        # NOTE: classic-mobile-config-profiles has no `enabled` field, so
        # the "disabled profiles" orphan rule (agreed in scoping) is skipped.
        # If Jamf ever surfaces an enabled flag on the modern API, this is
        # where we'd add the extra section.
        ios_orphan_rows: list[list] = []
        ios_orphan_hyperlinks: dict[tuple[int, int], str] = {}

        def _ios_add_section(title: str, count: int) -> None:
            ios_orphan_rows.append([f"+ {title} ({count}) +", "", ""])

        def _ios_add_orphan(name: str, item_id: int | str,
                            url: str, reason: str) -> None:
            ios_orphan_rows.append([
                name, str(item_id) if item_id is not None else "-",
                reason,
            ])
            if url:
                ios_orphan_hyperlinks[(len(ios_orphan_rows) - 1, 0)] = url

        # 1. Apps — hashtag in name OR no scope (mirrors macOS Restricted
        #    Software rule, applied here for consistency).
        _ios_orphan_apps: list[tuple[dict, str]] = []
        for app in ios_app_meta:
            # All Mobile Devices is a valid scope — apps using it are never
            # orphans, hashtag in name or not.
            if app["all_devices"]:
                continue
            _has_hash = "#" in (app.get("name") or "")
            _no_scope = not app["target_groups"]
            if _has_hash or _no_scope:
                if _has_hash and _no_scope:
                    _why = "Has '#' in name · no scope"
                elif _has_hash:
                    _why = "Has '#' in name"
                else:
                    _why = "No scope"
                _ios_orphan_apps.append((app, _why))
        _ios_orphan_apps.sort(key=lambda t: t[0]["name"].lower())
        _ios_add_section("Mobile Apps — hashtag or no scope", len(_ios_orphan_apps))
        for app, _why in _ios_orphan_apps:
            _ios_add_orphan(app["name"], app["id"], _url_ios_app(app["id"]), _why)
        ios_orphan_rows.append(["", "", ""])

        # 2. Config Profiles — no scope. (No 'disabled' field on iOS.)
        _ios_orphan_profs = [
            p for p in ios_profile_meta
            if not p["target_groups"] and not p["all_devices"]
        ]
        _ios_orphan_profs.sort(key=lambda p: p["name"].lower())
        _ios_add_section("Configuration Profiles — no scope", len(_ios_orphan_profs))
        for p in _ios_orphan_profs:
            _ios_add_orphan(p["name"], p["id"], _url_ios_profile(p["id"]), "No scope")
        ios_orphan_rows.append(["", "", ""])

        # 3. Smart Groups — not referenced anywhere.
        _ios_smart_orphans = [
            g for g in ios_groups
            if g["is_smart"] and g["name"] not in ios_used_groups
        ]
        _ios_smart_orphans.sort(key=lambda g: g["name"].lower())
        _ios_add_section("Smart Groups — not referenced anywhere",
                         len(_ios_smart_orphans))
        for g in _ios_smart_orphans:
            _ios_add_orphan(g["name"], g["id"], _url_ios_smart_group(g["id"]),
                            "Not referenced as scope/limitation/exclusion")
        ios_orphan_rows.append(["", "", ""])

        # 4. Static Groups — not referenced anywhere.
        _ios_static_orphans = [
            g for g in ios_groups
            if (not g["is_smart"]) and g["name"] not in ios_used_groups
        ]
        _ios_static_orphans.sort(key=lambda g: g["name"].lower())
        _ios_add_section("Static Groups — not referenced anywhere",
                         len(_ios_static_orphans))
        for g in _ios_static_orphans:
            _ios_add_orphan(g["name"], g["id"], _url_ios_static_group(g["id"]),
                            "Not referenced as scope/limitation/exclusion")

        _ios_orphan_total = (len(_ios_orphan_apps) + len(_ios_orphan_profs)
                             + len(_ios_smart_orphans) + len(_ios_static_orphans))

        all_sheets["iOS - Orphaned Items"] = {
            "title": f"iOS  |  Orphaned Items  ({_ios_orphan_total} total)",
            "headers": ["Name", "Jamf Pro ID", "Reason"],
            "rows": ios_orphan_rows,
            "summary_style": True,
            "hyperlinks": ios_orphan_hyperlinks,
            "skip_trim": True,
        }

    # ── Enforce sheet order ───────────────────────────────────────────────────
    # Summary is always first. macOS group runs Health Check → Managed Macs →
    # Apps Scope → Profiles Scope → Profiles → Scripts → EAs → Restricted SW
    # → Prestages → FileVault → Orphans. The iOS group below mirrors this
    # order as closely as iOS endpoints allow (no Scripts/EAs/Restricted
    # SW/Prestages/FileVault equivalents on iOS).
    _sheet_order = [
        "Jamf MSP Summary",
        # Each Health Check Key sits directly after its Health Check sheet so
        # the flags and their definitions read as one connected pair.
        "macOS - Health Check",
        "macOS - Health Check Key",
        "macOS - Managed Macs",
        "macOS - Apps - Scope",
        "macOS - Config Profiles - Scope",
        "macOS - Config Profiles",
        "macOS - Scripts",
        "macOS - Extension Attributes",
        "macOS - Restricted Software",
        "macOS - Printers",
        "macOS - Prestages",
        "macOS - FileVault Recovery Keys",
        "macOS - Software Updates",
        "macOS - Orphaned Items",
        # iOS group — mirrors macOS order. Health Check at the top so an
        # admin opening the workbook lands on the iOS issues immediately,
        # then the full-fleet inventory, then the scope/profile sheets,
        # then orphans.
        "iOS - Health Check",
        "iOS - Health Check Key",
        "iOS - Devices",
        "iOS - Apps - Scope",
        "iOS - Config Profiles - Scope",
        "iOS - Config Profiles",
        "iOS - Software Updates",
        "iOS - Orphaned Items",
        "Jamf Pro Accounts",
        "Jamf Protect",
    ]
    all_sheets = {
        k: all_sheets[k]
        for k in _sheet_order
        if k in all_sheets
    } | {k: v for k, v in all_sheets.items() if k not in _sheet_order}

    # ── Drop empty-fleet platform sheets ────────────────────────────────────
    # If the tenant has zero managed macOS devices, every macOS-prefixed
    # sheet (including the macOS - Health Check Key reference) is removed
    # from the workbook entirely — not even empty placeholders. Same for
    # iOS, though the iOS sheets are already gated upstream and don't
    # exist in all_sheets when _have_ios_fleet is False; this is a belt-
    # and-suspenders pass.
    if not _have_macos_fleet:
        all_sheets = {
            k: v for k, v in all_sheets.items()
            if not k.startswith("macOS - ")
        }
    if not _have_ios_fleet:
        all_sheets = {
            k: v for k, v in all_sheets.items()
            if not k.startswith("iOS - ")
        }

    # ── Filter to user-selected sheets (xlsx/csv only) ───────────────────────
    # selected_sheets was resolved up-front from --sheets, the picker, or "all".
    # Terminal mode ignores selection; it picks one dataset on its own below.
    if fmt in (FMT_XLSX, FMT_CSV):
        all_sheets = {k: v for k, v in all_sheets.items() if k in selected_sheets}

    if fmt == FMT_XLSX:
        xlsx_path = prefix.with_name(f"{prefix.name}-{datestamp}.xlsx")
        xlsx_path.parent.mkdir(parents=True, exist_ok=True)
        wb = build_workbook(all_sheets)
        # Post-build decoration for the Orphans sheets (hyperlinks + checklist
        # dropdown). Fires for whichever orphan sheets survived the user's
        # --sheets selection. Other sheets pass through unchanged.
        for _orphan_sheet in ("macOS - Orphaned Items", "iOS - Orphaned Items"):
            if _orphan_sheet in all_sheets:
                _decorate_orphans_sheet(wb, _orphan_sheet, all_sheets[_orphan_sheet])
        # Password is the jamf-cli profile name the script is already working
        # with (raw, unsanitised — same string the user typed/picked).
        xlsx_password = raw_profile
        save_encrypted(wb, str(xlsx_path), xlsx_password)
        print(f"Profiles processed:    {len(selected)}")
        print(f"Workbook:              {xlsx_path}")
        # Ollama cache stats — only meaningful when AI was actually used.
        # `note_miss()` is incremented inside the wrapped functions, so
        # `misses + hits` equals total cache lookups across the whole run.
        if (_ollama_cache.hits or _ollama_cache.misses) and not _ollama_cache.disabled:
            _total = _ollama_cache.hits + _ollama_cache.misses
            _pct = round(100 * _ollama_cache.hits / _total) if _total else 0
            print(f"Ollama cache:          {_ollama_cache.hits} hits / "
                  f"{_ollama_cache.misses} misses  ({_pct}% hit rate, "
                  f"db: {_OLLAMA_CACHE_PATH})")
        for name, spec in all_sheets.items():
            print(f"  Sheet: {name:<30} ({len(spec['rows'])} rows)")
        print()
        print("This file is password protected.")
        print(f"Password to open: {xlsx_password}")
        # Reveal the encrypted workbook in Finder (highlights the file in
        # its enclosing folder). Best-effort — don't fail the run if `open`
        # is missing (e.g. non-macOS environments).
        try:
            subprocess.run(["open", "-R", str(xlsx_path)], check=False)
        except FileNotFoundError:
            pass

    elif fmt == FMT_CSV:
        # Output folder: <prefix>-<YYYYMMDD>/ (e.g. /tmp/<profile>-jamfpro-configuration-<YYYYMMDD>/)
        # Convention matches the .command toolkit; the subfolder contains one
        # CSV per sheet so the output folder doesn't get cluttered with 10+ files per run.
        csv_dir = prefix.with_name(f"{prefix.name}-{datestamp}")
        csv_dir.mkdir(parents=True, exist_ok=True)

        # Derive a safe filename slug from each sheet name
        def _sheet_slug(name: str) -> str:
            slug = re.sub(r"[^\w]", "-", name)
            slug = re.sub(r"-{2,}", "-", slug).strip("-")
            return slug

        print(f"\nCSV folder:  {csv_dir}\n")
        for sheet_name, spec in all_sheets.items():
            slug = _sheet_slug(sheet_name)
            filename = f"{slug}.csv"
            path = csv_dir / filename
            with path.open("w", newline="", encoding="utf-8") as fh:
                w = csv.writer(fh)
                w.writerow([_dedash(h) for h in spec["headers"]])
                w.writerows(
                    [_dedash(v) if (v is not None and str(v).strip() != "") else "-"
                     for v in row]
                    for row in spec["rows"]
                )
            print(f"  {sheet_name:<35} → {filename}  ({len(spec['rows'])} rows)")
        print(f"\nAll CSVs written to:  {csv_dir}")

    elif fmt == FMT_TERMINAL:
        dataset_map = {
            "msp-summary":              "Jamf MSP Summary",
            "health-check-definitions": "macOS - Health Check Key",
            "health-check":             "macOS - Health Check",
            "managed-macs":             "macOS - Managed Macs",
            "ios-devices":              "iOS - Devices",
            "ios-health-check":         "iOS - Health Check",
            "prestages":                "macOS - Prestages",
            "config-profiles":          "macOS - Config Profiles",
            "config-profiles-scope":    "macOS - Config Profiles - Scope",
            "apps-scope":               "macOS - Apps - Scope",
            "scripts":                  "macOS - Scripts",
            "extension-attributes":     "macOS - Extension Attributes",
            "restricted-software":      "macOS - Restricted Software",
            "filevault-keys":           "macOS - FileVault Recovery Keys",
            "software-updates":         "macOS - Software Updates",
            "orphaned-items":           "macOS - Orphaned Items",
            "ios-software-updates":     "iOS - Software Updates",
            "jamf-pro-accounts":        "Jamf Pro Accounts",
        }
        if terminal_dataset == "all":
            for sheet_name, spec in all_sheets.items():
                _term_table(spec["headers"], spec["rows"], title=spec["title"])
        else:
            sheet_name = dataset_map.get(terminal_dataset, "macOS - Config Profiles - Scope")
            spec = all_sheets[sheet_name]
            _term_table(spec["headers"], spec["rows"], title=spec["title"])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())