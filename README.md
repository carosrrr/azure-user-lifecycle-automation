# Azure User Lifecycle Automation

End-to-end onboarding and offboarding automation for both **cloud-only (Entra ID)** and **hybrid (On-Premises AD + AAD Connect)** environments. Integrates with HR platforms via Azure Automation Runbooks and webhooks.

## Architecture

This project provides two parallel approaches depending on your infrastructure:

```
                            ┌─────────────────────────────────────────────┐
                            │           HR Platform (BambooHR)            │
                            └──────────────────┬──────────────────────────┘
                                               │ API / Zapier
                                               ▼
                            ┌─────────────────────────────────────────────┐
                            │         Azure Automation Runbook            │
                            │              (Webhook trigger)              │
                            └─────────┬───────────────────┬───────────────┘
                                      │                   │
                         Cloud-Only   │                   │  Hybrid
                                      ▼                   ▼
                            ┌──────────────┐    ┌───────────────────┐
                            │  Entra ID    │    │  On-Prem AD       │
                            │  (Graph API) │    │  (RSAT + ADSync)  │
                            └──────────────┘    └─────────┬─────────┘
                                                          │ Delta Sync
                                                          ▼
                                                ┌──────────────────┐
                                                │    Entra ID      │
                                                │  (synced users)  │
                                                └──────────────────┘
```

### Cloud-Only (`scripts/cloud/`)
Uses **Microsoft Graph API** to manage users directly in Entra ID. Best for organizations that are fully cloud-native with no on-premises Active Directory.

### Hybrid / On-Premises (`scripts/on-prem/`)
Uses **Active Directory PowerShell module** to create/disable users in on-prem AD, then triggers **AAD Connect delta sync** to reflect changes in Entra ID. Designed to run on a **Hybrid Runbook Worker** with AD RSAT installed.

## Results (Real-World Impact)

This automation approach was implemented in a production environment and achieved:

| Metric | Before | After |
|--------|--------|-------|
| Human errors in account management | Baseline | **-80%** |
| Offboarding coverage | ~70% | **100%** |
| Onboarding time per user | ~45 min | **~5 min** |
| Orphaned active accounts | Common | **Zero** |

## Project Structure

```
azure-user-lifecycle-automation/
├── scripts/
│   ├── cloud/                              # Cloud-only (Entra ID + Graph API)
│   │   ├── New-UserOnboarding.ps1          # Create user in Entra ID
│   │   ├── Remove-UserOffboarding.ps1      # Disable user in Entra ID
│   │   └── helpers/
│   │       ├── Connect-GraphHelper.ps1     # Graph API authentication
│   │       ├── Write-Report.ps1            # Report generation
│   │       └── Send-Notification.ps1       # Email notifications
│   │
│   └── on-prem/                            # Hybrid (On-Prem AD + AAD Connect)
│       ├── Create-OnPremADUser.ps1         # Create user in on-prem AD via webhook
│       └── Disable-OnPremADUser.ps1        # Disable user in on-prem AD via webhook
│
├── config/
│   ├── config.sample.json                  # Cloud scripts configuration
│   ├── on-prem-config.sample.json          # On-prem scripts configuration
│   └── license-skus.md                     # M365 license SKU reference
│
├── data/
│   ├── new_hires.csv                       # Sample bulk onboarding CSV
│   └── terminated_users.csv                # Sample bulk offboarding CSV
│
├── docs/
│   ├── cloud-setup.md                      # Cloud-only setup guide
│   ├── on-prem-setup.md                    # Hybrid setup guide
│   └── hr-integration.md                   # HR platform integration (Zapier + BambooHR)
│
├── reports/                                # Generated reports (gitignored)
├── .gitignore
├── LICENSE
└── README.md
```

## Quick Start

### Cloud-Only

