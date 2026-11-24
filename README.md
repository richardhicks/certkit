# New-CertKitAppProxyIdentity

[![PowerShell Gallery](https://img.shields.io/badge/PowerShell%20Gallery-New--CertKitAppProxyIdentity-blue)](https://www.powershellgallery.com/packages/New-CertKitAppProxyIdentity)
[![Version](https://img.shields.io/powershellgallery/v/New-CertKitAppProxyIdentity?label=Version)](https://www.powershellgallery.com/packages/New-CertKitAppProxyIdentity)
[![License](https://img.shields.io/github/license/richardhicks/certkit?label=License)](https://github.com/richardhicks/certkit/blob/main/LICENSE)

PowerShell script that creates or configures a least-privilege Microsoft Entra identity for [CertKit](https://certkit.io/) to deploy TLS certificates to Microsoft Entra Application Proxy applications, using either client secret or managed identity authentication. A companion script, `Remove-CertKitAppProxyIdentity.ps1`, removes everything it configures.

## Features

- **Least privilege** - CertKit receives a custom Entra role that can only read Application Proxy settings and update the Application Proxy SSL certificate, plus the read-only Microsoft Graph application permission `Application.Read.All`. It does not need Application Administrator, Cloud Application Administrator, or any write permission to app registrations.
- **Client secret or managed identity** - By default, the script creates a dedicated app registration and client secret for CertKit. With `-ManagedIdentityId`, it instead grants the same permissions to an existing managed identity attached to the server running the CertKit agent, so there is no secret to store or rotate.
- **Safe to run more than once** - Existing objects with the same names are reused, and existing role and permission assignments are not duplicated. With client secret authentication, each run creates a new client secret, so the script can also be used to issue a replacement secret.
- **Secret rotation** - With `-RemoveExistingSecrets`, all older client secrets are removed after the new secret is created. Without it, existing secrets are kept and the script warns how many remain.
- **Direct or PIM role assignment** - The custom role is assigned tenant-wide, either directly or, with `-UsePim`, through Privileged Identity Management (PIM) as a permanent active assignment.
- **Secret handling** - The client secret is copied to the clipboard and is never displayed on screen or written to the transcript.
- **Replication-aware** - Requests that can fail while new objects replicate across Entra ID are retried automatically, up to six times at ten-second intervals. Only "not found" replication errors, throttling (429), and service errors (5xx) are retried. Other errors, such as a missing license or insufficient permissions, fail immediately. The PIM role assignment is retried for up to ten minutes, because PIM can take several minutes to recognize a newly created custom role.
- **Preview with -WhatIf** - `-WhatIf` connects to Microsoft Graph and reports the objects that would be created without making any changes.
- **Clean removal** - `Remove-CertKitAppProxyIdentity.ps1` removes the role assignments, permission, app registration, and custom role, and keeps the custom role when another identity still uses it.
- **Transcript logging** - Every run of either script, including `-WhatIf` runs, is recorded in a transcript in `$env:ProgramData\RMHCI\PowerShell`.

## Description

[CertKit](https://certkit.io/) can deploy renewed TLS certificates to Microsoft Entra Application Proxy applications. To do that, it needs an identity in the tenant that can find App Proxy applications and update their certificates. Configuring that identity by hand, with a custom role and the correct permissions, involves several steps in the Entra admin center.

`New-CertKitAppProxyIdentity.ps1` configures everything CertKit needs in one run. It supports two authentication methods.

### Client Secret Authentication (Default)

1. A custom Entra role, `App Proxy Certificate Manager` by default.
2. A single-tenant app registration, `CertKit App Proxy Deployment` by default, and its service principal.
3. The Microsoft Graph application permission `Application.Read.All`, granted with admin consent, which CertKit uses to find App Proxy applications.
4. A tenant-wide assignment of the custom role to the service principal, made directly or through PIM.
5. A client secret named `CertKit`, copied to the clipboard.
6. Optionally, with `-RemoveExistingSecrets`, the removal of all older client secrets from the app registration.

When it finishes, the script returns the tenant ID and client ID to enter in CertKit, along with the secret expiration date.

### Managed Identity Authentication

With `-ManagedIdentityId`, the script uses an existing user-assigned or system-assigned managed identity attached to the server running the CertKit agent. The script doesn't create the managed identity, which is an Azure resource, and doesn't create an app registration or client secret.

1. A custom Entra role, `App Proxy Certificate Manager` by default.
2. The Microsoft Graph application permission `Application.Read.All`, granted to the managed identity.
3. A tenant-wide assignment of the custom role to the managed identity, made directly or through PIM.

The managed identity can be specified by its object (principal) ID or its client ID. Both are shown on the managed identity's **Overview** page in the Azure portal. The script verifies that the service principal it finds is a managed identity, and stops with an error if it isn't, so the permissions are never granted to another type of identity.

When it finishes, the script returns the tenant ID and the managed identity's client ID to enter in the CertKit deployment.

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

`Remove-CertKitAppProxyIdentity.ps1` isn't published to the PowerShell Gallery. Download it from [https://github.com/richardhicks/certkit](https://github.com/richardhicks/certkit).

### Manual Installation

For computers without access to the PowerShell Gallery:

1. On a computer with internet access, save the script with `Save-Script -Name New-CertKitAppProxyIdentity -Path C:\Temp`, or download `New-CertKitAppProxyIdentity.ps1` from [https://github.com/richardhicks/certkit](https://github.com/richardhicks/certkit).
2. Copy `New-CertKitAppProxyIdentity.ps1` to the offline computer.
3. If the file was downloaded from the internet, unblock it before running it:

```powershell
Unblock-File -Path .\New-CertKitAppProxyIdentity.ps1
```

### Prerequisites

The scripts require the `Microsoft.Graph.Authentication` module, version 2.0.0 or later. No other Microsoft Graph modules are needed.

```powershell
Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser
```

For managed identity authentication, the module must also be installed for all users on the server running the CertKit agent, because the agent runs as Local System:

```powershell
Install-Module -Name Microsoft.Graph.Authentication -Scope AllUsers
```

## Usage

When the script runs, it signs in to Microsoft Graph interactively and requests the following delegated scopes. It then displays the name and ID of the connected tenant, so it's clear where the objects will be created.

| Authentication method | Delegated scopes |
|---|---|
| Client secret | `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `RoleManagement.ReadWrite.Directory` |
| Managed identity | `Application.Read.All`, `AppRoleAssignment.ReadWrite.All`, `RoleManagement.ReadWrite.Directory` |

The managed identity method doesn't create an app registration, so it requests only read access to applications.

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-TenantId` | String | No | The tenant ID (GUID) or a verified domain name of the tenant to configure. Specify this when your account has access to more than one tenant, such as a guest account in a customer tenant, or when the session is already connected to Microsoft Graph in another tenant. Default: the tenant of the account you sign in with |
| `-DisplayName` | String | No | Client secret only. The display name of the CertKit app registration. Default: `CertKit App Proxy Deployment` |
| `-ManagedIdentityId` | String (GUID) | Yes, for managed identity | The object (principal) ID or client ID of an existing managed identity. Selects managed identity authentication. The managed identity must already exist and be attached to the server running the CertKit agent |
| `-RoleName` | String | No | The display name of the custom Entra role. Default: `App Proxy Certificate Manager` |
| `-SecretExpirationMonths` | Int | No | Client secret only. The lifetime of the client secret in months (1 to 24). Default: `12` |
| `-UsePim` | Switch | No | Assign the custom role through PIM as a permanent active assignment. Requires Microsoft Entra ID P2 or Microsoft Entra ID Governance. Default: the role is assigned directly. When the custom role is newly created, PIM can take several minutes to recognize it, and the script waits up to 10 minutes |
| `-RemoveExistingSecrets` | Switch | No | Client secret only. Remove all other client secrets from the app registration after the new client secret is created. Use this when rotating the secret or replacing a lost one. CertKit can't authenticate with a removed secret, so update CertKit with the new secret right away. Default: existing secrets are kept |

`-DisplayName`, `-SecretExpirationMonths`, and `-RemoveExistingSecrets` can't be combined with `-ManagedIdentityId`.

The script also supports `-WhatIf`, `-Confirm`, and `-Verbose`. Use `-Verbose` to see which objects were created and which existing objects were reused.

### Output

The script returns one object. Its properties depend on the authentication method.

| Property | Client secret | Managed identity | Description |
|---|---|---|---|
| `TenantName` | Yes | Yes | The display name of the tenant |
| `TenantId` | Yes | Yes | The tenant ID |
| `ManagedIdentity` | | Yes | The display name of the managed identity |
| `ClientId` | Yes | Yes | The application (client) ID of the CertKit app registration, or the client ID of the managed identity |
| `SecretExpires` | Yes | | The expiration date of the client secret |
| `CustomRole` | Yes | Yes | The display name of the custom Entra role |
| `RoleAssigned` | Yes | Yes | What this run did: `Directly` or `Through PIM` when the role was assigned, `Already assigned` when an existing active assignment was found, or `Not assigned` when the assignment was skipped, such as with `-WhatIf` |
| `OldSecretsRemoved` | Yes | | The number of older client secrets removed. Always `0` unless `-RemoveExistingSecrets` is used |

For client secret authentication, enter the `TenantId`, the `ClientId`, and the client secret from the clipboard in CertKit.

> **Important:** Paste the client secret into CertKit immediately, then clear the clipboard with `Set-Clipboard -Value $null`. The secret cannot be retrieved again. If it is lost, run the script again to create a new one.

For managed identity authentication, enter the `TenantId` and the managed identity's `ClientId` in the CertKit deployment.

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

# Configure an existing managed identity, identified by its client ID, and assign the custom role through PIM
.\New-CertKitAppProxyIdentity.ps1 -ManagedIdentityId e7ceec4e-6431-429a-8a17-c6127b14d3ef -UsePim

# Report the objects that would be created without making any changes
.\New-CertKitAppProxyIdentity.ps1 -WhatIf

# Show which objects were created and which were reused
.\New-CertKitAppProxyIdentity.ps1 -Verbose
```

### Renewing the Client Secret

This section applies to client secret authentication only. A managed identity has no secret to renew.

Run the script again with the same `-DisplayName` and `-RoleName` before the current secret expires. The existing app registration, role, and assignments are reused, and a new client secret is created and copied to the clipboard. By default, older secrets are kept and the script warns how many remain. There are two ways to remove them:

- **Two-step rotation (no downtime)** - Run the script without `-RemoveExistingSecrets`, update the secret in CertKit, then delete the old secrets from the app registration's **Certificates & secrets** page in the Entra admin center. Don't run the script again with `-RemoveExistingSecrets` for this step: it creates another new secret and removes the one CertKit is now using.
- **One-step rotation** - Run the script with `-RemoveExistingSecrets`. All older secrets are removed right after the new secret is created, so CertKit can't authenticate until it's updated with the new secret. This is also the way to replace a secret that was lost.

Older secrets are removed only after the new secret is created successfully. `-RemoveExistingSecrets` removes every other secret on the app registration, including any not created by this script.

### Switching to a Managed Identity

To move an existing CertKit deployment from a client secret to a managed identity:

1. Run `New-CertKitAppProxyIdentity.ps1 -ManagedIdentityId <id>` with the same `-RoleName`. The existing custom role is reused.
2. Update the CertKit deployment to use the managed identity.
3. Run `Remove-CertKitAppProxyIdentity.ps1 -KeepRole` to delete the old app registration. Even without `-KeepRole`, the role isn't deleted while the managed identity still uses it.

### Logging

Each run is recorded in a transcript in `$env:ProgramData\RMHCI\PowerShell`, named `New-CertKitAppProxyIdentity_<yyyyMMdd-HHmmss>.log`. The folder is created if it doesn't exist. The client secret is never written to the transcript.

## Removing the CertKit Identity

`Remove-CertKitAppProxyIdentity.ps1` removes what `New-CertKitAppProxyIdentity.ps1` configures, returning the tenant to a clean state for testing or decommissioning. After it runs, CertKit can no longer deploy certificates to Application Proxy until a new identity is configured and the CertKit deployment is updated.

For client secret authentication (default), the script:

1. Removes the custom role assignment, whether it was made through PIM or directly.
2. Deletes the CertKit app registration, which also removes its service principal, the `Application.Read.All` permission grant, and all client secrets.
3. Permanently deletes the app registration from the Entra ID recycle bin, unless `-KeepDeletedApp` is used.
4. Deletes the custom role, unless `-KeepRole` is used or the role is still assigned to another identity.

For managed identity authentication (`-ManagedIdentityId`), the script:

1. Removes the custom role assignment, whether it was made through PIM or directly.
2. Removes the `Application.Read.All` permission grant from the managed identity.
3. Deletes the custom role, unless `-KeepRole` is used or the role is still assigned to another identity.

The managed identity itself isn't deleted, because it's an Azure resource. Delete it in the Azure portal if it's no longer needed.

Only assignments of the custom role are removed. Other Entra roles assigned to the identity, such as roles a managed identity holds for other purposes, aren't changed.

PIM doesn't allow an active assignment to be removed until 5 minutes after it starts. If the PIM assignment is newer than that, the script waits and retries for up to 6 minutes.

The script prompts for confirmation before each removal. Use `-Confirm:$false` to skip the prompts, or `-WhatIf` to see what would be removed without making changes. It is safe to run more than once: objects that no longer exist are skipped. If more than one app registration or custom role matches the specified names, the script stops without making any changes.

The custom role is kept, with a warning, when it has active or eligible assignments to any other identity, such as when client secret and managed identity deployments share the role. Deleting the role is retried up to six times at ten-second intervals while the assignment removal replicates.

### Removal Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-TenantId` | String | No | The tenant ID (GUID) or a verified domain name of the tenant to clean up. Default: the tenant of the account you sign in with |
| `-DisplayName` | String | No | Client secret only. The display name of the CertKit app registration to remove. Default: `CertKit App Proxy Deployment` |
| `-ManagedIdentityId` | String (GUID) | Yes, for managed identity | The object (principal) ID or client ID of the managed identity to remove CertKit's permissions from. The managed identity itself isn't deleted |
| `-RoleName` | String | No | The display name of the custom Entra role to remove. Default: `App Proxy Certificate Manager` |
| `-KeepDeletedApp` | Switch | No | Client secret only. Leave the deleted app registration in the Entra ID recycle bin, where it can be restored for 30 days. Default: the app registration is permanently deleted |
| `-KeepRole` | Switch | No | Keep the custom Entra role. Default: the role is deleted unless it's still assigned to another identity |

The script signs in with the delegated scopes `Application.ReadWrite.All` and `RoleManagement.ReadWrite.Directory` for client secret authentication, or `Application.Read.All`, `AppRoleAssignment.ReadWrite.All`, and `RoleManagement.ReadWrite.Directory` for managed identity authentication.

### Removal Output

| Property | Description |
|---|---|
| `TenantName` | The display name of the tenant |
| `TenantId` | The tenant ID |
| `Identity` | The display name of the app registration or managed identity |
| `RoleAssignmentsRemoved` | The number of role assignments removed |
| `PermissionRemoved` | Whether the `Application.Read.All` permission was removed |
| `AppRegistrationDeleted` | Whether the app registration was deleted |
| `AppRegistrationPurged` | Whether the app registration was permanently deleted from the recycle bin |
| `CustomRoleDeleted` | Whether the custom role was deleted |

### Removal Examples

```powershell
# Remove the CertKit identity, custom role, and role assignments that use the default names, prompting before each removal
.\Remove-CertKitAppProxyIdentity.ps1

# Sign in to a specific tenant and remove everything without prompting
.\Remove-CertKitAppProxyIdentity.ps1 -TenantId contoso.onmicrosoft.com -Confirm:$false

# Show what would be removed without making any changes
.\Remove-CertKitAppProxyIdentity.ps1 -WhatIf

# Remove the client secret identity but keep the custom role, such as after switching CertKit to a managed identity
.\Remove-CertKitAppProxyIdentity.ps1 -KeepRole

# Remove the custom role assignment and Application.Read.All permission from a managed identity
.\Remove-CertKitAppProxyIdentity.ps1 -ManagedIdentityId e7ceec4e-6431-429a-8a17-c6127b14d3ef
```

Each run is recorded in a transcript in `$env:ProgramData\RMHCI\PowerShell`, named `Remove-CertKitAppProxyIdentity_<yyyyMMdd-HHmmss>.log`.

## Notes

- Existing objects are found by display name. If more than one app registration or custom role has the same name, `New-CertKitAppProxyIdentity.ps1` uses the first one returned, and `Remove-CertKitAppProxyIdentity.ps1` stops without making changes. Use unique names with `-DisplayName` and `-RoleName` to avoid this. Names can contain any characters, including apostrophes.
- A built-in Entra role is never used. If `-RoleName` matches the name of a built-in role, either script stops with an error before making any changes.
- The existing role assignment check looks for active assignments only. When `-UsePim` is used, the PIM assignment is permanent and active, so it is detected on later runs.
- The role is assigned at the tenant scope (`/`), so CertKit can update the certificate of any Application Proxy application in the tenant.
- Client secret and managed identity deployments can share the same custom role.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- The `Microsoft.Graph.Authentication` PowerShell module, version 2.0.0 or later.
- Microsoft Entra ID P1 or higher, which is required for Application Proxy and custom roles.
- Microsoft Entra ID P2 or Microsoft Entra ID Governance when `-UsePim` is used.
- An account with at least the Privileged Role Administrator role in the target tenant.
- For managed identity authentication, an existing user-assigned or system-assigned managed identity attached to the server running the CertKit agent, and the `Microsoft.Graph.Authentication` module installed for all users on that server.

## Author

**Richard M. Hicks** - [Richard M. Hicks Consulting, Inc.](https://www.richardhicks.com/)

- Website: [https://www.richardhicks.com/](https://www.richardhicks.com/)
- GitHub: [https://github.com/richardhicks/certkit](https://github.com/richardhicks/certkit)
- X: [@richardhicks](https://x.com/richardhicks)

## License

This project is licensed under the [MIT License](https://github.com/richardhicks/certkit/blob/main/LICENSE).

## Copyright

&copy; 2026 Richard M. Hicks Consulting, Inc.
