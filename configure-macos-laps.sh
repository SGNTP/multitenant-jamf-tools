#!/bin/bash

# --------------------------------------------------------------------------------
# Guided setup for Jamf LAPS the dataJAR way (JMF LAPS via User-Initiated
# Enrollment), across one or more Jamf Pro instances.
#
# This is the multitenant-jamf-tools port of the JamfCLIToolkit
# macos-laps-config.command. It sources _common-framework.sh for instance-list
# selection and Keychain-backed authentication, and bridges to jamf-cli by
# feeding it an MJT-minted bearer token (jc() below), exactly like
# set-prestage-os-version.sh. All structured jamf-cli subcommands are preserved.
#
# It walks the dataJAR LAPS runbook per instance, automating what it can and
# pausing with instructions for the step that requires manual action:
#
#   1.   Settings > Global > User-Initiated Enrollment > Computers
#          Create managed local administrator account = ENABLED
#          Username                                    = <uie-username> (default lapsadmin)
#          Hide managed local administrator account    = ENABLED
#
#   2.   Settings > Computer Management > Security > LAPS
#          Rotation interval           (Never / 7d / 30d / 90d / 180d)
#          Rotation after viewing      (1h / 3h / 12h / 1d / 3d / 7d / 1s)
#          autoDeployEnabled           TRUE ("Enable LAPS for PreStage accounts")
#
#   3.   Script skipAccounts exclusions (GUIDED). Searches Jamf Pro scripts and
#        lists only those that actually contain a skipAccounts array, then maps
#        them to the policies that run them (the exclusion is a policy parameter).
#
#   7-8. Enrolment Invitation. Created automatically via the Classic API
#        (classic-computer-invitations create): a multi-use, ~10-year invitation.
#        API invitations have no distribution method and cannot email anyone, so
#        nothing is ever sent. The code is read straight back and wired into 9-10.
#
#   9-10. <uie-username> Is Installed smart group + Jamf Binary Re-enrol policy,
#        created via AutoPkg using the msp-internal-recipes recipe repo.
#
# IMPORTANT: the UIE username must DIFFER from your PreStage admin username, or
#   you hit PI112488 (500 on password retrieval). Default lapsadmin vs PreStage
#   _datajardotmobi is fine.
#
# PRIVILEGES: the Keychain account for each instance needs update on
#   User-Initiated Enrollment settings, read + update on LAPS settings, and read
#   on Scripts / Policies. The AutoPkg role needs create/update on computer
#   groups, scripts, and policies.
# --------------------------------------------------------------------------------

# set instance list type (Computers = mac)
instance_list_type="mac"

# defaults
uie_username=""             # -> managementUsername (default lapsadmin)
rotation_interval=""        # -> autoRotate*: "" (default never) | never | <seconds>
rotate_after_view=""        # -> passwordRotationTime seconds (default 86400 = 1 day)
jss_autopkg_url=""          # -> JSS_URL for autopkg (defaults to the instance URL)
invitation_id=""            # -> PARAMETER4_VALUE for the re-enrol recipe
created_invitation_id=""    # -> id of the invitation this run created (kept by cleanup)
recipe_repo=""              # -> path to msp-internal-recipes repo
exclusions_done=0           # -> confirms step 3; required for 9-10 under --yes
dry_run=0
assume_yes=0
skip_reenrol=0              # -> skip steps 9-10 entirely

FIXED_REPO_PATH="${MSP_RECIPES_PATH:-/Users/Shared/msp-internal-recipes}"
REENROL_RECIPE="Recipes-ScriptBasedPolicy-DJmobi/JamfBinaryReenrol-Ongoing-DJmobi.jamf.recipe.yaml"

workdir=""
returncode=0

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
Guided setup for Jamf LAPS (JMF LAPS via User-Initiated Enrollment) across one or
more Jamf Pro instances.

Run with no flags (and interactively) for a guided walk-through. Flags below skip
the prompts and are intended for automation.

LAPS values:
--uie-username NAME                - UIE managed admin username (default lapsadmin)
--rotation-interval VAL            - never | 7d | 30d | 90d | 180d (default never)
--rotate-after-view DUR            - passwordRotationTime (default 1d; e.g. 1h, 12h, 1d)

Steps 9-10 (AutoPkg re-enrol policy):
--jss-url URL                      - Jamf Pro URL for autopkg (default: the instance URL)
--invitation-id ID                 - Enrolment Invitation code (skips the 7-8 create)
--recipe-repo PATH                 - Path to msp-internal-recipes repo
                                     (default: /Users/Shared/msp-internal-recipes)
--exclusions-done                  - Confirm step 3 done; required to run 9-10 under --yes
--skip-reenrol                     - Skip steps 9-10 entirely (settings/invitation only)

Instances:
-il | --instance-list FILENAME     - instance-list filename (without .txt)
-i  | --instance JSS_URL           - a single instance (repeatable)
-a  | --all                        - all instances in the list
--user | --client-id CLIENT_ID     - client ID / username to use
-x  | --nointeraction              - run without interaction (implies --yes)

Other:
-n  | --dry-run                    - show what would change; write nothing
-v  | --verbose                    - verbose curl / jamf-cli output
-h  | --help                       - this help

Examples:
# Guided run against a single instance
./configure-macos-laps.sh -i https://tenant.jamfcloud.com

# Apply LAPS settings only (no re-enrol policy) across a whole list, unattended
./configure-macos-laps.sh -il my-mac-list --all --skip-reenrol --yes

# Full unattended run once step 3 exclusions are confirmed
./configure-macos-laps.sh -i https://tenant.jamfcloud.com --yes --exclusions-done
USAGE
}

# run jamf-cli for the current instance ($jss_url + token already set)
jc() {
    "$jamf_cli_path" "$@" --url "$jss_url" --token-file "$token_file_for_jamfcli"
}

# obtain a bearer token for the current $jss_instance and stage it for jc().
# sets jss_url + token_file_for_jamfcli. Returns 1 if a token can't be obtained.
token_for_instance() {
    jss_instance="$1"
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
    else
        set_credentials "$jss_instance"
    fi
    jss_url="$jss_instance"
    check_token || return 1
    token_file_for_jamfcli=$(mktemp /tmp/jamfcli_token.XXXXXX)
    echo "$token" > "$token_file_for_jamfcli"
}

