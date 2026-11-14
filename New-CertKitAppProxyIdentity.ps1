<#PSScriptInfo

.VERSION 1.3

.GUID a9e0f308-5a4c-4ee6-a6f9-452dc867ee72

.AUTHOR Richard Hicks

.COMPANYNAME Richard M. Hicks Consulting, Inc.

.COPYRIGHT Copyright (C) 2026 Richard M. Hicks Consulting, Inc. All Rights Reserved.

.LICENSE Licensed under the MIT License. See LICENSE file in the project root for full license information.

.LICENSEURI https://github.com/richardhicks/certkit/blob/main/LICENSE

.PROJECTURI https://github.com/richardhicks/certkit

.TAGS CertKit, Entra, EntraID, AppProxy, ApplicationProxy, Certificate, TLS, SSL, MicrosoftGraph, Graph, ServicePrincipal, PIM, LeastPrivilege

#>

<#

.SYNOPSIS
    Creates a least-privilege Microsoft Entra identity for CertKit to deploy TLS certificates to Entra Application Proxy applications.

.DESCRIPTION
    This script creates everything CertKit needs to deploy certificates to Microsoft Entra Application Proxy applications using client secret authentication, following least privilege.

    - A dedicated app registration and service principal for CertKit.
    - A custom Entra role that can only read Application Proxy settings and update the Application Proxy SSL certificate.
    - The read-only Microsoft Graph application permission Application.Read.All, used by CertKit to find App Proxy applications.
    - A tenant-wide assignment of the custom role to the CertKit service principal, made directly or through Privileged Identity Management (PIM).
    - A client secret, which is copied to the clipboard and never displayed on screen.

    The script is safe to run more than once. Existing objects with the same names are reused, and existing role and permission assignments are not duplicated. A new client secret is created on every run. Use -RemoveExistingSecrets to remove older client secrets after the new one is created.

.PARAMETER TenantId
    The tenant ID (GUID) or a verified domain name of the Microsoft Entra tenant to configure. Optional. If omitted, the script uses the tenant of the account you sign in with. Specify this parameter when your account has access to more than one tenant, such as a guest account in a customer tenant, or when the PowerShell session is already connected to Microsoft Graph in another tenant.

.PARAMETER DisplayName
    The display name of the CertKit app registration. The default is 'CertKit App Proxy Deployment'.

.PARAMETER RoleName
    The display name of the custom Entra role. The default is 'App Proxy Certificate Manager'.

.PARAMETER SecretExpirationMonths
    The lifetime of the client secret in months, from 1 to 24. The default is 12.

.PARAMETER UsePim
    Assigns the custom role through Privileged Identity Management (PIM) as a permanent active assignment. Requires Microsoft Entra ID P2 or Microsoft Entra ID Governance. Without this switch, the role is assigned directly. When the custom role is newly created, PIM can take several minutes to recognize it, and the script waits up to 10 minutes.

.PARAMETER RemoveExistingSecrets
    Removes all other client secrets from the app registration after the new client secret is created. Use this when rotating the secret or replacing a secret that was lost. CertKit can't authenticate with a removed secret, so update CertKit with the new secret right away. Without this switch, existing secrets are kept and the script reports how many remain.

.EXAMPLE
    .\New-CertKitAppProxyIdentity.ps1

    Creates the CertKit identity with the default names and a 12-month client secret, and assigns the custom role directly.

.EXAMPLE
    .\New-CertKitAppProxyIdentity.ps1 -UsePim -SecretExpirationMonths 6

    Creates the CertKit identity with a 6-month client secret, and assigns the custom role through PIM.

.EXAMPLE
    .\New-CertKitAppProxyIdentity.ps1 -TenantId contoso.onmicrosoft.com

    Signs in to the contoso.onmicrosoft.com tenant and creates the CertKit identity there, regardless of the account's home tenant.

.EXAMPLE
    .\New-CertKitAppProxyIdentity.ps1 -RemoveExistingSecrets

    Creates a new client secret for the existing CertKit identity and removes all older client secrets.

.INPUTS
    None.

.OUTPUTS
    System.Management.Automation.PSCustomObject

.LINK
    https://directaccess.richardhicks.com/

.NOTES
    Version:        1.3
    Creation Date:  November 14, 2026
    Last Updated:   November 14, 2026
    Author:         Richard Hicks
    Organization:   Richard M. Hicks Consulting, Inc.
    Contact:        rich@richardhicks.com
    Website:        https://www.richardhicks.com/

    Requirements:
    - Microsoft Entra ID P1 or higher (required for Application Proxy and custom roles).
    - The Microsoft.Graph.Authentication PowerShell module.
    - An account with at least the Privileged Role Administrator role.

