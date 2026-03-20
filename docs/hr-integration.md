# HR Platform Integration Guide

This guide explains how to connect your HR platform (e.g., BambooHR) to Azure Automation Runbooks using Zapier as middleware, enabling fully automated user lifecycle management.

## Architecture

```
┌──────────────┐   Event trigger   ┌──────────┐   Webhook POST   ┌─────────────────────┐
│  BambooHR    │ ───────────────── │  Zapier  │ ──────────────── │ Azure Automation     │
│  (HR source) │                   │  (glue)  │                  │ Runbook (on Worker)  │
└──────────────┘                   └──────────┘                  └──────────┬────────────┘
                                                                           │
                                                      ┌────────────────────┴─────────────────┐
                                                      │                                      │
                                              Cloud-Only path                       Hybrid path
                                                      │                                      │
                                                      ▼                                      ▼
                                              ┌──────────────┐                    ┌─────────────────┐
                                              │  Entra ID    │                    │  On-Prem AD     │
                                              │  (Graph API) │                    │  + AAD Connect  │
                                              └──────────────┘                    └─────────────────┘
```

## Step 1: Set Up Azure Automation

### Create an Automation Account

1. In Azure Portal, go to **Automation Accounts** > **Create**
2. Enable **System-assigned managed identity**
3. For on-prem scripts: set up a **Hybrid Runbook Worker** on a domain-joined Windows server with AD RSAT installed

### Import the Runbook

1. Go to **Runbooks** > **Create a runbook**
2. For on-prem onboarding: import `Create-OnPremADUser.ps1`
3. For on-prem offboarding: import `Disable-OnPremADUser.ps1`
4. For cloud-only: import `New-UserOnboarding.ps1` or `Remove-UserOffboarding.ps1`
5. **Publish** the runbook

### Create a Webhook

1. Open the published Runbook
2. Go to **Webhooks** > **Add Webhook**
3. Name it (e.g., `bamboohr-onboarding`)
4. **Copy the URL immediately** — it is shown only once
5. Set an appropriate expiration date

> **Security tip:** Store the webhook URL securely. Rotate it periodically.

## Step 2: Configure BambooHR

BambooHR supports webhooks natively, but Zapier provides more flexibility for data mapping.

### Data you'll need from BambooHR

**For onboarding:**
- First Name, Last Name
- Work Email
- Job Title, Department
- Manager (name or email)
- Start Date

**For offboarding:**
- Work Email
- Employment Status change (Active → Inactive)

## Step 3: Set Up Zapier

### Onboarding Zap

1. **Trigger:** BambooHR > New Employee
2. **Action:** Webhooks by Zapier > POST

Configure the POST action:
- **URL:** Your Azure Automation webhook URL
- **Payload Type:** JSON
- **Data:**

| Key | Value (from BambooHR) |
|-----|-----------------------|
| `firstName` | First Name |
| `lastName` | Last Name |
| `userPrincipalName` | Work Email |
| `jobTitle` | Job Title |
| `department` | Department |
| `manager` | Supervisor (name) |
| `groups` | (hardcode or map from department) |
| `autoGeneratePassword` | `true` |
| `returnPassword` | `true` |

### Offboarding Zap

1. **Trigger:** BambooHR > Updated Employee (filter: Employment Status = Inactive)
2. **Action:** Webhooks by Zapier > POST

Configure the POST action:
- **URL:** Your Azure Automation webhook URL (offboarding)
- **Payload Type:** JSON
- **Data:**

| Key | Value |
|-----|-------|
| `workEmail` | Work Email from BambooHR |
| `reason` | `BambooHR status -> Inactive` |

## Step 4: Test the Flow

### Onboarding Test

1. Create a test employee in BambooHR (use a test domain email)
2. Watch the Zapier trigger fire
3. Check the Runbook job output in Azure Portal > Automation Account > Jobs
4. Verify the user was created in AD / Entra ID

### Offboarding Test

1. Change the test employee's status to Inactive in BambooHR
2. Verify the account was disabled, groups removed, and moved to Disabled OU
3. If using AAD Connect, verify the sync reflected in Entra ID

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Zapier doesn't fire | Check the BambooHR trigger filter conditions |
| Webhook returns 404 | Webhook may have expired — create a new one |
| User not created | Check Runbook job output for detailed error JSON |
| Group not found | Verify group names match exactly (case-sensitive) |
| AAD Connect sync fails | Ensure ADSync module is installed on the Hybrid Worker |
| Duplicate user warning | Script has idempotency — this is expected behavior if user already exists |

## Security Considerations

- **Never expose webhook URLs** in source code or logs
- Use Zapier's **filter steps** to prevent accidental triggers
- Use **test employees** before deploying to production
- Set up **Azure Monitor alerts** for failed Runbook jobs
- Rotate webhook URLs every 90 days
- Consider IP allowlisting on the Automation Account if Zapier publishes their IP ranges

## Alternative Middleware

While this guide uses Zapier, the same approach works with:
- **Power Automate** (Microsoft's native option)
- **Make** (formerly Integromat)
- **n8n** (self-hosted, open source)
- **Direct API calls** from BambooHR webhooks (no middleware needed if your HR platform supports custom webhooks)

## Author

**Caio Santana** — IT Infrastructure & Cloud Engineer
- [LinkedIn](https://www.linkedin.com/in/caiosantana/)
- [GitHub](https://github.com/carosrrr)