# Convert "86400" / "1d" / "12h" / "30m" to seconds. Echoes seconds, returns 1 on bad input.
parse_duration() {
    local in num unit
    in="$(printf '%s' "${1}" | tr -d '[:space:]')"
    if [[ "${in}" =~ ^([0-9]+)([sSmMhHdD]?)$ ]]; then
        num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
        case "${unit}" in
            s|S|"") echo "${num}" ;;
            m|M)    echo $(( num * 60 )) ;;
            h|H)    echo $(( num * 3600 )) ;;
            d|D)    echo $(( num * 86400 )) ;;
        esac
        return 0
    fi
    return 1
}

# Pretty-print a seconds value, e.g. "86400s (1d)".
human_duration() {
    local s="${1}"
    if ! [[ "${s}" =~ ^[0-9]+$ ]]; then printf '%s' "${s}"; return; fi
    if   (( s % 86400 == 0 && s > 0 )); then printf '%ss (%dd)' "${s}" $(( s / 86400 ))
    elif (( s % 3600  == 0 && s > 0 )); then printf '%ss (%dh)' "${s}" $(( s / 3600 ))
    elif (( s % 60    == 0 && s > 0 )); then printf '%ss (%dm)' "${s}" $(( s / 60 ))
    else printf '%ss' "${s}"; fi
}

# Extract the lowercase host from a URL (strip scheme, path, port).
url_host() {
    local u="${1#*://}"
    u="${u%%/*}"; u="${u%%:*}"
    printf '%s' "${u}" | tr 'A-Z' 'a-z'
}

# section header
section() {
    echo
    echo "=================================================================="
    echo "  ${1}"
    echo "=================================================================="
}

# dim breadcrumb showing where this setting lives in Jamf Pro
crumb() { echo "  (${1})"; echo; }

# y/N confirm honouring --yes. $1 = prompt. Returns 0 for yes.
confirm() {
    [[ $assume_yes -eq 1 ]] && return 0
    local ans
    read -r -p "${1} (Y/N) : " ans
    [[ "${ans}" =~ ^[Yy] ]]
}

# True (0) if $1 appears as a whole word in the space-separated list $2.
name_in_list() {
    local n="${1}" list=" ${2} "
    [[ "${list}" == *" ${n} "* ]]
}

# Detect PreStage managed-admin usernames on the current instance, to warn on a
# collision with the UIE username (PI112488). Best-effort; empty on any failure.
detect_prestage_admins() {
    local json
    json=$(jc pro computer-prestages list --output json 2>/dev/null)
    [[ -z "${json}" ]] && return 0
    printf '%s' "${json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = d.get("results", d) if isinstance(d, dict) else d
if not isinstance(items, list):
    items = []
seen = []
for it in items:
    acct = it.get("accountSettings") if isinstance(it, dict) else None
    if not isinstance(acct, dict):
        continue
    for k, v in acct.items():
        if "adminusername" in k.lower() and isinstance(v, str) and v.strip():
            u = v.strip()
            if u not in seen:
                seen.append(u)
            break
sys.stdout.write(" ".join(seen))
' 2>/dev/null
}

# Resolve the UIE username (default lapsadmin). Warn if it collides with a detected
# PreStage (MDM) admin username on this instance.
resolve_uie_username() {
    local interactive=0
    [[ -t 0 && $assume_yes -eq 0 ]] && interactive=1

    local prestage_admins; prestage_admins=$(detect_prestage_admins)

    while true; do
        if [[ -z "${uie_username}" ]]; then
            if [[ $interactive -eq 1 ]]; then
                local a
                read -r -p "  UIE managed admin username (press Enter for the default, lapsadmin): " a
                uie_username="${a:-lapsadmin}"
            else
                uie_username="lapsadmin"
            fi
        fi

        if [[ -n "${prestage_admins}" ]] && name_in_list "${uie_username}" "${prestage_admins}"; then
            echo
            echo "  WARNING: \"${uie_username}\" matches a PreStage admin (${prestage_admins})."
            echo "  Using the same name for both breaks LAPS password retrieval (PI112488)."
            if [[ $interactive -eq 1 ]]; then
                confirm "  Use \"${uie_username}\" anyway?" && break
                uie_username=""
                continue
            fi
        fi
        break
    done
    echo
}

# numbered single-choice menu. $1 title, $2 outvar name, then "value|Label" pairs.
pick_value() {
    local title="${1}" outvar="${2}"; shift 2
    local pairs=("$@") i val lab sel
    echo
    echo "  ${title}:"
    for i in "${!pairs[@]}"; do
        lab="${pairs[$i]#*|}"
        printf "     [%s] %s\n" "$i" "${lab}"
    done
    echo
    read -r -p "     Choose by number: " sel
    if [[ "${sel}" =~ ^[0-9]+$ ]] && [[ -n "${pairs[$sel]:-}" ]]; then
        val="${pairs[$sel]%%|*}"
        printf -v "${outvar}" '%s' "${val}"
        return 0
    fi
    return 1
}

# Interactive numbered menus for the Step 2 values (only those not set by flag).
choose_laps_settings() {
    [[ -t 0 && $assume_yes -eq 0 ]] || return 0

    [[ -z "${rotation_interval}" ]] && pick_value "Rotation interval" rotation_interval \
        "never|Never" "604800|7 days" "2592000|30 days" "7776000|90 days" "15552000|180 days"

    [[ -z "${rotate_after_view}" ]] && pick_value "Rotation after viewing interval" rotate_after_view \
        "3600|1 hour" "10800|3 hours" "43200|12 hours" "86400|1 day" "259200|3 days" \
        "604800|7 days" "1|1 second"
}

# Locate the recipe repo (steps 9-10). Fixed path first; prompt if not found.
resolve_repo_path() {
    [[ $skip_reenrol -eq 1 ]] && return 1
    [[ -n "${recipe_repo}" && -d "${recipe_repo}" ]] && return 0

    if [[ -d "${FIXED_REPO_PATH}" ]]; then
        recipe_repo="${FIXED_REPO_PATH}"
        return 0
    fi

    if [[ $assume_yes -eq 1 || ! -t 0 ]]; then
        echo "  WARNING: recipe repo not found at ${FIXED_REPO_PATH}."
        echo "  Steps 9-10 (re-enrol policy) will be skipped. Use --recipe-repo PATH to enable."
        echo
        recipe_repo=""
        return 1
    fi

    echo "  Recipe repo not found at ${FIXED_REPO_PATH}."
    local a
    read -r -p "  Paste the path to your msp-internal-recipes repo (or Enter to skip): " a
    if [[ -n "${a}" && -d "${a}" ]]; then
        recipe_repo="${a}"
        echo
        return 0
    fi
    echo "  Skipping steps 9-10 (re-enrol policy)."
    echo
    recipe_repo=""
    return 1
}