#>

#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' }

[CmdletBinding(SupportsShouldProcess)]

Param (

    [string]$TenantId,
    [string]$DisplayName = 'CertKit App Proxy Deployment',
    [string]$RoleName = 'App Proxy Certificate Manager',
    [ValidateRange(1, 24)]
    [int]$SecretExpirationMonths = 12,
    [switch]$UsePim,
    [switch]$RemoveExistingSecrets

)

#Region Logging

# Start transcript, including -WhatIf runs
$LogPath = Join-Path -Path $env:ProgramData -ChildPath 'RMHCI\PowerShell'
$LogFile = Join-Path -Path $LogPath -ChildPath "New-CertKitAppProxyIdentity_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

If (-not (Test-Path -Path $LogPath)) {

    New-Item -Path $LogPath -ItemType Directory -Force -WhatIf:$false -Confirm:$false | Out-Null

}

Start-Transcript -Path $LogFile -WhatIf:$false -Confirm:$false | Out-Null
$ExitCode = 0

#EndRegion

# Retry Graph requests that can fail while new objects replicate across Entra ID
Function Invoke-GraphRequestWithRetry {

    [CmdletBinding()]

    Param (

        [Parameter(Mandatory)]
        [hashtable]$Request,
        [int]$MaxAttempts = 6,
        [int]$DelaySeconds = 10

    )

    For ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {

        Try {

            Return Invoke-MgGraphRequest @Request -ErrorAction Stop

        }

        Catch {

            # Retry only errors caused by replication delay, throttling, or service faults. Fail fast on anything else
            $StatusCode = $null

            If ($_.Exception.Response) { $StatusCode = [int]$_.Exception.Response.StatusCode }

            $ErrorText = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
            $IsTransient = ($null -eq $StatusCode) -or
                ($StatusCode -in 404, 408, 429) -or
                ($StatusCode -ge 500) -or
                ($StatusCode -eq 400 -and $ErrorText -match 'not ?found|does ?not ?exist|does not reference a valid')

            If (-not $IsTransient -or $Attempt -eq $MaxAttempts) { Throw }
            Write-Verbose "Request failed with status $StatusCode (attempt $Attempt of $MaxAttempts). Retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds

        }

    }

}

