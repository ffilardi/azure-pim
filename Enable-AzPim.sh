#!/usr/bin/env bash
# ==============================================================================
# Enable-AzPim.sh — Activate (or deactivate) Azure PIM eligible role assignments
# ==============================================================================
# Replaces the manual "Activate" clicking in the Azure portal. All activation
# requests are submitted up-front and then polled together, so N resource groups
# take about as long as one.
#
# Uses the Azure Resource Manager PIM APIs via the token from `az account
# get-access-token`:
#   - Microsoft.Authorization/roleEligibilityScheduleInstances  (what you may activate)
#   - Microsoft.Authorization/roleAssignmentScheduleInstances    (what is active right now)
#   - Microsoft.Authorization/roleAssignmentScheduleRequests     (activate / deactivate)
#
# PREREQUISITES:  bash 3.2+, jq, curl, az CLI (logged in), date (GNU or BSD)
# ==============================================================================

set -euo pipefail

VERSION="1.1"

# Field separator for the internal record tables. ASCII Unit Separator cannot
# occur in an Azure resource name, unlike '|'.
SEP=$'\x1f'

API_VERSION='2020-10-01'
ARM_ROOT='https://management.azure.com'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${SCRIPT_DIR}/Enable-AzPim.config.json"

# ------------------------------------------------------------------ usage --

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Activate (or deactivate) Azure PIM eligible role assignments from the command line.

Options:
  -ResourceGroup <rg> [<rg>...]    One or more resource group names.
                                   Wildcards supported (e.g. 'az-rg-*').
                                   Omit to use saved defaults from config file.

  -Role <name>                     Role name to activate. Default: Contributor.
                                   Use '*' for every eligible role.

  -Duration <value>                How long to activate for. Accepts '8h', '30m',
                                   '4.5h' or a raw ISO-8601 duration ('PT8H').
                                   Capped by the PIM policy on the role.

  -Justification <text>            Business justification recorded in the PIM audit log.

  -Subscription <id|name>          Optional subscription filter, for when the same
                                   RG name exists in several subscriptions.

  -List                            Read-only. Shows eligible roles and which are
                                   currently active. Changes nothing.

  -Deactivate                      Deactivates the matching roles instead of
                                   activating them.

  -All                             Targets every eligible assignment (subject to
                                   -Role / -Subscription filters).

  -NoWait                          Submit the requests and return immediately
                                   instead of polling to completion.

  -TimeoutMinutes <minutes>        How long to poll for provisioning. Default: 5.

  -TicketNumber <number>           Ticket number, if your PIM policy requires it.

  -TicketSystem <system>           Ticket system name, if your PIM policy requires it.

  -SaveDefaults                    Saves the parameters used in this run as the
                                   defaults in the config file.

  -ShowToken                       Display current az CLI token claims (useful for
                                   debugging MFA / step-up issues).

  -NoReauth                        When a request needs step-up auth, skip the
                                   re-auth retry and just report errors.

  -TenantId <id>                   Tenant ID for step-up login.

  -Version                         Print the script version.
  -? | -h | --help                 Show this help message.

Exit codes: 0 = everything requested succeeded (or was already in the desired
state), 1 = at least one request failed or the script could not run.
EOF
}

# ------------------------------------------------------------------ output --

if [ -t 1 ]; then
    CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    RED=$'\033[0;31m'; DARKGRAY=$'\033[0;90m'; RESET=$'\033[0m'
else
    CYAN=''; GREEN=''; YELLOW=''; RED=''; DARKGRAY=''; RESET=''
fi

# Progress goes to stderr so stdout stays parseable and so that a helper whose
# stdout is captured can never contaminate its own return value.
step() { printf '%s==> %s%s\n' "$CYAN"     "$*" "$RESET" >&2; }
ok()   { printf '    %s%s%s\n' "$GREEN"    "$*" "$RESET" >&2; }
skip() { printf '    %s%s%s\n' "$DARKGRAY" "$*" "$RESET" >&2; }
warn() { printf '    %s%s%s\n' "$YELLOW"   "$*" "$RESET" >&2; }
err()  { printf '    %s%s%s\n' "$RED"      "$*" "$RESET" >&2; }
die()  { err "$*"; exit 1; }

# ------------------------------------------------------------------ args --

RESOURCE_GROUPS=()
ROLE='Contributor'
ROLE_EXPLICIT=false
DURATION=''
JUSTIFICATION=''
SUBSCRIPTION=''
DO_LIST=false
DO_DEACTIVATE=false
DO_ALL=false
DO_NOWAIT=false
TIMEOUT_MINUTES=5
TICKET_NUMBER=''
TICKET_SYSTEM=''
DO_SAVE_DEFAULTS=false
DO_SHOW_TOKEN=false
DO_NO_REAUTH=false
TENANT_ID=''

