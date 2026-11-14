# New-CertKitAppProxyIdentity

[![PowerShell Gallery](https://img.shields.io/badge/PowerShell%20Gallery-New--CertKitAppProxyIdentity-blue)](https://www.powershellgallery.com/packages/New-CertKitAppProxyIdentity)
[![Version](https://img.shields.io/powershellgallery/v/New-CertKitAppProxyIdentity?label=Version)](https://www.powershellgallery.com/packages/New-CertKitAppProxyIdentity)
[![License](https://img.shields.io/github/license/richardhicks/certkit?label=License)](https://github.com/richardhicks/certkit/blob/main/LICENSE)

PowerShell script that creates a least-privilege Microsoft Entra identity for [CertKit](https://certkit.io/) to deploy TLS certificates to Microsoft Entra Application Proxy applications.

## Features

- **Least privilege** - CertKit receives a custom Entra role that can only read Application Proxy settings and update the Application Proxy SSL certificate, plus the read-only Microsoft Graph application permission `Application.Read.All`. It does not need Application Administrator, Cloud Application Administrator, or any write permission to app registrations.
- **Safe to run more than once** - Existing objects with the same names are reused, and existing role and permission assignments are not duplicated. Each run creates a new client secret, so the script can also be used to issue a replacement secret.
- **Secret rotation** - With `-RemoveExistingSecrets`, all older client secrets are removed after the new secret is created. Without it, existing secrets are kept and the script warns how many remain.
- **Direct or PIM role assignment** - The custom role is assigned tenant-wide, either directly or, with `-UsePim`, through Privileged Identity Management (PIM) as a permanent active assignment.
- **Secret handling** - The client secret is copied to the clipboard and is never displayed on screen or written to the transcript.
- **Replication-aware** - Requests that can fail while new objects replicate across Entra ID are retried automatically, up to six times at ten-second intervals. Only "not found" replication errors, throttling (429), and service errors (5xx) are retried. Other errors, such as a missing license or insufficient permissions, fail immediately. The PIM role assignment is retried for up to ten minutes, because PIM can take several minutes to recognize a newly created custom role.
- **Preview with -WhatIf** - `-WhatIf` connects to Microsoft Graph and reports the objects that would be created without making any changes.
- **Transcript logging** - Every run, including `-WhatIf` runs, is recorded in a transcript in `$env:ProgramData\RMHCI\PowerShell`.

## Description

[CertKit](https://certkit.io/) can deploy renewed TLS certificates to Microsoft Entra Application Proxy applications using client secret authentication. To do that, it needs an identity in the tenant that can find App Proxy applications and update their certificates. Creating that identity by hand, with a custom role and the correct permissions, involves several steps in the Entra admin center.

`New-CertKitAppProxyIdentity.ps1` creates everything CertKit needs in one run:

1. A custom Entra role, `App Proxy Certificate Manager` by default.
2. A single-tenant app registration, `CertKit App Proxy Deployment` by default, and its service principal.
3. The Microsoft Graph application permission `Application.Read.All`, granted with admin consent, which CertKit uses to find App Proxy applications.
4. A tenant-wide assignment of the custom role to the service principal, made directly or through PIM.
5. A client secret named `CertKit`, copied to the clipboard.
6. Optionally, with `-RemoveExistingSecrets`, the removal of all older client secrets from the app registration.

When it finishes, the script returns the tenant ID and client ID to enter in CertKit, along with the secret expiration date.

### Custom Role Permissions

The custom role grants only the following permissions:

| Permission | Purpose |
|---|---|
| `microsoft.directory/applications/applicationProxy/read` | Read Application Proxy settings of applications |
| `microsoft.directory/applications/applicationProxySslCertificate/update` | Update the Application Proxy SSL certificate of applications |
| `microsoft.directory/connectorGroups/allProperties/read` | Read the properties of Application Proxy connector groups |

## Installation

### PowerShell Gallery

```powershell
Install-Script -Name New-CertKitAppProxyIdentity -Scope CurrentUser
```

On PowerShell 7.4 and later, `Install-PSResource -Name New-CertKitAppProxyIdentity` can be used instead. Update to the latest version with `Update-Script -Name New-CertKitAppProxyIdentity`.

Installed scripts are saved to the PowerShell `Scripts` folder for the selected scope. If that folder is not in your `PATH`, `Install-Script` offers to add it. Once it is, run the script by name:

```powershell
New-CertKitAppProxyIdentity.ps1
```

### Manual Installation

For computers without access to the PowerShell Gallery:

1. On a computer with internet access, save the script with `Save-Script -Name New-CertKitAppProxyIdentity -Path C:\Temp`, or download `New-CertKitAppProxyIdentity.ps1` from [https://github.com/richardhicks/certkit](https://github.com/richardhicks/certkit).
2. Copy `New-CertKitAppProxyIdentity.ps1` to the offline computer.
3. If the file was downloaded from the internet, unblock it before running it:

```powershell
Unblock-File -Path .\New-CertKitAppProxyIdentity.ps1
```

### Prerequisites

The script requires the `Microsoft.Graph.Authentication` module, version 2.0.0 or later. No other Microsoft Graph modules are needed.

```powershell
Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser
```

## Usage

When the script runs, it signs in to Microsoft Graph interactively and requests the delegated scopes `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, and `RoleManagement.ReadWrite.Directory`. It then displays the name and ID of the connected tenant, so it's clear where the objects will be created.

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-TenantId` | String | No | The tenant ID (GUID) or a verified domain name of the tenant to configure. Specify this when your account has access to more than one tenant, such as a guest account in a customer tenant, or when the session is already connected to Microsoft Graph in another tenant. Default: the tenant of the account you sign in with |
| `-DisplayName` | String | No | The display name of the CertKit app registration. Default: `CertKit App Proxy Deployment` |
| `-RoleName` | String | No | The display name of the custom Entra role. Default: `App Proxy Certificate Manager` |
| `-SecretExpirationMonths` | Int | No | The lifetime of the client secret in months (1 to 24). Default: `12` |
| `-UsePim` | Switch | No | Assign the custom role through PIM as a permanent active assignment. Requires Microsoft Entra ID P2 or Microsoft Entra ID Governance. Default: the role is assigned directly. When the custom role is newly created, PIM can take several minutes to recognize it, and the script waits up to 10 minutes |
| `-RemoveExistingSecrets` | Switch | No | Remove all other client secrets from the app registration after the new client secret is created. Use this when rotating the secret or replacing a lost one. CertKit can't authenticate with a removed secret, so update CertKit with the new secret right away. Default: existing secrets are kept |

The script also supports `-WhatIf`, `-Confirm`, and `-Verbose`. Use `-Verbose` to see which objects were created and which existing objects were reused.

### Output

The script returns one object with the following properties:

| Property | Description |
|---|---|
| `TenantName` | The display name of the tenant |
| `TenantId` | The tenant ID |
| `ClientId` | The application (client) ID of the CertKit app registration |
| `SecretExpires` | The expiration date of the client secret |
| `CustomRole` | The display name of the custom Entra role |
| `RoleAssigned` | What this run did: `Directly` or `Through PIM` when the role was assigned, `Already assigned` when an existing active assignment was found, or `Not assigned` when the assignment was skipped, such as with `-WhatIf` |
| `OldSecretsRemoved` | The number of older client secrets removed. Always `0` unless `-RemoveExistingSecrets` is used |

Enter the `TenantId`, the `ClientId`, and the client secret from the clipboard in CertKit.

> **Important:** Paste the client secret into CertKit immediately, then clear the clipboard with `Set-Clipboard -Value $null`. The secret cannot be retrieved again. If it is lost, run the script again to create a new one.

### Examples

```powershell
# Create the CertKit identity with the default names and a 12-month client secret, and assign the custom role directly
.\New-CertKitAppProxyIdentity.ps1

# Create the CertKit identity with a 6-month client secret, and assign the custom role through PIM
.\New-CertKitAppProxyIdentity.ps1 -UsePim -SecretExpirationMonths 6

# Sign in to a specific tenant and create the CertKit identity there, regardless of the account's home tenant
.\New-CertKitAppProxyIdentity.ps1 -TenantId contoso.onmicrosoft.com

# Create a new client secret for the existing CertKit identity and remove all older client secrets
.\New-CertKitAppProxyIdentity.ps1 -RemoveExistingSecrets

# Report the objects that would be created without making any changes
.\New-CertKitAppProxyIdentity.ps1 -WhatIf

# Show which objects were created and which were reused
.\New-CertKitAppProxyIdentity.ps1 -Verbose
```

### Renewing the Client Secret

Run the script again with the same `-DisplayName` and `-RoleName` before the current secret expires. The existing app registration, role, and assignments are reused, and a new client secret is created and copied to the clipboard. By default, older secrets are kept and the script warns how many remain. There are two ways to remove them:

- **Two-step rotation (no downtime)** - Run the script without `-RemoveExistingSecrets`, update the secret in CertKit, then delete the old secrets from the app registration's **Certificates & secrets** page in the Entra admin center. Don't run the script again with `-RemoveExistingSecrets` for this step: it creates another new secret and removes the one CertKit is now using.
- **One-step rotation** - Run the script with `-RemoveExistingSecrets`. All older secrets are removed right after the new secret is created, so CertKit can't authenticate until it's updated with the new secret. This is also the way to replace a secret that was lost.

Older secrets are removed only after the new secret is created successfully. `-RemoveExistingSecrets` removes every other secret on the app registration, including any not created by this script.

### Logging

Each run is recorded in a transcript in `$env:ProgramData\RMHCI\PowerShell`, named `New-CertKitAppProxyIdentity_<yyyyMMdd-HHmmss>.log`. The folder is created if it doesn't exist. The client secret is never written to the transcript.

## Notes

- Existing objects are found by display name. If more than one app registration or custom role has the same name, the first one returned is used. Use unique names with `-DisplayName` and `-RoleName` to avoid this. Names can contain any characters, including apostrophes.
- A built-in Entra role is never reused. If `-RoleName` matches the name of a built-in role, the script stops with an error before making any changes.
- The existing role assignment check looks for active assignments only. When `-UsePim` is used, the PIM assignment is permanent and active, so it is detected on later runs.
- The role is assigned at the tenant scope (`/`), so CertKit can update the certificate of any Application Proxy application in the tenant.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- The `Microsoft.Graph.Authentication` PowerShell module, version 2.0.0 or later.
- Microsoft Entra ID P1 or higher, which is required for Application Proxy and custom roles.
- Microsoft Entra ID P2 or Microsoft Entra ID Governance when `-UsePim` is used.
- An account with at least the Privileged Role Administrator role in the target tenant.

## Author

**Richard M. Hicks** - [Richard M. Hicks Consulting, Inc.](https://www.richardhicks.com/)

- Website: [https://www.richardhicks.com/](https://www.richardhicks.com/)
- GitHub: [https://github.com/richardhicks/certkit](https://github.com/richardhicks/certkit)
- X: [@richardhicks](https://x.com/richardhicks)

## License

This project is licensed under the [MIT License](https://github.com/richardhicks/certkit/blob/main/LICENSE).

## Copyright

&copy; 2026 Richard M. Hicks Consulting, Inc.
