<#

.SYNOPSIS
    Removes the Microsoft Entra identity, permissions, custom role, and role assignments configured by New-CertKitAppProxyIdentity.ps1.

.DESCRIPTION
    This script removes what New-CertKitAppProxyIdentity.ps1 configures, returning the tenant to a clean state for testing or decommissioning.

    Client secret authentication (default):
    - Removes the custom role assignment, whether it was made through Privileged Identity Management (PIM) or directly.
    - Deletes the CertKit app registration, which also removes its service principal, the Application.Read.All permission grant, and all client secrets.
    - Permanently deletes the app registration from the Entra ID recycle bin, unless -KeepDeletedApp is specified.

    Managed identity authentication (-ManagedIdentityId):
    - Removes the custom role assignment, whether it was made through PIM or directly.
    - Removes the Application.Read.All permission grant.
    - Doesn't delete the managed identity, which is an Azure resource. Delete it in the Azure portal if it's no longer needed.

    Both methods:
    - Deletes the custom Entra role, unless -KeepRole is specified or the role is still assigned to another identity, such as when client secret and managed identity deployments share the role.

    The script is safe to run more than once. Objects that no longer exist are skipped. If more than one app registration or custom role matches the specified names, the script stops without making changes.

    After running this script, CertKit can no longer deploy certificates to Entra Application Proxy until a new identity is created and the CertKit deployment is updated.

.PARAMETER TenantId
    The tenant ID (GUID) or a verified domain name of the Microsoft Entra tenant to clean up. Optional. If omitted, the script uses the tenant of the account you sign in with.

.PARAMETER DisplayName
    The display name of the CertKit app registration to remove. Client secret authentication only. The default is 'CertKit App Proxy Deployment'.

.PARAMETER ManagedIdentityId
    The object (principal) ID or client ID of the managed identity to remove CertKit's permissions from. Selects managed identity authentication. The managed identity itself isn't deleted.

.PARAMETER RoleName
    The display name of the custom Entra role to remove. The default is 'App Proxy Certificate Manager'.

.PARAMETER KeepDeletedApp
    Client secret authentication only. Leaves the deleted app registration in the Entra ID recycle bin, where it can be restored for 30 days. By default, the app registration is permanently deleted.

.PARAMETER KeepRole
    Keeps the custom Entra role. By default, the role is deleted unless it's still assigned to another identity.

.EXAMPLE
    .\Remove-CertKitAppProxyIdentity.ps1

    Removes the CertKit identity, custom role, and role assignments that use the default names, prompting for confirmation before each removal.

.EXAMPLE
    .\Remove-CertKitAppProxyIdentity.ps1 -TenantId contoso.onmicrosoft.com -Confirm:$false

    Signs in to the contoso.onmicrosoft.com tenant and removes everything without prompting for confirmation.

.EXAMPLE
    .\Remove-CertKitAppProxyIdentity.ps1 -WhatIf

    Shows what would be removed without making any changes.

.EXAMPLE
    .\Remove-CertKitAppProxyIdentity.ps1 -KeepRole

    Removes the client secret identity but keeps the custom role, for example after moving CertKit to a managed identity that uses the same role.

.EXAMPLE
    .\Remove-CertKitAppProxyIdentity.ps1 -ManagedIdentityId e7ceec4e-6431-429a-8a17-c6127b14d3ef

    Removes the custom role assignment and Application.Read.All permission from the managed identity, and deletes the custom role if no other identity uses it.

.INPUTS
    None.

.OUTPUTS
    System.Management.Automation.PSCustomObject

.LINK
    https://github.com/richardhicks/certkit/

.LINK
    https://directaccess.richardhicks.com/

.NOTES
    Version:        1.2
    Creation Date:  November 14, 2026
    Last Updated:   November 23, 2026
    Author:         Richard Hicks
    Organization:   Richard M. Hicks Consulting, Inc.
    Contact:        rich@richardhicks.com
    Website:        https://www.richardhicks.com/

    Requirements:
    - The Microsoft.Graph.Authentication PowerShell module.
    - An account with at least the Privileged Role Administrator role.

#>

#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' }

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ClientSecret')]