need_value() {
    # $1 = option name, $2 = number of args remaining after the option
    [ "$2" -ge 2 ] || die "Option $1 requires a value."
}

while [ $# -gt 0 ]; do
    case "$1" in
        -ResourceGroup)
            shift
            while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
                RESOURCE_GROUPS+=("$1"); shift
            done
            ;;
        -Role)           need_value "$1" $#; ROLE="$2"; ROLE_EXPLICIT=true; shift 2 ;;
        -Duration)       need_value "$1" $#; DURATION="$2";         shift 2 ;;
        -Justification)  need_value "$1" $#; JUSTIFICATION="$2";    shift 2 ;;
        -Subscription)   need_value "$1" $#; SUBSCRIPTION="$2";     shift 2 ;;
        -TimeoutMinutes) need_value "$1" $#; TIMEOUT_MINUTES="$2";  shift 2 ;;
        -TicketNumber)   need_value "$1" $#; TICKET_NUMBER="$2";    shift 2 ;;
        -TicketSystem)   need_value "$1" $#; TICKET_SYSTEM="$2";    shift 2 ;;
        -TenantId)       need_value "$1" $#; TENANT_ID="$2";        shift 2 ;;
        -List)           DO_LIST=true;          shift ;;
        -Deactivate)     DO_DEACTIVATE=true;    shift ;;
        -All)            DO_ALL=true;           shift ;;
        -NoWait)         DO_NOWAIT=true;        shift ;;
        -SaveDefaults)   DO_SAVE_DEFAULTS=true; shift ;;
        -ShowToken)      DO_SHOW_TOKEN=true;    shift ;;
        -NoReauth)       DO_NO_REAUTH=true;     shift ;;
        -Version)        echo "$VERSION"; exit 0 ;;
        -h|--help|'-?')  usage; exit 0 ;;
        *)               err "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
done

case "$TIMEOUT_MINUTES" in
    ''|*[!0-9]*) die "-TimeoutMinutes must be a whole number of minutes." ;;
esac

# ------------------------------------------------------------------ preflight --

for tool in jq curl az; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool '$tool' is not on PATH."
done

# Pick a working date implementation once, rather than guessing per call.
DATE_MODE=''
if [ "$(date -u -d '2000-01-01T00:00:00' '+%s' 2>/dev/null || true)" = '946684800' ]; then
    DATE_MODE='gnu'
elif command -v gdate >/dev/null 2>&1; then
    DATE_MODE='gdate'
elif [ "$(date -u -j -f '%Y-%m-%dT%H:%M:%S' '2000-01-01T00:00:00' '+%s' 2>/dev/null || true)" = '946684800' ]; then
    DATE_MODE='bsd'
fi

# ISO-8601 UTC timestamp -> epoch seconds. Fractional seconds and the trailing
# offset are dropped; ARM always returns UTC here.
iso_to_epoch() {
    local dt="${1:0:19}"
    [ "${#dt}" -eq 19 ] || return 1
    case "$DATE_MODE" in
        gnu)   date  -u -d "$dt" '+%s' 2>/dev/null ;;
        gdate) gdate -u -d "$dt" '+%s' 2>/dev/null ;;
        bsd)   date  -u -j -f '%Y-%m-%dT%H:%M:%S' "$dt" '+%s' 2>/dev/null ;;
        *)     return 1 ;;
    esac
}

epoch_to_local() {
    local e="$1"
    case "$DATE_MODE" in
        gnu)   date  -d "@$e" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$e" ;;
        gdate) gdate -d "@$e" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$e" ;;
        bsd)   date  -r "$e"  '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$e" ;;
        *)     echo "$e" ;;
    esac
}

# "$1" = end timestamp. Prints "Xh Ym" remaining, or nothing if unknown/expired.
remaining_for() {
    local end_dt="$1" end_epoch now_epoch mins
    [ -n "$end_dt" ] || return 1
    end_epoch="$(iso_to_epoch "$end_dt" || true)"
    [ -n "$end_epoch" ] || return 1
    now_epoch="$(date -u '+%s')"
    mins=$(( (end_epoch - now_epoch) / 60 ))
    [ "$mins" -gt 0 ] || return 1
    printf '%dh %dm' "$(( mins / 60 ))" "$(( mins % 60 ))"
}

# ------------------------------------------------------------------ helpers --

convert_to_iso_duration() {
    local value="$1"
    [ -n "$value" ] || return 0

    local v="${value// /}"
    if [ "${v#[Pp]}" != "$v" ]; then
        printf '%s' "$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]')"
        return 0
    fi

    if [[ "$v" =~ ^([0-9]+\.?[0-9]*)(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)$ ]]; then
        local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}" mins
        case "$unit" in
            h|hr|hrs|hour|hours) mins=$(awk -v n="$num" 'BEGIN { printf "%d", n * 60 + 0.5 }') ;;
            *)                   mins=$(awk -v n="$num" 'BEGIN { printf "%d", n + 0.5 }') ;;
        esac
        [ "$mins" -gt 0 ] || die "Duration '$value' resolves to zero."
        if [ $(( mins % 60 )) -eq 0 ]; then
            printf 'PT%dH' "$(( mins / 60 ))"
        else
            printf 'PT%dM' "$mins"
        fi
        return 0
    fi

    die "Could not parse duration '$value'. Use e.g. '8h', '90m' or 'PT8H'."
}