# --------------------------------------------------------------------------------
# STEP 1: User-Initiated Enrollment managed admin
# --------------------------------------------------------------------------------
apply_uie() {
    section "Step 1: User-Initiated Enrollment managed admin"
    crumb "Settings > Global > User-Initiated Enrollment > Computers"

    local enr
    enr=$(jc pro enrollment-settings enrollment --output json 2>"${workdir}/uie-read.log")
    if [[ -z "${enr}" ]]; then
        echo "  ERROR: Could not read enrollment settings."
        [[ -s "${workdir}/uie-read.log" ]] && sed 's/^/    /' "${workdir}/uie-read.log"
        returncode=1
        return
    fi

    local tsv cur_cma cur_mu cur_hide
    tsv=$(printf '%s' "${enr}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if isinstance(d, dict) and isinstance(d.get("results"), dict):
    d = d["results"]
def b(x):
    return "true" if x is True else ("false" if x is False else "")
mu = d.get("managementUsername")
print("|".join([b(d.get("createManagementAccount")), (mu if isinstance(mu, str) else ""),
                b(d.get("hideManagementAccount"))]))
' 2>/dev/null)
    IFS='|' read -r cur_cma cur_mu cur_hide <<< "${tsv}"

    local was_cma="" was_mu="" was_hide=""
    [[ "${cur_cma}"  != "true" ]]           && was_cma="   (was ${cur_cma:-unset})"
    [[ "${cur_mu}"   != "${uie_username}" ]] && was_mu="   (was \"${cur_mu}\")"
    [[ "${cur_hide}" != "true" ]]           && was_hide="   (was ${cur_hide:-unset})"
    printf '  %-26s %s%s\n' "Create managed admin" "true"               "${was_cma}"
    printf '  %-26s %s%s\n' "Username"             "\"${uie_username}\"" "${was_mu}"
    printf '  %-26s %s%s\n' "Hide managed admin"   "true"               "${was_hide}"
    echo

    local new_enr
    new_enr=$(printf '%s' "${enr}" | J_MU="${uie_username}" python3 -c '
import json, sys, os
d = json.load(sys.stdin)
if isinstance(d, dict) and isinstance(d.get("results"), dict):
    d = d["results"]
if isinstance(d, dict):
    d["createManagementAccount"] = True
    d["managementUsername"] = os.environ.get("J_MU", "lapsadmin")
    d["hideManagementAccount"] = True
print(json.dumps(d))
' 2>/dev/null)

    if [[ $dry_run -eq 1 ]]; then
        echo "  (dry run) would set createManagementAccount=true, managementUsername=\"${uie_username}\", hideManagementAccount=true"
        echo
        return
    fi
    confirm "  Apply UIE change?" || { echo "  Skipped UIE change."; echo; return; }

    if printf '%s' "${new_enr}" \
        | jc pro enrollment-settings update-enrollment --output json \
          >"${workdir}/uie-write.log" 2>&1; then
        echo "  UIE managed admin set to \"${uie_username}\" (ticked + hidden)."
    else
        echo "  ERROR updating enrollment settings:"
        sed 's/^/    /' "${workdir}/uie-write.log"
        returncode=1
    fi
    echo
}

# --------------------------------------------------------------------------------
# STEP 2: LAPS settings
# --------------------------------------------------------------------------------
apply_laps_rotation() {
    section "Step 2: LAPS settings"
    crumb "Settings > Computer Management > Security > LAPS"

    local cur
    cur=$(jc pro local-admin-passwords settings --output json 2>"${workdir}/laps-read.log")
    if [[ -z "${cur}" ]]; then
        echo "  ERROR: Could not read current LAPS settings."
        [[ -s "${workdir}/laps-read.log" ]] && sed 's/^/    /' "${workdir}/laps-read.log"
        returncode=1
        return
    fi

    local tsv cur_deploy cur_rotate cur_expiry cur_rotview
    tsv=$(printf '%s' "${cur}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if isinstance(d, dict) and isinstance(d.get("results"), dict):
    d = d["results"]
def b(x): return "true" if x is True else ("false" if x is False else "")
def n(x): return str(x) if isinstance(x, int) and not isinstance(x, bool) else ""
print("|".join([b(d.get("autoDeployEnabled")), b(d.get("autoRotateEnabled")),
                n(d.get("autoRotateExpirationTime")), n(d.get("passwordRotationTime"))]))
' 2>/dev/null)
    IFS='|' read -r cur_deploy cur_rotate cur_expiry cur_rotview <<< "${tsv}"

    choose_laps_settings

    local final_deploy final_rotate final_expiry final_rotview
    final_deploy=true
    if [[ "${rotation_interval}" =~ ^[0-9]+$ ]]; then
        final_rotate=true;  final_expiry="${rotation_interval}"
    else
        final_rotate=false; final_expiry="${cur_expiry:-2592000}"   # Never / default
    fi
    final_rotview="${rotate_after_view:-86400}"

    local was_deploy="" was_rotate="" was_expiry="" was_rotview=""
    [[ "${cur_deploy}"  != "true" ]]             && was_deploy="   (was ${cur_deploy:-unset})"
    [[ "${cur_rotate}"  != "${final_rotate}" ]]  && was_rotate="   (was ${cur_rotate:-unset})"
    [[ "${cur_expiry}"  != "${final_expiry}" ]]  && was_expiry="   (was $(human_duration "${cur_expiry:-unset}"))"
    [[ "${cur_rotview}" != "${final_rotview}" ]] && was_rotview="   (was $(human_duration "${cur_rotview:-unset}"))"
    printf '  %-30s %s%s\n' "autoDeployEnabled"        "true (Enable LAPS for PreStage accounts)" "${was_deploy}"
    printf '  %-30s %s%s\n' "autoRotateEnabled"        "${final_rotate}"                          "${was_rotate}"
    printf '  %-30s %s%s\n' "autoRotateExpirationTime" "$(human_duration "${final_expiry}")"      "${was_expiry}"
    printf '  %-30s %s%s\n' "passwordRotationTime"     "$(human_duration "${final_rotview}")"     "${was_rotview}"
    echo

    # Persist resolved values so the replay summary reflects the run.
    rotation_interval=$([[ "${final_rotate}" == true ]] && echo "${final_expiry}" || echo never)
    rotate_after_view="${final_rotview}"

    local new_laps
    new_laps=$(J_AD="${final_deploy}" J_AR="${final_rotate}" J_EXP="${final_expiry}" J_RV="${final_rotview}" python3 -c '
import os, json
def tob(s): return s == "true"
print(json.dumps({
    "autoDeployEnabled":        tob(os.environ["J_AD"]),
    "autoRotateEnabled":        tob(os.environ["J_AR"]),
    "autoRotateExpirationTime": int(os.environ.get("J_EXP") or 2592000),
    "passwordRotationTime":     int(os.environ.get("J_RV") or 86400),
}))
' 2>/dev/null)

    if [[ $dry_run -eq 1 ]]; then
        echo "  (dry run) would PUT:"
        printf '%s\n' "${new_laps}" | sed 's/^/    /'
        echo
        return
    fi
    confirm "  Apply LAPS settings?" || { echo "  Skipped LAPS settings."; echo; return; }

    if printf '%s' "${new_laps}" \
        | jc pro local-admin-passwords update --output json \
          >"${workdir}/laps-write.log" 2>&1; then
        echo "  LAPS settings applied."
    else
        echo "  ERROR updating LAPS settings:"
        sed 's/^/    /' "${workdir}/laps-write.log"
        returncode=1
    fi
    echo
}

# --------------------------------------------------------------------------------
# STEP 3: guided script skipAccounts exclusions
# --------------------------------------------------------------------------------
guided_script_exclusions() {
    section "Step 3: Script skipAccounts exclusions"
    crumb "Computers > Policies  (exclusion is a policy parameter)"
    echo "  Searching scripts for a 'skipAccounts' array..."
    echo

    local list_json
    list_json=$(jc pro scripts list --output json 2>"${workdir}/scripts-list.log")
    if [[ -z "${list_json}" ]]; then
        echo "  Could not list scripts (check privileges / connection); skipping the search."
        [[ -s "${workdir}/scripts-list.log" ]] && sed 's/^/    /' "${workdir}/scripts-list.log"
        echo "  Manually add \"${uie_username}\" to skipAccounts in any demote/delete scripts."
        echo
        return
    fi

    local ids_file="${workdir}/scripts.tsv"
    printf '%s' "${list_json}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
items = d.get("results", d) if isinstance(d, dict) else d
if not isinstance(items, list):
    items = []
for it in items:
    if isinstance(it, dict) and it.get("id") is not None:
        print("%s\t%s" % (it.get("id"), str(it.get("name") or "")))
' > "${ids_file}" 2>/dev/null

    local total; total=$(grep -c . "${ids_file}" 2>/dev/null)
    if (( total == 0 )); then
        echo "  No scripts found in this instance."
        echo
        return
    fi

    # matchFile columns: scriptId, scriptName, hasUser (1 if the account already
    # appears in the script body, so its array already excludes it).
    local match_file="${workdir}/scripts-match.tsv"; : > "${match_file}"
    local sid sname n=0 body has_user
    while IFS=$'\t' read -r sid sname; do
        [[ -z "${sid}" ]] && continue
        n=$(( n + 1 ))
        body=$(jc pro scripts download "${sid}" 2>/dev/null)
        if printf '%s' "${body}" | grep -qi 'skipAccounts'; then
            has_user=0
            printf '%s' "${body}" | grep -qwF -- "${uie_username}" && has_user=1
            printf '%s\t%s\t%s\n' "${sid}" "${sname}" "${has_user}" >> "${match_file}"
        fi
        (( n % 10 == 0 )) && printf '\r  scanned %d/%d...' "${n}" "${total}"
    done < "${ids_file}"
    printf '\r  scanned %d/%d.        \n\n' "${n}" "${total}"

    local matched; matched=$(grep -c . "${match_file}" 2>/dev/null)
    if (( matched == 0 )); then
        echo "  No scripts contain a 'skipAccounts' array. Nothing to update for Step 3."
        echo
        return
    fi

    # Script IDs whose body already names the account (already excluded at the script level).
    local user_script_ids; user_script_ids=$(awk -F'\t' '$3==1{print $1}' "${match_file}" | paste -sd, -)

    local already_count; already_count=$(awk -F'\t' '$3==1' "${match_file}" | grep -c .)
    echo "  ${matched} script(s) use skipAccounts (${already_count} already name \"${uie_username}\")."
    echo "  Finding the policies that run them..."
    local skip_ids; skip_ids=$(cut -f1 "${match_file}" | paste -sd, -)

    jc pro classic-policies list --output json 2>"${workdir}/pol-list.log" \
      | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = d.get("policies", d) if isinstance(d, dict) else d
if not isinstance(items, list):
    items = []
for it in items:
    if isinstance(it, dict) and it.get("id") is not None:
        print("%s\t%s" % (it.get("id"), str(it.get("name") or "")))
' > "${workdir}/policies.tsv" 2>/dev/null

    local ptotal; ptotal=$(grep -c . "${workdir}/policies.tsv" 2>/dev/null)
    if (( ptotal == 0 )); then
        echo "  Could not list policies; showing the scripts instead:"
        while IFS=$'\t' read -r sid sname has_user; do
            if [[ "${has_user}" == "1" ]]; then
                printf '    [id %s]  %s  (already excludes %s)\n' "${sid}" "${sname}" "${uie_username}"
            else
                printf '    [id %s]  %s  (add %s)\n' "${sid}" "${sname}" "${uie_username}"
            fi
        done < "${match_file}"
        echo
        return
    fi

    echo "  Scanning ${ptotal} policies (this can take a moment)..."
    : > "${workdir}/polmatch.tsv"
    local pid pname pn=0
    while IFS=$'\t' read -r pid pname; do
        [[ -z "${pid}" ]] && continue
        pn=$(( pn + 1 ))
        jc pro classic-policies get "${pid}" --output json 2>/dev/null \
          | J_SKIP="${skip_ids}" J_USER="${uie_username}" J_HASUSER="${user_script_ids}" python3 -c '
import json, sys, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
pol = d.get("policy", d) if isinstance(d, dict) else {}
gen = pol.get("general", {}) if isinstance(pol, dict) else {}
pid = gen.get("id"); pname = gen.get("name", "")
skip = set(x for x in os.environ.get("J_SKIP", "").split(",") if x)
hasuser = set(x for x in os.environ.get("J_HASUSER", "").split(",") if x)
user = os.environ.get("J_USER", "")
scripts = pol.get("scripts") if isinstance(pol, dict) else None
if not isinstance(scripts, list):
    scripts = []
for s in scripts:
    if not isinstance(s, dict) or str(s.get("id")) not in skip:
        continue
    sname = str(s.get("name") or "")
    present = str(s.get("id")) in hasuser
    params = []
    for k in ("parameter4","parameter5","parameter6","parameter7","parameter8","parameter9","parameter10","parameter11"):
        v = s.get(k)
        if isinstance(v, str) and v.strip():
            params.append(k.replace("parameter", "p") + "=" + v.strip())
            if user and user in v:
                present = True
    print("\t".join([str(pid), pname, str(s.get("id")), sname, "1" if present else "0", "; ".join(params)]))
' >> "${workdir}/polmatch.tsv"
        (( pn % 20 == 0 )) && printf '\r  scanned %d/%d...' "${pn}" "${ptotal}"
    done < "${workdir}/policies.tsv"
    printf '\r  scanned %d/%d.        \n\n' "${pn}" "${ptotal}"

    local pmatched; pmatched=$(grep -c . "${workdir}/polmatch.tsv" 2>/dev/null)
    if (( pmatched == 0 )); then
        # No policy runs them, so the exclusion is likely hardcoded in the script body.
        local need_file="${workdir}/scripts-need.tsv" done_file="${workdir}/scripts-done.tsv"
        awk -F'\t' '$3==1' "${match_file}" > "${done_file}"
        awk -F'\t' '$3!=1' "${match_file}" > "${need_file}"
        if [[ -s "${need_file}" ]]; then
            echo "  Not attached to a policy, so the exclusion is likely hardcoded."
            echo "  Add \"${uie_username}\" to the skipAccounts array in these scripts:"
            while IFS=$'\t' read -r sid sname _; do printf '    [id %s]  %s\n' "${sid}" "${sname}"; done < "${need_file}"
            echo
        fi
        if [[ -s "${done_file}" ]]; then
            local dcount; dcount=$(grep -c . "${done_file}" 2>/dev/null)
            echo "  ${dcount} script(s) already exclude \"${uie_username}\"; no change needed."
            echo
        fi
        if [[ ! -s "${need_file}" ]]; then
            echo "  Nothing to edit for Step 3."
            echo
            return
        fi
        [[ $assume_yes -eq 0 && -t 0 ]] && { local a; read -r -p "  Press Enter to continue: " a; }
        echo
        return
    fi

    # Render affected policies as a numbered list; entries.tsv drives browser-open.
    J_ENTRIES="${workdir}/entries.tsv" J_USER="${uie_username}" python3 -c '
import sys, os
from collections import OrderedDict
ep   = os.environ["J_ENTRIES"]
user = os.environ.get("J_USER", "lapsadmin")
groups = OrderedDict()
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    pid, pname, sid, sname, present, params = (line.split("\t") + ["","","","","",""])[:6]
    groups.setdefault((pid, pname), []).append((sid, sname, present, params))
need = []; done = []
for key, items in groups.items():
    (done if all(p == "1" for _, _, p, _ in items) else need).append((key, items))
with open(ep, "w") as ef:
    if need:
        print("  To update (add %s to the exclusion parameter):" % user)
        print("")
        n = 0
        for (pid, pname), items in need:
            n += 1
            sids = ",".join(sid for sid, _, _, _ in items if sid)
            ef.write("%s\t%s\t%s\n" % (pid, pname, sids))
            print("  %2d | %s" % (n, pname))
            for sid, sname, present, params in items:
                note = "has " + user if present == "1" else "add " + user
                tail = ("  " + params) if params else ""
                print("        %s (%s)%s" % (sname, note, tail))
        print("")
if done:
    print("  Already exclude %s (no change needed):" % user)
    for (pid, pname), _ in done:
        print("     - %s" % pname)
' < "${workdir}/polmatch.tsv"
    echo

    local etotal; etotal=$(grep -c . "${workdir}/entries.tsv" 2>/dev/null)
    if (( etotal == 0 )); then
        echo "  All matching policies already exclude \"${uie_username}\"; nothing to edit."
        echo
        return
    fi
    if [[ $assume_yes -eq 1 ]]; then
        echo "  (--yes) Add ${uie_username} to the exclusion parameter in the policies above."
        echo
        return
    fi
    [[ -t 0 ]] || { echo; return; }

    # jss_url is the instance base URL, so build clickable edit links directly from it.
    if command -v open >/dev/null 2>&1; then
        local sel row epid escids s
        while true; do
            read -r -p "  Number to open its policy + script in the browser (Enter when done): " sel
            [[ -z "${sel}" ]] && break
            if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= etotal )); then
                row=$(sed -n "${sel}p" "${workdir}/entries.tsv")
                epid=$(printf '%s' "${row}" | cut -f1)
                escids=$(printf '%s' "${row}" | cut -f3)
                open "${jss_url}/policies.html?id=${epid}&o=r" 2>/dev/null
                for s in ${escids//,/ }; do
                    open "${jss_url}/view/settings/computer-management/scripts/${s}" 2>/dev/null
                done
            else
                echo "  Not a listed number."
            fi
        done
    else
        echo "  Policy URLs (copy into a browser):"
        local i=0 p
        while IFS=$'\t' read -r p _ _; do
            i=$(( i + 1 ))
            printf '    %2d  %s/policies.html?id=%s&o=r\n' "${i}" "${jss_url}" "${p}"
        done < "${workdir}/entries.tsv"
        local a; read -r -p "  Press Enter to continue: " a
    fi
    echo
}

# --------------------------------------------------------------------------------
# STEPS 7-8: Enrolment Invitation (Classic API)
# --------------------------------------------------------------------------------

# Read an invitation's exact numeric code by id. JSON output renders the code as a
# lossy float, so parse the raw/XML passthrough (preserves the full integer as text).
inv_code_by_id() {
    local id="${1}" fmt c
    for fmt in raw xml; do
        c=$(jc pro classic-computer-invitations get "${id}" --output "${fmt}" 2>/dev/null \
            | grep -oE '<invitation>[0-9]+</invitation>' | head -1 | grep -oE '[0-9]+' | head -1)
        [[ -n "${c}" ]] && break
    done
    printf '%s' "${c}"
}

# Newest (highest id) USER_INITIATED_EMAIL invitation id, via the list endpoint.
newest_email_invitation_id() {
    jc pro classic-computer-invitations list --output json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = d if isinstance(d, list) else ((d.get("results") if isinstance(d, dict) else []) or [])
best = -1
for it in items:
    if not isinstance(it, dict) or it.get("invitation_type") != "USER_INITIATED_EMAIL":
        continue
    try:
        n = int(it.get("id"))
    except Exception:
        continue
    if n > best:
        best = n
print(best if best >= 0 else "")
' 2>/dev/null
}

# Generate a strong random alphanumeric password (no XML-special chars).
random_password() {
    python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(32)))' 2>/dev/null \
        || LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32
}

# Emit the XML body for the computer invitation (multi-use, ~10-year, creates +
# hides the managed admin named ${uie_username}). $1 = ssh_password to embed.
invitation_xml() {
    local ssh_pw="${1}" exp_date
    exp_date=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(days=3650)).strftime("%Y-%m-%d %H:%M:%S"))' 2>/dev/null)
    [[ -z "${exp_date}" ]] && exp_date="2035-01-01 00:00:00"
    cat <<XML