Param (

    [string]$TenantId,
    [Parameter(ParameterSetName = 'ClientSecret')]
    [string]$DisplayName = 'CertKit App Proxy Deployment',
    [Parameter(Mandatory, ParameterSetName = 'ManagedIdentity')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$ManagedIdentityId,
    [string]$RoleName = 'App Proxy Certificate Manager',
    [Parameter(ParameterSetName = 'ClientSecret')]
    [switch]$KeepDeletedApp,
    [switch]$KeepRole

)

#Region Logging

# Start transcript, including -WhatIf runs
$LogPath = Join-Path -Path $env:ProgramData -ChildPath 'RMHCI\PowerShell'
$LogFile = Join-Path -Path $LogPath -ChildPath "Remove-CertKitAppProxyIdentity_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

If (-not (Test-Path -Path $LogPath)) {

    New-Item -Path $LogPath -ItemType Directory -Force -WhatIf:$false -Confirm:$false | Out-Null

}

Start-Transcript -Path $LogFile -WhatIf:$false -Confirm:$false | Out-Null
$ExitCode = 0

#EndRegion

Try {

    $GraphUri = 'https://graph.microsoft.com/v1.0'

    # Track what was removed
    $Result = [Ordered]@{

        RoleAssignmentsRemoved = 0
        PermissionRemoved      = $false
        AppRegistrationDeleted = $false
        AppRegistrationPurged  = $false
        CustomRoleDeleted      = $false

    }

    $UseManagedIdentity = $PSCmdlet.ParameterSetName -eq 'ManagedIdentity'

    # Connect to Microsoft Graph
    Write-Verbose 'Connecting to Microsoft Graph...'
    $ConnectParams = @{

        Scopes      = If ($UseManagedIdentity) { 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All', 'RoleManagement.ReadWrite.Directory' } Else { 'Application.ReadWrite.All', 'RoleManagement.ReadWrite.Directory' }
        NoWelcome   = $true
        ErrorAction = 'Stop'

    }

    # Sign in to a specific tenant when one is specified
    If ($TenantId) { $ConnectParams['TenantId'] = $TenantId }

    Connect-MgGraph @ConnectParams
    $TenantId = (Get-MgContext).TenantId

    # Display the connected tenant so it's clear where objects will be removed
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

    # Find the custom role. Never touch a built-in role with the same name
    $Role = @((Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleDefinitions?`$filter=$RoleFilter" -ErrorAction Stop).value)
    If ($Role | Where-Object { $_.isBuiltIn }) { Throw "'$RoleName' is the name of a built-in Entra role. Specify the custom role with -RoleName. No changes were made." }
    If ($Role.Count -gt 1) { Throw "Found $($Role.Count) custom roles named '$RoleName'. Resolve the duplicates manually. No changes were made." }
    $Role = $Role | Select-Object -First 1

    $App = $null
    $Sp = $null

    If ($UseManagedIdentity) {

        # Find the managed identity by object ID, then by client ID
        Try {

            $Sp = Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals/$($ManagedIdentityId)?`$select=id,appId,displayName,servicePrincipalType" -ErrorAction Stop

        }

        Catch {

            $Sp = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals?`$filter=appId eq '$ManagedIdentityId'&`$select=id,appId,displayName,servicePrincipalType" -ErrorAction Stop).value | Select-Object -First 1

        }

        If ($Sp -and $Sp.servicePrincipalType -ne 'ManagedIdentity') { Throw "'$($Sp.displayName)' ($ManagedIdentityId) is not a managed identity. Its service principal type is '$($Sp.servicePrincipalType)'. No changes were made." }

        If ($Sp) {

            $DisplayName = $Sp.displayName
            Write-Verbose "Found managed identity '$DisplayName' (client ID $($Sp.appId), object ID $($Sp.id))."

        }

        Else {

            Write-Verbose "Managed identity '$ManagedIdentityId' not found. Skipping."

        }

    }

    Else {

        # Find the app registration and its service principal
        $App = @((Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/applications?`$filter=$AppFilter" -ErrorAction Stop).value)
        If ($App.Count -gt 1) { Throw "Found $($App.Count) app registrations named '$DisplayName'. Resolve the duplicates manually. No changes were made." }
        $App = $App | Select-Object -First 1

        If ($App) {

            $Sp = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals?`$filter=appId eq '$($App.appId)'" -ErrorAction Stop).value | Select-Object -First 1
            Write-Verbose "Found app registration '$DisplayName' ($($App.appId))."

        }

        Else {

            Write-Verbose "App registration '$DisplayName' not found. Skipping."

        }

    }

    If ($Role) { Write-Verbose "Found custom role '$RoleName' ($($Role.id))." }
    Else { Write-Verbose "Custom role '$RoleName' not found. Skipping." }

    # Remove role assignments, through PIM first, then any direct assignments
    If ($Sp) {

        If ($Role) {

            $PimAssignment = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleAssignmentSchedules?`$filter=principalId eq '$($Sp.id)' and roleDefinitionId eq '$($Role.id)'" -ErrorAction SilentlyContinue).value

            If ($PimAssignment -and $PSCmdlet.ShouldProcess($DisplayName, "Remove '$RoleName' role assignment through PIM")) {

                $PimRequest = @{

                    Method      = 'POST'
                    Uri         = "$GraphUri/roleManagement/directory/roleAssignmentScheduleRequests"
                    Body        = @{

                        action           = 'adminRemove'
                        justification    = 'Remove CertKit Application Proxy identity'
                        roleDefinitionId = $Role.id
                        directoryScopeId = '/'
                        principalId      = $Sp.id

                    }
                    ErrorAction = 'Stop'

                }

                # PIM rejects removing an active assignment less than 5 minutes after it starts (ActiveDurationTooShort), so wait and retry
                $MaxPimAttempts = 12

                For ($PimAttempt = 1; $PimAttempt -le $MaxPimAttempts; $PimAttempt++) {

                    Try {

                        Invoke-MgGraphRequest @PimRequest | Out-Null
                        Break

                    }

                    Catch {

                        $ErrorText = "$($_.ErrorDetails.Message) $($_.Exception.Message)"

                        If ($ErrorText -notmatch 'ActiveDurationTooShort' -or $PimAttempt -eq $MaxPimAttempts) { Throw }

                        If ($PimAttempt -eq 1) {

                            Write-Information 'The PIM assignment was made less than 5 minutes ago and cannot be removed yet. Waiting up to 6 minutes...' -InformationAction Continue

                        }

                        Write-Verbose "PIM assignment is too new to remove (attempt $PimAttempt of $MaxPimAttempts). Retrying in 30 seconds..."
                        Start-Sleep -Seconds 30

                    }

                }

                $Result.RoleAssignmentsRemoved++
                Write-Verbose "Removed the '$RoleName' role assignment through PIM."

            }

            # Remove only assignments of the custom role. A managed identity isn't deleted and can hold other Entra roles
            $Assignments = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($Sp.id)' and roleDefinitionId eq '$($Role.id)'" -ErrorAction Stop).value

            ForEach ($Assignment in $Assignments) {

                If ($PSCmdlet.ShouldProcess($DisplayName, "Remove '$RoleName' role assignment $($Assignment.id)")) {

                    # An assignment just removed through PIM can still be listed briefly, so a failure here is not fatal
                    Try {

                        Invoke-MgGraphRequest -Method DELETE -Uri "$GraphUri/roleManagement/directory/roleAssignments/$($Assignment.id)" -ErrorAction Stop
                        $Result.RoleAssignmentsRemoved++
                        Write-Verbose "Removed role assignment $($Assignment.id)."

                    }

                    Catch {

                        Write-Verbose "Could not remove role assignment $($Assignment.id). It may already be removed through PIM."

                    }

                }

            }

        }

    }

    # Remove the Application.Read.All permission from a managed identity, since the identity itself isn't deleted
    If ($UseManagedIdentity -and $Sp) {

        $GraphSp = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles" -ErrorAction Stop).value[0]
        $AppRoleId = ($GraphSp.appRoles | Where-Object { $_.value -eq 'Application.Read.All' -and $_.allowedMemberTypes -contains 'Application' }).id
        $Grant = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals/$($Sp.id)/appRoleAssignments" -ErrorAction Stop).value | Where-Object { $_.appRoleId -eq $AppRoleId -and $_.resourceId -eq $GraphSp.id }

        If ($Grant -and $PSCmdlet.ShouldProcess($DisplayName, 'Remove Microsoft Graph application permission Application.Read.All')) {

            Invoke-MgGraphRequest -Method DELETE -Uri "$GraphUri/servicePrincipals/$($Sp.id)/appRoleAssignments/$($Grant.id)" -ErrorAction Stop
            $Result.PermissionRemoved = $true
            Write-Verbose 'Removed Application.Read.All.'

        }

        ElseIf (-not $Grant) {

            Write-Verbose 'Application.Read.All is not granted. Skipping.'

        }

    }

    # Delete the app registration, which also removes its service principal, permission grant, and client secrets
    If ($App -and $PSCmdlet.ShouldProcess($DisplayName, 'Delete app registration')) {

        Invoke-MgGraphRequest -Method DELETE -Uri "$GraphUri/applications/$($App.id)" -ErrorAction Stop
        $Result.AppRegistrationDeleted = $true
        $Result.PermissionRemoved = $true
        Write-Verbose "Deleted app registration '$DisplayName'."

        # Permanently delete the app registration from the recycle bin
        If (-not $KeepDeletedApp) {

            Invoke-MgGraphRequest -Method DELETE -Uri "$GraphUri/directory/deletedItems/$($App.id)" -ErrorAction Stop
            $Result.AppRegistrationPurged = $true
            Write-Verbose "Permanently deleted app registration '$DisplayName' from the recycle bin."

        }

    }

    # Keep the custom role if requested, or if another identity still uses it
    $DeleteRole = [bool]$Role

    If ($Role -and $KeepRole) {

        $DeleteRole = $false
        Write-Verbose "Keeping custom role '$RoleName' as requested."

    }

    ElseIf ($Role) {

        # Ignore this identity's own assignments, which can still be listed briefly after removal through PIM
        $OtherActive = @((Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '$($Role.id)'" -ErrorAction Stop).value | Where-Object { -not $Sp -or $_.principalId -ne $Sp.id })
        $OtherEligible = @((Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleEligibilitySchedules?`$filter=roleDefinitionId eq '$($Role.id)'" -ErrorAction SilentlyContinue).value | Where-Object { -not $Sp -or $_.principalId -ne $Sp.id })
        $OtherCount = $OtherActive.Count + $OtherEligible.Count

        If ($OtherCount -gt 0) {

            $DeleteRole = $false
            Write-Warning "Custom role '$RoleName' is still assigned to $OtherCount other identity or identities, so it wasn't deleted. Use the Entra admin center to review its assignments."

        }

    }

    # Delete the custom role, retrying while the assignment removal replicates
    If ($DeleteRole -and $PSCmdlet.ShouldProcess($RoleName, 'Delete custom Entra role')) {

        $MaxAttempts = 6

        For ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {

            Try {

                Invoke-MgGraphRequest -Method DELETE -Uri "$GraphUri/roleManagement/directory/roleDefinitions/$($Role.id)" -ErrorAction Stop
                $Result.CustomRoleDeleted = $true
                Write-Verbose "Deleted custom role '$RoleName'."
                Break

            }

            Catch {

                If ($Attempt -eq $MaxAttempts) { Throw }
                Write-Verbose "Custom role is still in use (attempt $Attempt of $MaxAttempts). Retrying in 10 seconds..."
                Start-Sleep -Seconds 10

            }

        }

    }

    # Output a summary
    [PSCustomObject]@{

        TenantName             = $TenantName
        TenantId               = $TenantId
        Identity               = $DisplayName
        RoleAssignmentsRemoved = $Result.RoleAssignmentsRemoved
        PermissionRemoved      = $Result.PermissionRemoved
        AppRegistrationDeleted = $Result.AppRegistrationDeleted
        AppRegistrationPurged  = $Result.AppRegistrationPurged
        CustomRoleDeleted      = $Result.CustomRoleDeleted

    }

}

Catch {

    # Record the error in the transcript before logging stops
    $ErrorActionPreference = 'Continue'
    Write-Error -ErrorRecord $_
    $ExitCode = 1

}

Finally {

    # Stop-Transcript supports -WhatIf in PowerShell 7 but not in Windows PowerShell 5.1
    $StopTranscriptParams = @{}

    If ((Get-Command -Name Stop-Transcript).Parameters.ContainsKey('WhatIf')) {

        $StopTranscriptParams = @{ WhatIf = $false; Confirm = $false }

    }

    Stop-Transcript @StopTranscriptParams | Out-Null

}

If ($ExitCode -ne 0) {

    Exit $ExitCode

}