format_duration() {
    local iso="$1" h=0 m=0
    if [[ "$iso" =~ ^PT([0-9]+)H([0-9]+)M$ ]]; then
        h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
    elif [[ "$iso" =~ ^PT([0-9]+)H$ ]]; then
        h="${BASH_REMATCH[1]}"
    elif [[ "$iso" =~ ^PT([0-9]+)M$ ]]; then
        h=$(( BASH_REMATCH[1] / 60 )); m=$(( BASH_REMATCH[1] % 60 ))
    else
        printf '%s' "$iso"; return 0
    fi
    if   [ "$m" -eq 0 ]; then printf '%dh' "$h"
    elif [ "$h" -eq 0 ]; then printf '%dm' "$m"
    else                      printf '%dh %dm' "$h" "$m"; fi
}

b64url_decode() {
    local data="${1//-/+}"
    data="${data//_//}"
    case $(( ${#data} % 4 )) in
        2) data="${data}==" ;;
        3) data="${data}="  ;;
        1) return 1 ;;
    esac
    printf '%s' "$data" | base64 -d 2>/dev/null || printf '%s' "$data" | base64 -D 2>/dev/null
}

jwt_claims() {
    local t="${1#*.}"     # drop the header
    t="${t%%.*}"          # drop the signature
    b64url_decode "$t"
}

# URL-decode (percent-decoding, '+' as space), as used on the claims challenge.
urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

new_guid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | awk '{
            printf "%s-%s-4%s-a%s-%s", substr($0,1,8), substr($0,9,4),
                   substr($0,14,3), substr($0,18,3), substr($0,21,12) }'
    fi
}

TOKEN=''

get_arm_token() {
    local raw
    if ! raw=$(az account get-access-token --resource "$ARM_ROOT" -o json 2>&1); then
        err "az CLI could not get a token. Run 'az login' first."
        printf '%s\n' "$raw" >&2
        exit 1
    fi
    printf '%s' "$raw" | jq -r '.accessToken'
}

get_signed_in_object_id() {
    local oid
    oid=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
    oid="${oid//[$'\r\n']/}"
    if [ -n "$oid" ]; then printf '%s' "$oid"; return 0; fi

    # Fallback for service principals / restricted Graph access: read the oid claim.
    local claims oid_claim
    claims=$(jwt_claims "$TOKEN" || true)
    oid_claim=$(printf '%s' "$claims" | jq -r '.oid // empty' 2>/dev/null || true)
    [ -n "$oid_claim" ] || die 'Unable to determine the signed-in principal object id.'
    printf '%s' "$oid_claim"
}

# invoke_arm <method> <uri> [body]
# Always exits 0. Prints the HTTP status code on the first line, the response
# body (possibly empty, possibly multi-line) on the remaining lines.
invoke_arm() {
    local method="$1" uri="$2" body="${3:-}"
    local args=( -sS -X "$method"
                 -H "Authorization: Bearer $TOKEN"
                 -H "Content-Type: application/json"
                 -w $'\n%{http_code}' )
    [ -n "$body" ] && args+=( --data-binary "$body" )

    local out
    if ! out=$(curl "${args[@]}" "$uri" 2>/dev/null); then
        printf '000\n'
        return 0
    fi
    printf '%s\n%s' "${out##*$'\n'}" "${out%$'\n'*}"
}

http_code_of() { printf '%s' "${1%%$'\n'*}"; }
http_body_of() { local r="$1"; if [ "${r#*$'\n'}" = "$r" ]; then printf ''; else printf '%s' "${r#*$'\n'}"; fi; }

arm_error_message() {
    local body="$1"
    if printf '%s' "$body" | jq -e 'has("error")' >/dev/null 2>&1; then
        printf '%s' "$body" | jq -r '"\(.error.code // "Unknown"): \(.error.message // "Unknown error")"'
    elif [ -n "$body" ]; then
        printf '%s' "$body"
    else
        printf 'empty response'
    fi
}

# ------------------------------------------------------------------ config --