<computer_invitation>
  <invitation_type>USER_INITIATED_EMAIL</invitation_type>
  <expiration_date>${exp_date}</expiration_date>
  <multiple_uses_allowed>true</multiple_uses_allowed>
  <ssh_username>${uie_username}</ssh_username>
  <ssh_password>${ssh_pw}</ssh_password>
  <create_account_if_does_not_exist>true</create_account_if_does_not_exist>
  <hide_account>true</hide_account>
  <lock_down_ssh>false</lock_down_ssh>
  <site>
    <id>-1</id>
    <name>None</name>
  </site>
</computer_invitation>
XML
}

# Create the invitation via the Classic API; set invitation_id to its code (and
# created_invitation_id to its id). Returns 1 on failure.
create_invitation_via_api() {
    local resp_json iid code ssh_pw
    ssh_pw=$(random_password)
    resp_json=$(invitation_xml "${ssh_pw}" | jc pro classic-computer-invitations create --output json 2>"${workdir}/inv-create.log")

    iid=$(printf '%s' "${resp_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
o = d
if isinstance(d, dict):
    for k in ("computer_invitation", "computerInvitation", "results"):
        v = d.get(k)
        if isinstance(v, dict):
            o = v; break
print(o.get("id") if isinstance(o, dict) and o.get("id") is not None else "")
' 2>/dev/null)

    [[ -z "${iid}" ]] && iid=$(newest_email_invitation_id)
    [[ -z "${iid}" ]] && return 1

    code=$(inv_code_by_id "${iid}")
    if [[ "${code}" =~ ^[0-9]{20,}$ ]]; then
        invitation_id="${code}"
        created_invitation_id="${iid}"
        echo "  Created enrolment invitation (id ${iid}). Code: ${invitation_id}"
        return 0
    fi
    return 1
}

# Opt-in deletion of OTHER existing USER_INITIATED_EMAIL invitations. $1 = id to keep.
# Interactive only, never under --yes.
cleanup_old_invitations() {
    local keep_id="${1}"
    [[ -t 0 && $assume_yes -eq 0 ]] || return 0

    local list_json inv_file="${workdir}/invitations-clean.tsv"
    list_json=$(jc pro classic-computer-invitations list --output json 2>/dev/null)
    [[ -z "${list_json}" ]] && return 0

    printf '%s' "${list_json}" | J_KEEP="${keep_id}" python3 -c '
import json, sys, os
keep = os.environ.get("J_KEEP", "")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def items(obj):
    if isinstance(obj, list):
        return [x for x in obj if isinstance(x, dict)]
    if isinstance(obj, dict):
        for key in ("computer_invitations", "computerinvitations", "computerInvitations", "results", "invitations"):
            v = obj.get(key)
            if isinstance(v, list):
                return [x for x in v if isinstance(x, dict)]
            if isinstance(v, dict):
                for k2 in ("computer_invitation", "computerInvitation"):
                    w = v.get(k2)
                    if isinstance(w, list):
                        return [x for x in w if isinstance(x, dict)]
                    if isinstance(w, dict):
                        return [w]
                return [x for x in v.values() if isinstance(x, dict)]
        if "invitation" in obj or "id" in obj:
            return [obj]
    return []
rows = []
for it in items(d):
    iid = it.get("id")
    if iid is None or str(iid) == str(keep):
        continue
    if it.get("invitation_type") != "USER_INITIATED_EMAIL":
        continue
    exp = str(it.get("expiration_date") or it.get("expiration_date_utc") or "")
    rows.append((str(iid), exp))
def idnum(r):
    try:
        return int(r[0])
    except Exception:
        return -1
rows.sort(key=idnum, reverse=True)
for r in rows:
    print("\t".join(r))
' > "${inv_file}" 2>/dev/null

    local count; count=$(grep -c . "${inv_file}" 2>/dev/null)
    (( count == 0 )) && return 0

    echo
    echo "  Other enrolment invitations (USER_INITIATED_EMAIL) exist in this tenant:"
    local i=0 iid exp
    while IFS=$'\t' read -r iid exp; do
        i=$(( i + 1 ))
        if [[ -n "${exp}" ]]; then
            printf '  %2d  id %-6s  (expires %s)\n' "${i}" "${iid}" "${exp}"
        else
            printf '  %2d  id %-6s\n' "${i}" "${iid}"
        fi
    done < "${inv_file}"
    echo
    echo "  Caution: only delete invitations you know are unused; others may rely on them."
    confirm "  Delete any of these now?" || { echo "  Left all invitations in place."; return 0; }

    local sel targets=() toks tok row rid
    read -r -p "  Numbers to delete (comma-separated, or 'all'): " sel
    [[ -z "${sel}" ]] && { echo "  Nothing deleted."; return 0; }

    if [[ "${sel}" == "all" || "${sel}" == "ALL" ]]; then
        while IFS=$'\t' read -r rid _; do targets+=("${rid}"); done < "${inv_file}"
    else
        IFS=',' read -ra toks <<< "${sel}"
        for tok in "${toks[@]}"; do
            tok="${tok//[[:space:]]/}"
            [[ "${tok}" =~ ^[0-9]+$ ]] || { echo "  Skipping '${tok}' (not a number)."; continue; }
            (( tok >= 1 && tok <= count )) || { echo "  Skipping ${tok} (out of range)."; continue; }
            row=$(sed -n "${tok}p" "${inv_file}")
            rid=$(printf '%s' "${row}" | cut -f1)
            [[ -n "${rid}" ]] && targets+=("${rid}")
        done
    fi

    (( ${#targets[@]} == 0 )) && { echo "  Nothing valid selected."; return 0; }
    echo "  Deleting invitation id(s): ${targets[*]}"
    confirm "  Confirm delete ${#targets[@]} invitation(s)?" || { echo "  Cancelled."; return 0; }

    local t
    for t in "${targets[@]}"; do
        if jc pro classic-computer-invitations delete "${t}" --yes >/dev/null 2>&1; then
            echo "    Deleted id ${t}."
        else
            echo "    Failed to delete id ${t}."
        fi
    done
}

# List existing invitations and let the user pick one; sets invitation_id. Fallback path.
capture_invitation_via_api() {
    local list_json inv_file="${workdir}/invitations.tsv"
    list_json=$(jc pro classic-computer-invitations list --output json 2>"${workdir}/inv-list.log")
    [[ -z "${list_json}" ]] && return 1

    printf '%s' "${list_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
def items(obj):
    if isinstance(obj, list):
        return [x for x in obj if isinstance(x, dict)]
    if isinstance(obj, dict):
        for key in ("computer_invitations", "computerinvitations", "computerInvitations", "results", "invitations"):
            v = obj.get(key)
            if isinstance(v, list):
                return [x for x in v if isinstance(x, dict)]
            if isinstance(v, dict):
                for k2 in ("computer_invitation", "computerInvitation"):
                    w = v.get(k2)
                    if isinstance(w, list):
                        return [x for x in w if isinstance(x, dict)]
                    if isinstance(w, dict):
                        return [w]
                return [x for x in v.values() if isinstance(x, dict)]
        if "invitation" in obj or "id" in obj:
            return [obj]
    return []
rows = []
for it in items(d):
    iid = it.get("id")
    if iid is None or it.get("invitation_type") != "USER_INITIATED_EMAIL":
        continue
    exp = it.get("expiration_date") or it.get("expiration_date_utc") or ""
    rows.append((str(iid), str(exp)))
def idnum(r):
    try:
        return int(r[0])
    except Exception:
        return -1
rows.sort(key=idnum, reverse=True)
for r in rows:
    print("\t".join(r))
' > "${inv_file}" 2>/dev/null

    local count; count=$(grep -c . "${inv_file}" 2>/dev/null)
    (( count == 0 )) && return 1

    echo "  Enrolment invitations in Jamf Pro (newest first):"
    echo
    local i=0 iid exp
    while IFS=$'\t' read -r iid exp; do
        i=$(( i + 1 ))
        if [[ -n "${exp}" ]]; then
            printf '  %2d  id %-6s  (expires %s)\n' "${i}" "${iid}" "${exp}"
        else
            printf '  %2d  id %-6s\n' "${i}" "${iid}"
        fi
    done < "${inv_file}"
    echo

    local sel row code
    while true; do
        read -r -p "  Pick the invitation you just created by number (or 'm' to type the code): " sel
        [[ "${sel}" == "m" || "${sel}" == "M" ]] && return 1
        if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= count )); then
            row=$(sed -n "${sel}p" "${inv_file}")
            iid=$(printf '%s' "${row}" | cut -f1)
            code=$(inv_code_by_id "${iid}")
            if [[ "${code}" =~ ^[0-9]{20,}$ ]]; then
                invitation_id="${code}"
                echo "  Invitation code captured: ${invitation_id}"
                return 0
            fi
            echo "  Could not read a full numeric code for that entry; try another or 'm'."
        else
            echo "  Not a listed number."
        fi
    done
}

# Required manual entry of the invitation code (used when the API path is skipped/fails).
prompt_invitation_manual() {
    echo "  Open the invitation you created and copy its Invitation code"
    echo "  (the long number in the 'Invitation' column)."
    local a
    while true; do
        read -r -p "  Invitation code (numbers only): " a
        if [[ "${a}" =~ ^[0-9]+$ ]]; then
            invitation_id="${a}"; echo "  Invitation code recorded: ${invitation_id}"; return 0
        fi
        echo "  Must be numeric. Try again."
    done
}

create_enrolment_invitation() {
    section "Steps 7-8: Enrolment Invitation"
    crumb "Computers > Enrollment Invitations"

    if [[ -n "${invitation_id}" ]]; then
        echo "  Using provided Invitation code: ${invitation_id}"
        echo
        return
    fi

    echo "  Creating a multi-use enrolment invitation via the Classic API. Its code is used"
    echo "  only by the AutoPkg re-enrol policy (next steps) to re-enrol the Mac and create"
    echo "  the ${uie_username} account. API invitations cannot email anyone; nothing is sent."
    echo

    if [[ $dry_run -eq 1 ]]; then
        echo "  (dry run) would POST this to classic-computer-invitations create:"
        invitation_xml "********" | sed 's/^/    /'
        echo
        return
    fi

    if create_invitation_via_api; then
        cleanup_old_invitations "${created_invitation_id}"
    else
        echo "  Could not auto-create the invitation."
        [[ -s "${workdir}/inv-create.log" ]] && sed 's/^/    /' "${workdir}/inv-create.log"
        echo
        if [[ -t 0 && $assume_yes -eq 0 ]]; then
            echo "  Falling back to an existing invitation (or manual entry)."
            capture_invitation_via_api || prompt_invitation_manual
        else
            echo "  Re-run with --invitation-id CODE once you have a code."
        fi
    fi
    echo
}

# --------------------------------------------------------------------------------
# STEPS 9-10: <uie-username> Is Installed group + Re-enrol policy (AutoPkg)
# --------------------------------------------------------------------------------
apply_reenrol_policy() {
    [[ $skip_reenrol -eq 1 ]] && return 0

    section "Steps 9-10: ${uie_username} Is Installed group + Re-enrol policy"
    crumb "Computers > Smart Computer Groups + Policies  (via AutoPkg)"

    if [[ -z "${invitation_id}" ]]; then
        echo "  No Invitation code; skipping."
        echo "  Re-run with --invitation-id CODE once you have it."
        echo
        return
    fi

    if [[ -z "${recipe_repo}" ]]; then
        echo "  No recipe repo; skipping."
        echo "  Re-run with --recipe-repo PATH to apply."
        echo
        return
    fi

    local recipe_path="${recipe_repo}/${REENROL_RECIPE}"
    if [[ ! -f "${recipe_path}" ]]; then
        echo "  ERROR: Recipe not found at: ${recipe_path}"
        echo
        returncode=1
        return
    fi

    if ! command -v autopkg >/dev/null 2>&1; then
        echo "  ERROR: autopkg not found in PATH."
        echo
        returncode=1
        return
    fi

    # Safety gate: don't deploy the re-enrol policy unattended unless the step 3
    # exclusions are confirmed, or lapsadmin could be demoted/deleted at check-in.
    if [[ $assume_yes -eq 1 && $exclusions_done -ne 1 ]]; then
        echo "  SAFETY: --yes given without --exclusions-done."
        echo "  Steps 9-10 create the re-enrol policy that deploys \"${uie_username}\". If the"
        echo "  demote/delete-account scripts (step 3) do not yet exclude \"${uie_username}\","
        echo "  deploying it now could get it demoted or deleted on the next check-in."
        echo "  Skipping 9-10. Re-run with --exclusions-done once step 3 is confirmed."
        echo
        return
    fi

    # AutoPkg targets the same tenant, so default JSS_URL to this instance's URL.
    local this_jss_url="${jss_autopkg_url:-$jss_url}"

    local group_name="${uie_username} Is Installed"
    echo "  JSS URL:         ${this_jss_url}"
    echo "  Recipe:          ${recipe_path}"
    echo "  Account:         ${uie_username}"
    echo "  Group:           ${group_name}"
    echo "  Invitation code: ${invitation_id}"
    echo

    if [[ $dry_run -eq 1 ]]; then
        echo "  (dry run) would run:"
        printf '  autopkg run "%s" \\\n' "${recipe_path}"
        printf '    --key PARAMETER4_VALUE="%s" \\\n' "${invitation_id}"
        printf '    --key MANAGEMENT_ACCOUNT="%s" \\\n' "${uie_username}"
        printf '    --key JSS_URL="%s" \\\n' "${this_jss_url}"
        printf '    --key EXCLUDED_GROUP_NAME_2="%s"\n' "${group_name}"
        echo
        return
    fi

    confirm "  Run AutoPkg recipe?" || { echo "  Skipped."; echo; return; }

    # MANAGEMENT_ACCOUNT and EXCLUDED_GROUP_NAME_2 are BOTH derived from the one UIE
    # username, so the managed account and its "Is Installed" smart group always match.
    local autopkg_args=("${recipe_path}" --key "PARAMETER4_VALUE=${invitation_id}")
    autopkg_args+=(--key "MANAGEMENT_ACCOUNT=${uie_username}")
    autopkg_args+=(--key "EXCLUDED_GROUP_NAME_2=${group_name}")
    autopkg_args+=(--key "JSS_URL=${this_jss_url}")

    if autopkg run "${autopkg_args[@]}"; then
        echo
        echo "  ${group_name} group and re-enrol policy created."
    else
        echo
        echo "  ERROR: AutoPkg run failed. Check output above."
        returncode=1
    fi
    echo
}

# run the full runbook against the current $jss_instance (token already staged)
process_instance() {
    resolve_uie_username
    apply_uie
    apply_laps_rotation
    guided_script_exclusions
    create_enrolment_invitation
    apply_reenrol_policy
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        --uie-username)     shift; uie_username="$1" ;;
        --rotation-interval)
            shift
            case "$1" in
                never|Never|"") rotation_interval="never" ;;
                *) rotation_interval=$(parse_duration "$1") \
                    || { echo "ERROR: invalid rotation interval: $1"; exit 1; } ;;
            esac
            ;;
        --rotate-after-view)
            shift
            rotate_after_view=$(parse_duration "$1") \
                || { echo "ERROR: invalid duration: $1"; exit 1; }
            ;;
        --jss-url)          shift; jss_autopkg_url="$1" ;;
        --invitation-id)    shift; invitation_id="$1" ;;
        --recipe-repo)      shift; recipe_repo="$1" ;;
        --exclusions-done)  exclusions_done=1 ;;
        --skip-reenrol)     skip_reenrol=1 ;;
        -il|--instance-list) shift; chosen_instance_list_file="$1" ;;
        -i|--instance)      shift; chosen_instances+=("$1") ;;
        -a|-ai|--all|--all-instances) all_instances=1 ;;
        --id|--client-id|--user|--username) shift; chosen_id="$1" ;;
        -x|--nointeraction) no_interaction=1; assume_yes=1 ;;
        -n|--dry-run)       dry_run=1 ;;
        -y|--yes)           assume_yes=1 ;;
        -v|--verbose)       verbose=1 ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done
