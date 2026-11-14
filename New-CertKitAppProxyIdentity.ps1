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

    The script is safe to run more than once. Existing objects with the same names are reused, and existing role and permission assignments are not duplicated. A new client secret is created on every run.

.PARAMETER DisplayName
    The display name of the CertKit app registration. The default is 'CertKit App Proxy Deployment'.

.PARAMETER RoleName
    The display name of the custom Entra role. The default is 'App Proxy Certificate Manager'.

.PARAMETER SecretExpirationMonths
    The lifetime of the client secret in months, from 1 to 24. The default is 12.

.PARAMETER UsePim
    Assigns the custom role through Privileged Identity Management (PIM) as a permanent active assignment. Requires Microsoft Entra ID P2 or Microsoft Entra ID Governance. Without this switch, the role is assigned directly.

.EXAMPLE
    .\New-CertKitAppProxyIdentity.ps1

    Creates the CertKit identity with the default names and a 12-month client secret, and assigns the custom role directly.

.EXAMPLE
    .\New-CertKitAppProxyIdentity.ps1 -UsePim -SecretExpirationMonths 6

    Creates the CertKit identity with a 6-month client secret, and assigns the custom role through PIM.

.INPUTS
    None.

.OUTPUTS
    System.Management.Automation.PSCustomObject

.LINK
    https://directaccess.richardhicks.com/

.NOTES
    Version:        1.0
    Creation Date:  November 14, 2026
    Last Updated:   November 14, 2026
    Author:         Richard Hicks
    Organization:   Richard M. Hicks Consulting, Inc.
    Website:        https://www.richardhicks.com/

    Requirements:
    - Microsoft Entra ID P1 or higher (required for Application Proxy and custom roles).
    - The Microsoft.Graph.Authentication PowerShell module.
    - An account with at least the Privileged Role Administrator role.

#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding(SupportsShouldProcess)]

Param (

    [string]$DisplayName = 'CertKit App Proxy Deployment',
    [string]$RoleName = 'App Proxy Certificate Manager',
    [ValidateRange(1, 24)]
    [int]$SecretExpirationMonths = 12,
    [switch]$UsePim

)

# Start transcript
$TranscriptPath = Join-Path -Path $env:ProgramData -ChildPath "New-CertKitAppProxyIdentity_$(Get-Date -Format 'yyyyMMddHHmmss').log"
Start-Transcript -Path $TranscriptPath | Out-Null

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

            If ($Attempt -eq $MaxAttempts) { Throw }
            Write-Verbose "Request failed (attempt $Attempt of $MaxAttempts). Retrying in $DelaySeconds seconds..."
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

    Connect-MgGraph @ConnectParams
    $TenantId = (Get-MgContext).TenantId

    # Create or reuse the custom role
    $Role = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleDefinitions?`$filter=displayName eq '$RoleName'" -ErrorAction Stop).value | Select-Object -First 1

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
        Write-Verbose "Created custom role '$RoleName' ($($Role.id))."

    }

    # Create or reuse the app registration
    $App = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/applications?`$filter=displayName eq '$DisplayName'" -ErrorAction Stop).value | Select-Object -First 1

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
    $ExistingGrant = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals/$($Sp.id)/appRoleAssignments" -ErrorAction Stop).value | Where-Object { $_.appRoleId -eq $AppRoleId }

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
    $ExistingAssignment = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($Sp.id)' and roleDefinitionId eq '$($Role.id)'" -ErrorAction Stop).value

    If ($ExistingAssignment) {

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

            Invoke-GraphRequestWithRetry -Request $PimRequest | Out-Null
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
        Write-Verbose "Assigned the '$RoleName' role."

    }

    # Create a client secret and copy it to the clipboard
    $SecretExpires = (Get-Date).AddMonths($SecretExpirationMonths)

    If ($PSCmdlet.ShouldProcess($DisplayName, "Create client secret expiring $($SecretExpires.ToString('d'))")) {

        $SecretBody = @{

            passwordCredential = @{

                displayName = 'CertKit'
                endDateTime = $SecretExpires.ToUniversalTime().ToString('o')

            }

        }

        $Secret = Invoke-MgGraphRequest -Method POST -Uri "$GraphUri/applications/$($App.id)/addPassword" -Body $SecretBody -ErrorAction Stop
        $Secret.secretText | Set-Clipboard
        Remove-Variable -Name Secret
        Write-Warning 'The client secret was copied to the clipboard. Paste it into CertKit now, then clear the clipboard with Set-Clipboard -Value $null.'

    }

    # Output the values CertKit needs
    [PSCustomObject]@{

        TenantId      = $TenantId
        ClientId      = $App.appId
        SecretExpires = $SecretExpires
        CustomRole    = $RoleName
        RoleAssigned  = If ($UsePim) { 'Through PIM' } Else { 'Directly' }

    }

}

Catch {

    Write-Error $_
    Throw

}

Finally {

    Stop-Transcript | Out-Null

}