load_config() {
    [ -f "$CONFIG_PATH" ] || return 0

    local config
    if ! config=$(jq -e . "$CONFIG_PATH" 2>/dev/null); then
        warn "Ignoring unreadable config file $CONFIG_PATH"
        return 0
    fi

    if [ "${#RESOURCE_GROUPS[@]}" -eq 0 ] && [ "$DO_ALL" = false ] && [ "$DO_LIST" = false ]; then
        local rg
        while IFS= read -r rg; do
            [ -n "$rg" ] && RESOURCE_GROUPS+=("$rg")
        done < <(printf '%s' "$config" | jq -r '.resourceGroups // [] | .[]')
    fi

    local v
    if [ "$ROLE_EXPLICIT" = false ]; then
        v=$(printf '%s' "$config" | jq -r '.role // empty');          [ -n "$v" ] && ROLE="$v"
    fi
    if [ -z "$DURATION" ]; then
        v=$(printf '%s' "$config" | jq -r '.duration // empty');      [ -n "$v" ] && DURATION="$v"
    fi
    if [ -z "$JUSTIFICATION" ]; then
        v=$(printf '%s' "$config" | jq -r '.justification // empty'); [ -n "$v" ] && JUSTIFICATION="$v"
    fi
    if [ -z "$TICKET_NUMBER" ]; then
        v=$(printf '%s' "$config" | jq -r '.ticketNumber // empty');  [ -n "$v" ] && TICKET_NUMBER="$v"
    fi
    if [ -z "$TICKET_SYSTEM" ]; then
        v=$(printf '%s' "$config" | jq -r '.ticketSystem // empty');  [ -n "$v" ] && TICKET_SYSTEM="$v"
    fi
    return 0
}

# ------------------------------------------------------------------ PIM data --

ELIGIBLE_DATA=''
ACTIVE_DATA=''