Try {

    $GraphUri = 'https://graph.microsoft.com/v1.0'

    # Application Proxy permissions granted by the custom role
    $RolePermissions = @(

        'microsoft.directory/applications/applicationProxy/read'
        'microsoft.directory/applications/applicationProxySslCertificate/update'
        'microsoft.directory/connectorGroups/allProperties/read'

    )

    # Connect to Microsoft Graph
    Write-Verbose 'Connecting to Microsoft Graph...'
    $ConnectParams = @{

        Scopes      = 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'RoleManagement.ReadWrite.Directory'
        NoWelcome   = $true
        ErrorAction = 'Stop'

    }

    # Sign in to a specific tenant when one is specified
    If ($TenantId) { $ConnectParams['TenantId'] = $TenantId }

    Connect-MgGraph @ConnectParams
    $TenantId = (Get-MgContext).TenantId

    # Display the connected tenant so it's clear where objects will be created
    Try {

        $TenantName = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/organization?`$select=displayName" -ErrorAction Stop).value[0].displayName

    }

    Catch {

        $TenantName = 'Unknown'

    }

    Write-Information "Connected to tenant '$TenantName' ($TenantId)." -InformationAction Continue

    # Build OData filters with apostrophes doubled and the expression URL-encoded, so any display name is safe
    $RoleFilter = [uri]::EscapeDataString("displayName eq '$($RoleName -replace "'", "''")'")
    $AppFilter = [uri]::EscapeDataString("displayName eq '$($DisplayName -replace "'", "''")'")

    # Create or reuse the custom role. Never reuse a built-in role with the same name
    $RoleCreated = $false
    $MatchingRoles = @((Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleDefinitions?`$filter=$RoleFilter" -ErrorAction Stop).value)

    If ($MatchingRoles | Where-Object { $_.isBuiltIn }) {

        Throw "'$RoleName' is the name of a built-in Entra role. Specify a different name with -RoleName."

    }

    $Role = $MatchingRoles | Select-Object -First 1

    If ($Role) {

        Write-Verbose "Using existing custom role '$RoleName' ($($Role.id))."

    }

    ElseIf ($PSCmdlet.ShouldProcess($RoleName, 'Create custom Entra role')) {

        $RoleBody = @{

            displayName     = $RoleName
            description     = 'Can read Application Proxy settings and update the Application Proxy SSL certificate. Used by CertKit.'
            isEnabled       = $true
            rolePermissions = @(@{ allowedResourceActions = $RolePermissions })

        }

        $Role = Invoke-MgGraphRequest -Method POST -Uri "$GraphUri/roleManagement/directory/roleDefinitions" -Body $RoleBody -ErrorAction Stop
        $RoleCreated = $true
        Write-Verbose "Created custom role '$RoleName' ($($Role.id))."

    }

    # Create or reuse the app registration
    $App = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/applications?`$filter=$AppFilter" -ErrorAction Stop).value | Select-Object -First 1

    If ($App) {

        Write-Verbose "Using existing app registration '$DisplayName' ($($App.appId))."

    }

    ElseIf ($PSCmdlet.ShouldProcess($DisplayName, 'Create app registration')) {

        $AppBody = @{

            displayName    = $DisplayName
            signInAudience = 'AzureADMyOrg'

        }

        $App = Invoke-MgGraphRequest -Method POST -Uri "$GraphUri/applications" -Body $AppBody -ErrorAction Stop
        Write-Verbose "Created app registration '$DisplayName' ($($App.appId))."

    }

    # Create or reuse the service principal
    $Sp = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals?`$filter=appId eq '$($App.appId)'" -ErrorAction Stop).value | Select-Object -First 1

    If ($Sp) {

        Write-Verbose "Using existing service principal ($($Sp.id))."

    }

    ElseIf ($PSCmdlet.ShouldProcess($DisplayName, 'Create service principal')) {

        $SpRequest = @{

            Method = 'POST'
            Uri    = "$GraphUri/servicePrincipals"
            Body   = @{ appId = $App.appId }

        }

        $Sp = Invoke-GraphRequestWithRetry -Request $SpRequest
        Write-Verbose "Created service principal ($($Sp.id))."

    }

    # Grant the read-only Microsoft Graph application permission Application.Read.All
    $GraphSp = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles" -ErrorAction Stop).value[0]
    $AppRoleId = ($GraphSp.appRoles | Where-Object { $_.value -eq 'Application.Read.All' -and $_.allowedMemberTypes -contains 'Application' }).id

    # With -WhatIf, a service principal that doesn't exist yet has no grants to look up
    $ExistingGrant = $null

    If ($Sp) {

        $ExistingGrant = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals/$($Sp.id)/appRoleAssignments" -ErrorAction Stop).value | Where-Object { $_.appRoleId -eq $AppRoleId }

    }

    If ($ExistingGrant) {

        Write-Verbose 'Application.Read.All is already granted.'

    }

    ElseIf ($PSCmdlet.ShouldProcess($DisplayName, 'Grant Microsoft Graph application permission Application.Read.All')) {

        $GrantRequest = @{

            Method = 'POST'
            Uri    = "$GraphUri/servicePrincipals/$($Sp.id)/appRoleAssignments"
            Body   = @{ principalId = $Sp.id; resourceId = $GraphSp.id; appRoleId = $AppRoleId }

        }

        Invoke-GraphRequestWithRetry -Request $GrantRequest | Out-Null
        Write-Verbose 'Granted Application.Read.All.'

    }

    # Assign the custom role tenant-wide, directly or through PIM
    # With -WhatIf, a service principal or role that doesn't exist yet has no assignments to look up
    $ExistingAssignment = $null
    $RoleAssigned = 'Not assigned'

    If ($Sp -and $Role) {

        $ExistingAssignment = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($Sp.id)' and roleDefinitionId eq '$($Role.id)'" -ErrorAction Stop).value

    }

    If ($ExistingAssignment) {

        $RoleAssigned = 'Already assigned'
        Write-Verbose "The '$RoleName' role is already assigned."

    }

    ElseIf ($UsePim) {

        If ($PSCmdlet.ShouldProcess($DisplayName, "Assign '$RoleName' role through PIM")) {

            $PimRequest = @{

                Method = 'POST'
                Uri    = "$GraphUri/roleManagement/directory/roleAssignmentScheduleRequests"
                Body   = @{

                    action           = 'adminAssign'
                    justification    = 'CertKit certificate deployment to Entra Application Proxy'
                    roleDefinitionId = $Role.id
                    directoryScopeId = '/'
                    principalId      = $Sp.id
                    scheduleInfo     = @{

                        startDateTime = (Get-Date).ToUniversalTime().ToString('o')
                        expiration    = @{ type = 'noExpiration' }

                    }

                }

            }

            # PIM can take several minutes to recognize a newly created custom role, so allow up to 10 minutes
            If ($RoleCreated) {

                Write-Information 'Waiting for PIM to recognize the new custom role. This can take several minutes...' -InformationAction Continue

            }

            Invoke-GraphRequestWithRetry -Request $PimRequest -MaxAttempts 60 | Out-Null
            $RoleAssigned = 'Through PIM'
            Write-Verbose "Assigned the '$RoleName' role through PIM."

        }

    }

    ElseIf ($PSCmdlet.ShouldProcess($DisplayName, "Assign '$RoleName' role")) {

        $AssignmentRequest = @{

            Method = 'POST'
            Uri    = "$GraphUri/roleManagement/directory/roleAssignments"
            Body   = @{

                '@odata.type'    = '#microsoft.graph.unifiedRoleAssignment'
                roleDefinitionId = $Role.id
                principalId      = $Sp.id
                directoryScopeId = '/'

            }

        }

        Invoke-GraphRequestWithRetry -Request $AssignmentRequest | Out-Null
        $RoleAssigned = 'Directly'
        Write-Verbose "Assigned the '$RoleName' role."

    }

    # Create a client secret and copy it to the clipboard
    $NewSecretKeyId = $null
    $SecretExpires = (Get-Date).AddMonths($SecretExpirationMonths)

    If ($PSCmdlet.ShouldProcess($DisplayName, "Create client secret expiring $($SecretExpires.ToString('d'))")) {

        $SecretBody = @{

            passwordCredential = @{

                displayName = 'CertKit'
                endDateTime = $SecretExpires.ToUniversalTime().ToString('o')

            }

        }

        $Secret = Invoke-MgGraphRequest -Method POST -Uri "$GraphUri/applications/$($App.id)/addPassword" -Body $SecretBody -ErrorAction Stop
        $NewSecretKeyId = $Secret.keyId
        $Secret.secretText | Set-Clipboard
        Remove-Variable -Name Secret
        Write-Warning 'The client secret was copied to the clipboard. Paste it into CertKit now, then clear the clipboard with Set-Clipboard -Value $null.'

    }

    # Remove older client secrets, or report how many remain
    $SecretsRemoved = 0

    If ($App.id) {

        $OldSecrets = @((Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/applications/$($App.id)?`$select=passwordCredentials" -ErrorAction Stop).passwordCredentials | Where-Object { $_.keyId -ne $NewSecretKeyId })

        # Remove older secrets only after a new secret was successfully created
        If ($OldSecrets.Count -gt 0 -and $RemoveExistingSecrets -and $NewSecretKeyId) {

            ForEach ($OldSecret in $OldSecrets) {

                If ($PSCmdlet.ShouldProcess($DisplayName, "Remove client secret '$($OldSecret.displayName)' ($($OldSecret.hint)***), expiring $(([datetime]$OldSecret.endDateTime).ToString('d'))")) {

                    Invoke-MgGraphRequest -Method POST -Uri "$GraphUri/applications/$($App.id)/removePassword" -Body @{ keyId = $OldSecret.keyId } -ErrorAction Stop
                    $SecretsRemoved++
                    Write-Verbose "Removed client secret $($OldSecret.keyId)."

                }

            }

        }

        ElseIf ($OldSecrets.Count -gt 0) {

            Write-Warning "The app registration has $($OldSecrets.Count) older client secret(s). Once CertKit is using the new secret, delete them on the app registration's Certificates & secrets page in the Entra admin center. Running this script again with -RemoveExistingSecrets would also remove the secret CertKit is now using."

        }

    }

    # Output the values CertKit needs
    [PSCustomObject]@{

        TenantName        = $TenantName
        TenantId          = $TenantId
        ClientId          = $App.appId
        SecretExpires     = $SecretExpires
        CustomRole        = $RoleName
        RoleAssigned      = $RoleAssigned
        OldSecretsRemoved = $SecretsRemoved

    }

}

Catch {

    # Record the error in the transcript before logging stops
    $ErrorActionPreference = 'Continue'
    Write-Error -ErrorRecord $_
    $ExitCode = 1

}

Finally {

    Stop-Transcript | Out-Null

}

If ($ExitCode -ne 0) {

    Exit $ExitCode

}