echo

# temp working directory for per-instance API scratch files
workdir=$(mktemp -d /tmp/configure-macos-laps-XXXXXX)
trap 'rm -f "${token_file_for_jamfcli:-}"; rm -rf "${workdir}"' EXIT

# tenant mismatch check: --jss-url should target the same host as the chosen instance(s)
if [[ -n "${jss_autopkg_url}" && ${#chosen_instances[@]} -eq 1 ]]; then
    ih=$(url_host "${chosen_instances[0]}"); jh=$(url_host "${jss_autopkg_url}")
    if [[ -n "$ih" && -n "$jh" && "$ih" != "$jh" ]]; then
        echo "WARNING: --jss-url host ($jh) differs from the instance host ($ih)."
        echo "Steps 9-10 would create the re-enrol policy on a different tenant."
        confirm "Proceed anyway?" || { echo "Aborted."; exit 1; }
        echo
    fi
fi

echo "This tool applies the Jamf LAPS runbook to the instance(s) you choose."
[[ $dry_run -eq 1 ]] && echo "(dry-run: no changes will be written)"

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    # a single -i lands in chosen_instances[0]; choose_destination_instances only
    # resolves the singular chosen_instance (or chosen_instances when >1), so promote it.
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# locate the recipe repo once (shared across instances; steps 9-10)
resolve_repo_path || true

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
    rm -f "${token_file_for_jamfcli}"
    token_file_for_jamfcli=""
done

echo
echo "Finished"
echo
exit "${returncode:-0}"