# Record layout (SEP-joined):
#   eligible: sub rg role_name role_def scope scope_display elig_id member_type via_principal
#   active:   scope role_suffix end_dt
read_pim_state() {
    local resp code body

    resp=$(invoke_arm GET "${ARM_ROOT}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=${API_VERSION}&\$filter=asTarget()")
    code=$(http_code_of "$resp"); body=$(http_body_of "$resp")
    [ "$code" = "200" ] || die "Failed to read eligibilities (HTTP $code): $(arm_error_message "$body")"

    ELIGIBLE_DATA=$(printf '%s' "$body" | jq -r --arg sep "$SEP" '
        .value[]?
        | (.properties.scope // "") as $scope
        | ($scope | split("/")) as $p
        | ($scope | ascii_downcase | split("/")) as $pl
        | [ (($pl | index("subscriptions"))  as $i | if $i == null then "N/A" else ($p[$i+1] // "N/A") end),
            (($pl | index("resourcegroups")) as $j | if $j == null then ""    else ($p[$j+1] // "")    end),
            (.properties.expandedProperties.roleDefinition.displayName // "Unknown"),
            (.properties.roleDefinitionId // ""),
            $scope,
            (.properties.expandedProperties.scope.displayName // "Unknown"),
            (.properties.roleEligibilityScheduleId // ""),
            (.properties.memberType // ""),
            (.properties.expandedProperties.principal.displayName // "Unknown")
          ] | join($sep)')

    resp=$(invoke_arm GET "${ARM_ROOT}/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=${API_VERSION}&\$filter=asTarget()")
    code=$(http_code_of "$resp"); body=$(http_body_of "$resp")
    [ "$code" = "200" ] || die "Failed to read active assignments (HTTP $code): $(arm_error_message "$body")"

    ACTIVE_DATA=$(printf '%s' "$body" | jq -r --arg sep "$SEP" '
        .value[]?
        | select(.properties.assignmentType == "Activated")
        | [ (.properties.scope // ""),
            ((.properties.roleDefinitionId // "") | split("/") | last // ""),
            (.properties.endDateTime // "")
          ] | join($sep)')
}

count_records() {
    [ -n "$1" ] || { printf '0'; return 0; }
    printf '%s\n' "$1" | grep -c . || true
}

# find_active <scope> <role_definition_id>
# Exits 0 when the role is currently active on that scope; prints its end time.
find_active() {
    local scope="$1" suffix="${2##*/}" a_scope a_suffix a_end
    [ -n "$ACTIVE_DATA" ] || return 1
    while IFS="$SEP" read -r a_scope a_suffix a_end; do
        [ -n "$a_scope" ] || continue
        if [ "$a_scope" = "$scope" ] && [ "$a_suffix" = "$suffix" ]; then
            printf '%s' "$a_end"
            return 0
        fi
    done <<< "$ACTIVE_DATA"
    return 1
}

# ------------------------------------------------------------------ requests --

MY_OID=''
ISO_DURATION=''
REQUEST_TYPE=''
FAILED_COUNT=0

build_request_body() {
    local role_def="$1" elig_id="$2"
    jq -c -n \
        --arg oid   "$MY_OID" \
        --arg rdef  "$role_def" \
        --arg rtype "$REQUEST_TYPE" \
        --arg just  "$JUSTIFICATION" \
        --arg elig  "$elig_id" \
        --arg iso   "$ISO_DURATION" \
        --arg tn    "$TICKET_NUMBER" \
        --arg ts    "$TICKET_SYSTEM" \
        '{ properties: (
             { principalId: $oid, roleDefinitionId: $rdef, requestType: $rtype, justification: $just }
           + (if $elig == "" then {} else
                { linkedRoleEligibilityScheduleId: $elig,
                  scheduleInfo: { startDateTime: null,
                                  expiration: { type: "AfterDuration", duration: $iso } } }
              end)
           + (if ($tn == "" and $ts == "") then {} else
                { ticketInfo: { ticketNumber: $tn, ticketSystem: $ts } }
              end) ) }'
}

# Entra returns the exact claims challenge to satisfy inside the error text.
claims_challenge_from_error() {
    local msg="$1"
    local re="claims=\"?([^[:space:]&\"']+)"
    [[ "$msg" =~ $re ]] || return 1
    local decoded
    decoded=$(urldecode "${BASH_REMATCH[1]}" 2>/dev/null || true)
    [ -n "$decoded" ] || return 1
    printf '%s' "$decoded" | jq -e . >/dev/null 2>&1 || return 1
    printf '%s' "$decoded" | base64 | tr -d '\n'
}

step_up_login() {
    local claims_b64="$1"

    # az reuses a cached access token even after `az logout`, so the MSAL
    # access-token cache has to be dropped for the step-up token to be used.
    rm -f "$HOME/.azure/msal_token_cache.bin" 2>/dev/null || true

    local login_args=( login --only-show-errors --output none )
    [ -n "$claims_b64" ] && login_args+=( --claims-challenge "$claims_b64" )
    [ -n "$TENANT_ID" ]  && login_args+=( --tenant "$TENANT_ID" )

    warn 'Complete the sign-in / MFA prompt in the browser that just opened...'
    az "${login_args[@]}" || die 'Step-up sign-in failed.'

    TOKEN=$(get_arm_token)
}

# Parallel arrays describing every request we care about.
REQ_NAME=(); REQ_SCOPE=(); REQ_URI=(); REQ_BODY=()
REQ_STATE=()    # pending | stepup | failed | done
REQ_STATUS=()   # last ARM status, or the error message for stepup/failed

# submit_request <index> — (re)submits REQ_BODY[i] under a fresh request id and
# updates REQ_STATE/REQ_STATUS. Returns 0 when the request is now pending.
submit_request() {
    local i="$1"
    local uri="${ARM_ROOT}${REQ_SCOPE[$i]}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/$(new_guid)?api-version=${API_VERSION}"
    REQ_URI[$i]="$uri"

    local resp code body
    resp=$(invoke_arm PUT "$uri" "${REQ_BODY[$i]}")
    code=$(http_code_of "$resp"); body=$(http_body_of "$resp")

    if [ "$code" = "200" ] || [ "$code" = "201" ]; then
        REQ_STATE[$i]='pending'
        REQ_STATUS[$i]=$(printf '%s' "$body" | jq -r '.properties.status // "Submitted"')
        return 0
    fi

    REQ_STATUS[$i]=$(arm_error_message "$body")
    REQ_STATE[$i]='failed'
    return 1
}

# ------------------------------------------------------------------ main --

main() {
    load_config

    [ -n "$DURATION" ]      || DURATION='8h'
    [ -n "$JUSTIFICATION" ] || JUSTIFICATION='Scheduled operational support work'

    ISO_DURATION=$(convert_to_iso_duration "$DURATION")

    TOKEN=$(get_arm_token)
    MY_OID=$(get_signed_in_object_id)

    if [ "$DO_SHOW_TOKEN" = true ]; then
        local claims upn amr iat exp
        claims=$(jwt_claims "$TOKEN" || true)
        if [ -z "$claims" ]; then
            warn 'Could not decode the access token.'
        else
            upn=$(printf '%s' "$claims" | jq -r '.upn // .preferred_username // .appid // "N/A"')
            amr=$(printf '%s' "$claims" | jq -r '(.amr // []) | join(", ")')
            iat=$(printf '%s' "$claims" | jq -r '.iat // 0')
            exp=$(printf '%s' "$claims" | jq -r '.exp // 0')

            step 'Current az CLI token'
            printf '    user     : %s\n' "$upn"                 >&2
            printf '    amr      : %s\n' "$amr"                 >&2
            printf '    issued   : %s\n' "$(epoch_to_local "$iat")" >&2
            printf '    expires  : %s\n' "$(epoch_to_local "$exp")" >&2

            if printf '%s' "$claims" | jq -e '(.amr // []) | index("mfa")' >/dev/null 2>&1; then
                ok 'MFA claim present - PIM activation will be accepted.'
            else
                err 'No "mfa" value in amr - Azure will reject activation. See -? notes on the WAM broker.'
            fi
            printf '\n' >&2
        fi
    fi

    step 'Reading PIM eligibilities'
    read_pim_state

    local eligible_count active_count
    eligible_count=$(count_records "$ELIGIBLE_DATA")
    active_count=$(count_records "$ACTIVE_DATA")

    if [ "$eligible_count" -eq 0 ]; then
        warn 'No eligible PIM role assignments found for your account.'
        return 0
    fi
    ok "$eligible_count eligible assignment(s), $active_count currently active."

    # ---- subscription filter -------------------------------------------------

    if [ -n "$SUBSCRIPTION" ]; then
        local filtered='' line sub rg role_name role_def scope scope_display elig_id member_type via
        while IFS="$SEP" read -r sub rg role_name role_def scope scope_display elig_id member_type via; do
            [ -n "$scope" ] || continue
            if [ "$sub" = "$SUBSCRIPTION" ] || [ "${scope#*$SUBSCRIPTION}" != "$scope" ]; then
                filtered+="${sub}${SEP}${rg}${SEP}${role_name}${SEP}${role_def}${SEP}${scope}${SEP}${scope_display}${SEP}${elig_id}${SEP}${member_type}${SEP}${via}"$'\n'
            fi
        done <<< "$ELIGIBLE_DATA"
        ELIGIBLE_DATA="${filtered%$'\n'}"
        if [ -z "$ELIGIBLE_DATA" ]; then
            warn "No eligible assignment is in subscription '$SUBSCRIPTION'."
            return 0
        fi
    fi

    # ---- list mode -----------------------------------------------------------

    if [ "$DO_LIST" = true ]; then
        local sub rg role_name role_def scope scope_display elig_id member_type via
        local status end_dt left

        printf '\n'
        printf '%-22s %-40s %-24s %s\n' 'Role' 'ResourceGroup' 'Status' 'Subscription'
        printf '%-22s %-40s %-24s %s\n' '----' '-------------' '------' '------------'

        while IFS="$SEP" read -r sub rg role_name role_def scope scope_display elig_id member_type via; do
            [ -n "$scope" ] || continue
            status='eligible'
            if end_dt=$(find_active "$scope" "$role_def"); then
                if left=$(remaining_for "$end_dt"); then
                    status="ACTIVE ($left left)"
                else
                    status='ACTIVE'
                fi
            fi
            printf '%-22s %-40s %-24s %s\n' "$role_name" "$scope_display" "$status" "$sub"
        done < <(printf '%s\n' "$ELIGIBLE_DATA" | sort -t"$SEP" -k3,3 -k2,2)

        return 0
    fi

    # ---- select targets ------------------------------------------------------

    local targets=() line
    shopt -s nocasematch   # PowerShell -like / -eq are case-insensitive

    if [ "$DO_ALL" = true ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && targets+=("$line")
        done <<< "$ELIGIBLE_DATA"
    elif [ "${#RESOURCE_GROUPS[@]}" -gt 0 ]; then
        local pattern matched sub rg role_name role_def scope scope_display elig_id member_type via
        for pattern in "${RESOURCE_GROUPS[@]}"; do
            matched=false
            while IFS="$SEP" read -r sub rg role_name role_def scope scope_display elig_id member_type via; do
                [ -n "$scope" ] || continue
                if [[ "$scope_display" == $pattern ]] || { [ -n "$rg" ] && [[ "$rg" == $pattern ]]; }; then
                    targets+=("${sub}${SEP}${rg}${SEP}${role_name}${SEP}${role_def}${SEP}${scope}${SEP}${scope_display}${SEP}${elig_id}${SEP}${member_type}${SEP}${via}")
                    matched=true
                fi
            done <<< "$ELIGIBLE_DATA"
            [ "$matched" = true ] || warn "No eligible assignment matches '$pattern'."
        done
    else
        shopt -u nocasematch
        die 'Nothing to do. Pass -ResourceGroup, -All, or -List (or save defaults with -SaveDefaults).'
    fi

    # Role filter
    if [ "$ROLE" != '*' ] && [ "${#targets[@]}" -gt 0 ]; then
        local kept=() role_name
        for line in "${targets[@]}"; do
            role_name=$(printf '%s' "$line" | cut -d"$SEP" -f3)
            [[ "$role_name" == "$ROLE" ]] && kept+=("$line")
        done
        targets=( ${kept[@]+"${kept[@]}"} )
    fi

    shopt -u nocasematch

    # Deduplicate on scope + role name
    local final=()
    if [ "${#targets[@]}" -gt 0 ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && final+=("$line")
        done < <(printf '%s\n' "${targets[@]}" | sort -t"$SEP" -k5,5 -k3,3 -u)
    fi

    if [ "${#final[@]}" -eq 0 ]; then
        warn "No eligible '$ROLE' assignments matched your filters. Run with -List to see what you have."
        return 0
    fi

    # ---- build and submit ----------------------------------------------------

    local verb='Activating'
    REQUEST_TYPE='SelfActivate'
    if [ "$DO_DEACTIVATE" = true ]; then
        verb='Deactivating'
        REQUEST_TYPE='SelfDeactivate'
    fi

    if [ "$DO_DEACTIVATE" = true ]; then
        step "$verb $ROLE on ${#final[@]} scope(s)"
    else
        step "$verb $ROLE on ${#final[@]} scope(s) for $(format_duration "$ISO_DURATION")"
    fi

    local sub rg role_name role_def scope scope_display elig_id member_type via
    local end_dt left i msg
    for line in "${final[@]}"; do
        IFS="$SEP" read -r sub rg role_name role_def scope scope_display elig_id member_type via <<< "$line"

        if [ "$DO_DEACTIVATE" = false ]; then
            if end_dt=$(find_active "$scope" "$role_def"); then
                if left=$(remaining_for "$end_dt"); then
                    skip "$scope_display - already active (expires in $left)"
                else
                    skip "$scope_display - already active"
                fi
                continue
            fi
        else
            if ! find_active "$scope" "$role_def" >/dev/null; then
                skip "$scope_display - not active"
                continue
            fi
        fi

        i="${#REQ_NAME[@]}"
        REQ_NAME[$i]="$scope_display"
        REQ_SCOPE[$i]="$scope"
        REQ_URI[$i]=''
        REQ_STATE[$i]='new'
        REQ_STATUS[$i]=''
        if [ "$DO_DEACTIVATE" = true ]; then
            REQ_BODY[$i]=$(build_request_body "$role_def" "")
        else
            REQ_BODY[$i]=$(build_request_body "$role_def" "$elig_id")
        fi

        if submit_request "$i"; then
            ok "$scope_display - submitted [${REQ_STATUS[$i]}]"
            continue
        fi

        msg="${REQ_STATUS[$i]}"
        case "$msg" in
            *RoleAssignmentExists*)
                REQ_STATE[$i]='done'
                skip "$scope_display - already active"
                ;;
            *PendingRoleAssignmentRequest*)
                REQ_STATE[$i]='done'
                warn "$scope_display - a request is already pending (likely awaiting approval)."
                ;;
            *AcrsValidationFailed*|*RequestDisallowedByAzure*|*MfaRule*|*[Mm][Ff][Aa]\ *|*\ [Mm][Ff][Aa]*)
                # Conditional Access / PIM authentication-context step-up required.
                REQ_STATE[$i]='stepup'
                ;;
            *RoleAssignmentRequestPolicyValidationFailed*)
                FAILED_COUNT=$(( FAILED_COUNT + 1 ))
                err "$scope_display - policy rejected the request: $msg"
                err '      Common causes: duration exceeds the policy maximum, or justification /'
                err '      ticket info / approval required. Try -TicketNumber and -TicketSystem.'
                ;;
            *)
                FAILED_COUNT=$(( FAILED_COUNT + 1 ))
                err "$scope_display - $msg"
                ;;
        esac
    done

    # ---- step up and retry ---------------------------------------------------

    local stepup=()
    for (( i=0; i<${#REQ_STATE[@]}; i++ )); do
        [ "${REQ_STATE[$i]}" = 'stepup' ] && stepup+=("$i")
    done

    if [ "${#stepup[@]}" -gt 0 ]; then
        printf '\n' >&2
        warn "${#stepup[@]} request(s) need a stronger/fresher sign-in (PIM authentication context)."

        if [ "$DO_NO_REAUTH" = true ]; then
            for i in "${stepup[@]}"; do
                err "${REQ_NAME[$i]} - ${REQ_STATUS[$i]}"
                REQ_STATE[$i]='failed'
                FAILED_COUNT=$(( FAILED_COUNT + 1 ))
            done
            warn 'Re-run without -NoReauth to sign in and retry automatically.'
        else
            local challenge=''
            for i in "${stepup[@]}"; do
                if challenge=$(claims_challenge_from_error "${REQ_STATUS[$i]}"); then
                    [ -n "$challenge" ] && break
                fi
                challenge=''
            done
            if [ -z "$challenge" ]; then
                # Fall back to explicitly demanding an MFA claim.
                challenge=$(printf '%s' '{"access_token":{"amr":{"essential":true,"values":["mfa"]}}}' | base64 | tr -d '\n')
            fi

            step 'Re-authenticating to satisfy the PIM policy'
            step_up_login "$challenge"

            step "Retrying ${#stepup[@]} request(s)"
            for i in "${stepup[@]}"; do
                if submit_request "$i"; then
                    ok "${REQ_NAME[$i]} - submitted [${REQ_STATUS[$i]}]"
                    continue
                fi
                msg="${REQ_STATUS[$i]}"
                case "$msg" in
                    *RoleAssignmentExists*)
                        REQ_STATE[$i]='done'
                        skip "${REQ_NAME[$i]} - already active" ;;
                    *PendingRoleAssignmentRequest*)
                        REQ_STATE[$i]='done'
                        warn "${REQ_NAME[$i]} - a request is already pending (likely awaiting approval)." ;;
                    *)
                        FAILED_COUNT=$(( FAILED_COUNT + 1 ))
                        err "${REQ_NAME[$i]} - $msg" ;;
                esac
            done
        fi
    fi

    # ---- save defaults -------------------------------------------------------

    if [ "$DO_SAVE_DEFAULTS" = true ]; then
        local rg_json config_json tmp
        rg_json=$(printf '%s\n' "${final[@]}" | cut -d"$SEP" -f6 | grep . | sort -u | jq -R . | jq -s .)
        config_json=$(jq -n \
            --argjson rgs "$rg_json" \
            --arg role "$ROLE" --arg dur "$DURATION" --arg just "$JUSTIFICATION" \
            --arg tn "$TICKET_NUMBER" --arg ts "$TICKET_SYSTEM" \
            '{ resourceGroups: $rgs, role: $role, duration: $dur,
               justification: $just, ticketNumber: $tn, ticketSystem: $ts }')
        tmp="${CONFIG_PATH}.tmp.$$"
        printf '%s\n' "$config_json" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
        ok "Saved defaults to $CONFIG_PATH"
    fi

    # ---- poll ----------------------------------------------------------------

    local pending=()
    for (( i=0; i<${#REQ_STATE[@]}; i++ )); do
        [ "${REQ_STATE[$i]}" = 'pending' ] && pending+=("$i")
    done

    if [ "${#pending[@]}" -eq 0 ]; then
        step 'Nothing to wait for.'
        return 0
    fi
    if [ "$DO_NOWAIT" = true ]; then
        step "${#pending[@]} request(s) submitted. Not waiting (-NoWait)."
        return 0
    fi

    step "Waiting for ${#pending[@]} request(s) to provision (timeout ${TIMEOUT_MINUTES}m)"

    local deadline done_count=0 resp code body status
    deadline=$(( $(date -u '+%s') + TIMEOUT_MINUTES * 60 ))

    # Requests that already came back terminal need no polling.
    for i in "${pending[@]}"; do
        case "${REQ_STATUS[$i]}" in
            Provisioned|Granted|Revoked|Canceled)
                REQ_STATE[$i]='done'
                done_count=$(( done_count + 1 ))
                ;;
        esac
    done

    while [ "$(date -u '+%s')" -lt "$deadline" ] && [ "$done_count" -lt "${#pending[@]}" ]; do
        sleep 5
        for i in "${pending[@]}"; do
            [ "${REQ_STATE[$i]}" = 'pending' ] || continue

            resp=$(invoke_arm GET "${REQ_URI[$i]}")
            code=$(http_code_of "$resp"); body=$(http_body_of "$resp")
            [ "$code" = "200" ] || continue

            status=$(printf '%s' "$body" | jq -r '.properties.status // empty')
            [ -n "$status" ] || continue
            REQ_STATUS[$i]="$status"

            case "$status" in
                Provisioned|Granted|Revoked|Canceled)
                    REQ_STATE[$i]='done'; done_count=$(( done_count + 1 )); ok "${REQ_NAME[$i]} - $status" ;;
                Failed|FailedAsResourceIsLocked|Denied|TimedOut)
                    REQ_STATE[$i]='failed'; done_count=$(( done_count + 1 ))
                    FAILED_COUNT=$(( FAILED_COUNT + 1 )); err "${REQ_NAME[$i]} - $status" ;;
                *PendingApproval*)
                    REQ_STATE[$i]='failed'; done_count=$(( done_count + 1 ))
                    warn "${REQ_NAME[$i]} - $status (an approver must action this request)" ;;
            esac
        done
        if [ "$done_count" -lt "${#pending[@]}" ]; then
            printf '%s.%s' "$DARKGRAY" "$RESET" >&2
        fi
    done
    printf '\n' >&2

    for i in "${pending[@]}"; do
        if [ "${REQ_STATE[$i]}" = 'pending' ]; then
            warn "${REQ_NAME[$i]} - still provisioning after ${TIMEOUT_MINUTES}m. It will likely complete shortly; re-run with -List to check."
        fi
    done

    local succeeded=0
    for i in "${pending[@]}"; do
        [ "${REQ_STATE[$i]}" = 'done' ] && succeeded=$(( succeeded + 1 ))
    done

    step "Done. $succeeded/${#pending[@]} request(s) completed."
    return 0
}

main
[ "$FAILED_COUNT" -eq 0 ] || exit 1
exit 0
