# Changelog

All notable changes to `New-CertKitAppProxyIdentity.ps1` and its companion script, `Remove-CertKitAppProxyIdentity.ps1`, are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.4] - November 23, 2026

### Added

- Managed identity authentication. The new `-ManagedIdentityId` parameter takes the object (principal) ID or client ID of an existing user-assigned or system-assigned managed identity attached to the server running the CertKit agent. The script grants the managed identity the `Application.Read.All` permission and assigns it the custom role, directly or through PIM. No app registration or client secret is created.
- The script verifies that the identity specified with `-ManagedIdentityId` is a managed identity, and stops with an error if its service principal is any other type.
- A `ManagedIdentity` property in the output when managed identity authentication is used.

### Changed

- The script now has two parameter sets: `ClientSecret` (default) and `ManagedIdentity`. `-DisplayName`, `-SecretExpirationMonths`, and `-RemoveExistingSecrets` apply to client secret authentication only and can't be combined with `-ManagedIdentityId`.
- With managed identity authentication, the script requests the delegated scope `Application.Read.All` instead of `Application.ReadWrite.All`, because it doesn't create an app registration.
- With managed identity authentication, the output omits `SecretExpires` and `OldSecretsRemoved`, and `ClientId` is the managed identity's client ID.
- The custom role is looked up, and checked against built-in role names, before the app registration is created or the managed identity is looked up. An invalid `-RoleName` stops the script before any changes are made, for both authentication methods.

### Fixed

- In PowerShell 7, `-WhatIf` runs now stop the transcript. Previously, `-WhatIf` also applied to `Stop-Transcript`, which left the transcript running.

### Remove-CertKitAppProxyIdentity.ps1 1.2

#### Added

- Managed identity support with the `-ManagedIdentityId` parameter. The script removes the custom role assignment and the `Application.Read.All` permission from the managed identity, but doesn't delete the managed identity, which is an Azure resource.
- The `-KeepRole` switch, which keeps the custom Entra role.
- `Identity` and `PermissionRemoved` properties in the output.

#### Changed

- The custom role is no longer deleted while it has active or eligible assignments to another identity, such as when client secret and managed identity deployments share the role. The script warns instead.
- Only assignments of the custom role are removed from the identity. Previously, every directory role assigned to the CertKit service principal was removed. That made no difference for a dedicated app registration, but a managed identity can hold other roles.
- `-DisplayName` and `-KeepDeletedApp` now apply to client secret authentication only.
- If `-RoleName` matches the name of a built-in Entra role, the script stops with an error before making any changes.

#### Fixed

- App registration and role names that contain apostrophes are now found correctly.
- In PowerShell 7, `-WhatIf` runs now stop the transcript. Previously, `-WhatIf` also applied to `Stop-Transcript`, which left the transcript running.
