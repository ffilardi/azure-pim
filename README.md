# Enable-AzPim

Activate (and deactivate) your Azure PIM eligible role assignments from the command line
instead of clicking through the portal.

All activation requests are submitted up front and then polled together, so activating
10 resource groups takes about as long as activating one.

- **PowerShell script:** `Enable-AzPim.ps1` (Windows, macOS, Linux)
- **Bash script:**    `Enable-AzPim.sh` (macOS, Linux)
- **Defaults file:**   `Enable-AzPim.config.json` (created by `-SaveDefaults`)

---

## Prerequisites — PowerShell

Only two things are needed — there are **no PowerShell modules to install**. The script
talks to the Azure REST API directly using the built-in `Invoke-RestMethod`, and only
shells out to `az` to get an access token and to sign in.

| Requirement | Notes |
| --- | --- |
| **Azure CLI** | Tested on **2.89.1**. Check with `az version`. Install/update: [aka.ms/installazurecli](https://aka.ms/installazurecli) or `winget install Microsoft.AzureCLI`. |
| **PowerShell** | Tested on **7.6.5**. Windows PowerShell 5.1 also works. Check with `$PSVersionTable.PSVersion`. |

You must also be **signed in** (`az login`) and have **eligible PIM assignments** on the
scopes you're targeting — the script activates existing eligibilities, it can't create them.

> The **Az PowerShell module is *not* required**, and neither is the `Az.Resources` or any
> Azure CLI extension.

One-time `az` configuration is also needed for MFA to work correctly — see
[Authentication](#authentication).

---

## Prerequisites — Bash

The Bash version uses only standard Unix tools plus the Azure CLI.

| Requirement | Notes |
| --- | --- |
| **Azure CLI** | Same as PowerShell. Check with `az version`. |
| **jq** | JSON parsing and generation. Install via `brew install jq` (macOS) or `apt install jq` / `yum install jq` (Linux). |
| **curl** | HTTP requests — included in virtually every Unix-like OS. |
| **bash** | Version 4+ (most systems ship with this). |

Install `jq` on macOS:

```bash
brew install jq
```

On Linux (Debian / Ubuntu):

```bash
sudo apt install jq
```

On Linux (RHEL / CentOS):

```bash
sudo yum install jq
```

---

## Quick start — PowerShell

```powershell
.\Enable-AzPim.ps1 -List     # see what you're eligible for and what's already active
.\Enable-AzPim.ps1           # activate your saved daily set
```

The first activation of the day opens a browser MFA prompt (see [Authentication](#authentication)).
Everything after that runs without prompting until the token ages out.

---

## Examples — PowerShell

```powershell
# Read-only status view - changes nothing
.\Enable-AzPim.ps1 -List

# Activate your saved defaults (no arguments needed)
.\Enable-AzPim.ps1

# Activate specific resource groups for 8 hours
.\Enable-AzPim.ps1 -ResourceGroup az-rg-dev, az-rg-uat -Duration 8h

# Wildcards work
.\Enable-AzPim.ps1 -ResourceGroup 'az-rg-di-*' -Duration 4h

# Activate everything you're eligible for
.\Enable-AzPim.ps1 -All

# Save the current selection as your new defaults
.\Enable-AzPim.ps1 -ResourceGroup 'az-rg-*' -Duration 8h `
                   -Justification 'Daily operational support' `
                   -TicketNumber 'N/A' -TicketSystem 'N/A' -SaveDefaults

# Give the access back
.\Enable-AzPim.ps1 -ResourceGroup az-rg-dev -Deactivate
.\Enable-AzPim.ps1 -All -Deactivate

# Diagnose authentication problems
.\Enable-AzPim.ps1 -ShowToken

# Fire and forget - submit without waiting for provisioning
.\Enable-AzPim.ps1 -NoWait
```

Full built-in help:

```powershell
Get-Help .\Enable-AzPim.ps1 -Full
```

---

## Prerequisites — Bash

| Requirement | Notes |
| --- | --- |
| **Azure CLI** | Same as above — `az login` must have been run. |
| **bash** | 3.2 or newer, so the stock `/bin/bash` on macOS works. |
| **jq** | `brew install jq` / `apt install jq`. |
| **curl** | Present by default on macOS and most Linux distributions. |

## Quick start — Bash

```bash
./Enable-AzPim.sh -List     # see what you're eligible for and what's already active
./Enable-AzPim.sh           # activate your saved daily set
```

The Bash version works identically to the PowerShell script — same parameters, same
behaviour. Differences to be aware of:

- Invoke it as `./Enable-AzPim.sh` instead of `.\Enable-AzPim.ps1`.
- Separate multiple resource groups with **spaces**, not commas
  (`-ResourceGroup az-rg-dev az-rg-uat`).
- Progress and status lines go to **stderr**, so `./Enable-AzPim.sh -List > roles.txt`
  captures just the table.
- It exits **0** when everything succeeded (or was already in the desired state) and
  **1** when any request failed or the script could not run.

### Bash examples (same as PowerShell)

```bash
# Read-only status view - changes nothing
./Enable-AzPim.sh -List

# Activate your saved defaults (no arguments needed)
./Enable-AzPim.sh

# Activate specific resource groups for 8 hours
./Enable-AzPim.sh -ResourceGroup az-rg-dev az-rg-uat -Duration 8h

# Wildcards work (quote to prevent shell expansion)
./Enable-AzPim.sh -ResourceGroup 'az-rg-di-*' -Duration 4h

# Activate everything you're eligible for
./Enable-AzPim.sh -All

# Save the current selection as your new defaults
./Enable-AzPim.sh -ResourceGroup 'az-rg-*' -Duration 8h \
                  -Justification 'Daily operational support' \
                  -TicketNumber 'N/A' -TicketSystem 'N/A' -SaveDefaults

# Give the access back
./Enable-AzPim.sh -ResourceGroup az-rg-dev -Deactivate
./Enable-AzPim.sh -All -Deactivate

# Diagnose authentication problems
./Enable-AzPim.sh -ShowToken

# Fire and forget - submit without waiting for provisioning
./Enable-AzPim.sh -NoWait
```

Full built-in help:

```bash
./Enable-AzPim.sh --help
```

---

## Parameters (both scripts)

| Parameter | Default | Description |
| --- | --- | --- |
| `-ResourceGroup` | from config | One or more RG names. Wildcards supported (`'az-rg-*'`). Positional. |
| `-Role` | `Contributor` | Role to activate. Use `'*'` for every eligible role. |
| `-Duration` | `8h` | `8h`, `90m`, `4.5h`, or raw ISO-8601 (`PT8H`). Capped by the PIM policy. |
| `-Justification` | from config | Recorded in the PIM audit log. |
| `-Subscription` | all | Filter by subscription id or name when an RG name exists in several subs. |
| `-List` | — | Read-only. Shows eligible roles and which are active, with time remaining. |
| `-Deactivate` | — | Deactivate matching roles instead of activating. |
| `-All` | — | Target every eligible assignment (still honours `-Role` / `-Subscription`). |
| `-NoWait` | — | Submit and return immediately instead of polling to completion. |
| `-TimeoutMinutes` | `5` | How long to poll for provisioning. |
| `-TicketNumber` | from config | Required if your PIM policy enforces ticketing. |
| `-TicketSystem` | from config | Required if your PIM policy enforces ticketing. |
| `-SaveDefaults` | — | Save this run's RGs / role / duration / justification / ticket info as defaults. |
| `-ShowToken` | — | Print the current token's `amr` claims and whether MFA is satisfied. |
| `-NoReauth` | — | Don't auto-launch a step-up sign-in; just report the failure. |
| `-TenantId` | — | Tenant to use for the step-up sign-in (multi-tenant accounts). |

### Defaults file

`-SaveDefaults` writes `Enable-AzPim.config.json` next to the script:

```json
{
  "resourceGroups": [
    "az-rg-dev",
    "az-rg-uat",
    "az-rg-prod"
  ],
  "role": "Contributor",
  "duration": "8h",
  "justification": "Daily operational support",
  "ticketNumber": "N/A",
  "ticketSystem": "N/A"
}
```

Edit it by hand any time. Anything you pass on the command line overrides it.

---

## Authentication

This is the part that bites. Azure now **mandates an MFA claim** on the token used to
create, update or delete resources, and PIM additionally enforces an **authentication
context** (`acrs: c1`) with a short freshness window.

Both scripts handle this for you: when Azure rejects a request it reads the claims
challenge out of the error response, runs `az login --claims-challenge ...`, and retries.
You complete **one** browser MFA prompt per run and the rest is automatic.

### One-time CLI configuration (both scripts)

```bash
# The WAM broker silently reuses the Windows device sign-in and produces a token
# WITHOUT the mfa claim, which Azure rejects. Turn it off.
az config set core.enable_broker_on_windows=false

# Stops az from blocking on the interactive subscription picker during scripted logins.
az config set core.login_experience_v2=off
```

Both are global `az` settings, reversible with `=true` / `=on`. (These work regardless
of whether you use the PowerShell or Bash script.)

### Verifying your token (PowerShell)

```powershell
.\Enable-AzPim.ps1 -ShowToken
```

`amr` must include `mfa`:

```text
==> Current az CLI token
    user     : you@example.com
    amr      : pwd, rsa, mfa
    MFA claim present - PIM activation will be accepted.
```

### Verifying your token (Bash)

```bash
./Enable-AzPim.sh -ShowToken
```

Output is identical to the PowerShell version.

### If it still fails (both scripts)

```bash
az config set core.enable_broker_on_windows=false
rm -f "$HOME/.azure/msal_token_cache.bin"
az login
```

> `az logout` alone is **not** enough — it leaves a valid cached access token behind,
> so the next call keeps returning the old claim-less token. The cache file has to go.

---

## Common messages

| Message | Meaning |
| --- | --- |
| `already active (expires in 6h 42m)` | Skipped; nothing to do. |
| `TicketingRule - Ticket information is required` | Pass `-TicketNumber` and `-TicketSystem`. |
| `RequestDisallowedByAzure ... without authenticating through MFA` | Token has no `mfa` claim. See [Authentication](#authentication). |
| `RoleAssignmentRequestAcrsValidationFailed` | Auth context expired. The script re-authenticates and retries automatically. |
| `a request is already pending (likely awaiting approval)` | An approver must action it, or you already submitted it in the portal. |
| `PendingApproval` | Activation needs approval; it won't provision until approved. |
| `still provisioning after 5m` | Usually completes shortly. Re-check with `-List`, or raise `-TimeoutMinutes`. |

---

## Cross-platform notes

The Bash script mirrors every feature of the PowerShell version. Key differences are
handled transparently:

| Feature | PowerShell | Bash |
| --- | --- | --- |
| HTTP calls | `Invoke-RestMethod` | `curl` |
| JSON parsing / generation | `ConvertFrom/To-Json` | `jq` |
| GUID generation | `[guid]::NewGuid()` | `uuidgen` or `/proc/sys/kernel/random/uuid` |
| Date handling | `[datetime]` .NET types | `date -u '+%s'` (Unix epoch) |
| Colours | `-ForegroundColor` | ANSI escape codes (auto-disabled when piped) |

---

## How it works

Uses the ARM PIM REST APIs (api-version `2020-10-01`) with a bearer token from
`az account get-access-token`:

| API | Purpose |
| --- | --- |
| `roleEligibilityScheduleInstances?$filter=asTarget()` | What you may activate |
| `roleAssignmentScheduleInstances?$filter=asTarget()` | What is active right now |
| `roleAssignmentScheduleRequests/{guid}` | `SelfActivate` / `SelfDeactivate` |

Queried at tenant scope, so eligibilities across **all** your subscriptions come back in a
single call — including group-based ones (`memberType: Group`), which is how these are
granted here.