```powershell
# Install Graph modules
Install-Module Microsoft.Graph -Scope CurrentUser

# Single user onboarding
.\scripts\cloud\New-UserOnboarding.ps1 -FirstName "John" -LastName "Doe" -Department "Engineering" -JobTitle "Developer"

# Bulk onboarding
.\scripts\cloud\New-UserOnboarding.ps1 -CsvPath ".\data\new_hires.csv"

# Offboarding
.\scripts\cloud\Remove-UserOffboarding.ps1 -UserPrincipalName "john.doe@company.com"
```

### On-Premises (via Webhook)

The on-prem scripts are designed to run as Azure Automation Runbooks triggered by webhooks. Send a POST request:

**Onboarding:**
```json
POST https://your-webhook-url.azure-automation.net/webhooks?token=xxx

{
    "firstName": "John",
    "lastName": "Doe",
    "userPrincipalName": "john.doe@company.com",
    "jobTitle": "Software Engineer",
    "department": "Engineering",
    "groups": ["grp_ssl_users", "grp_engineering"],
    "autoGeneratePassword": true,
    "returnPassword": true
}
```

**Offboarding:**
```json
POST https://your-webhook-url.azure-automation.net/webhooks?token=xxx

{
    "workEmail": "john.doe@company.com",
    "reason": "BambooHR status -> Inactive"
}
```

## Key Features

### Onboarding
| Feature | Cloud | On-Prem |
|---------|:-----:|:-------:|
| Create user account | Entra ID | Active Directory |
| Auto-generate secure password | ✅ | ✅ |
| Assign to groups | Graph API | AD Groups |
| Set manager | ✅ | ✅ |
| Assign M365 license | ✅ | — |
| Idempotency (skip if exists) | ✅ | ✅ |
| Bulk via CSV | ✅ | — |
| Webhook trigger | ✅ | ✅ |
| Send notification email | ✅ | — |
| Return temp password in response | — | ✅ |

### Offboarding
| Feature | Cloud | On-Prem |
|---------|:-----:|:-------:|
| Disable account | ✅ | ✅ |
| Revoke all sessions | ✅ | — |
| Remove group memberships | ✅ | ✅ |
| Remove licenses | ✅ | — |
| Reset password | ✅ | — |
| Clear manager | — | ✅ |
| Move to Disabled OU | — | ✅ |
| Convert mailbox to shared | ✅ | — |
| Trigger AAD Connect sync | — | ✅ |
| Confirmation for bulk ops | ✅ | — |

## HR Platform Integration

The recommended production flow uses **Zapier** (or similar) as middleware:

```
BambooHR "New Hire" event
  → Zapier catches the trigger
  → Zapier sends POST to Azure Automation webhook
  → Runbook executes Create-OnPremADUser.ps1 (or cloud equivalent)
  → User is created automatically

BambooHR "Status → Inactive" event
  → Zapier catches the trigger
  → Zapier sends POST to Azure Automation webhook
  → Runbook executes Disable-OnPremADUser.ps1
  → Account disabled, groups removed, moved to Disabled OU
  → AAD Connect syncs changes to Entra ID
```

See [docs/hr-integration.md](docs/hr-integration.md) for detailed setup.

## Prerequisites

### Cloud-Only
- PowerShell 7.x+
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph/installation)
- Entra ID admin permissions (User Administrator, License Administrator, Groups Administrator)

### On-Premises
- Windows PowerShell 5.1 (Hybrid Runbook Worker)
- AD RSAT (Remote Server Administration Tools)
- Azure Automation Account with Hybrid Worker configured
- AAD Connect installed (for sync to Entra ID)

## Security Considerations

- Passwords generated with cryptographic RNG (`RandomNumberGenerator`)
- Config files with secrets are gitignored
- On-prem scripts validate all inputs before execution
- Idempotency checks prevent duplicate account creation
- Offboarding resets passwords and revokes sessions immediately
- All actions logged in JSON reports for audit compliance

## License

MIT License — see [LICENSE](LICENSE) for details.

## Author

**Caio Santana** — IT Infrastructure & Cloud Engineer
- [LinkedIn](https://www.linkedin.com/in/caiosantana/)
- [GitHub](https://github.com/carosrrr)
- [Portfolio](https://carosrrr.github.io)
