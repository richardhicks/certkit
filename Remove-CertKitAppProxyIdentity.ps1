<#

.SYNOPSIS
    Removes the Microsoft Entra identity, custom role, and role assignments created by New-CertKitAppProxyIdentity.ps1.

.DESCRIPTION
    This script removes everything New-CertKitAppProxyIdentity.ps1 creates, returning the tenant to a clean state for testing or decommissioning.

    - Removes the custom role assignment, whether it was made through Privileged Identity Management (PIM) or directly.
    - Deletes the CertKit app registration, which also removes its service principal, the Application.Read.All permission grant, and all client secrets.
    - Permanently deletes the app registration from the Entra ID recycle bin, unless -KeepDeletedApp is specified.
    - Deletes the custom Entra role.

    The script is safe to run more than once. Objects that no longer exist are skipped. If more than one app registration or custom role matches the specified names, the script stops without making changes.

    After running this script, CertKit can no longer deploy certificates to Entra Application Proxy until a new identity is created and the CertKit deployment is updated.

.PARAMETER TenantId
    The tenant ID (GUID) or a verified domain name of the Microsoft Entra tenant to clean up. Optional. If omitted, the script uses the tenant of the account you sign in with.

.PARAMETER DisplayName
    The display name of the CertKit app registration to remove. The default is 'CertKit App Proxy Deployment'.

.PARAMETER RoleName
    The display name of the custom Entra role to remove. The default is 'App Proxy Certificate Manager'.

.PARAMETER KeepDeletedApp
    Leaves the deleted app registration in the Entra ID recycle bin, where it can be restored for 30 days. By default, the app registration is permanently deleted.

.EXAMPLE
    .\Remove-CertKitAppProxyIdentity.ps1

    Removes the CertKit identity, custom role, and role assignments that use the default names, prompting for confirmation before each removal.

.EXAMPLE
    .\Remove-CertKitAppProxyIdentity.ps1 -TenantId contoso.onmicrosoft.com -Confirm:$false

    Signs in to the contoso.onmicrosoft.com tenant and removes everything without prompting for confirmation.

.EXAMPLE
    .\Remove-CertKitAppProxyIdentity.ps1 -WhatIf

    Shows what would be removed without making any changes.

.INPUTS
    None.

.OUTPUTS
    System.Management.Automation.PSCustomObject

.LINK
    https://github.com/richardhicks/certkit/

.LINK
    https://directaccess.richardhicks.com/

.NOTES
    Version:        1.1
    Creation Date:  November 14, 2026
    Last Updated:   November 14, 2026
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

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]

Param (

    [string]$TenantId,
    [string]$DisplayName = 'CertKit App Proxy Deployment',
    [string]$RoleName = 'App Proxy Certificate Manager',
    [switch]$KeepDeletedApp

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
        AppRegistrationDeleted = $false
        AppRegistrationPurged  = $false
        CustomRoleDeleted      = $false

    }

    # Connect to Microsoft Graph
    Write-Verbose 'Connecting to Microsoft Graph...'
    $ConnectParams = @{

        Scopes      = 'Application.ReadWrite.All', 'RoleManagement.ReadWrite.Directory'
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

    # Find the app registration, service principal, and custom role
    $App = @((Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/applications?`$filter=displayName eq '$DisplayName'" -ErrorAction Stop).value)
    $Role = @((Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleDefinitions?`$filter=displayName eq '$RoleName'" -ErrorAction Stop).value)

    If ($App.Count -gt 1) { Throw "Found $($App.Count) app registrations named '$DisplayName'. Resolve the duplicates manually. No changes were made." }
    If ($Role.Count -gt 1) { Throw "Found $($Role.Count) custom roles named '$RoleName'. Resolve the duplicates manually. No changes were made." }

    $App = $App | Select-Object -First 1
    $Role = $Role | Select-Object -First 1
    $Sp = $null

    If ($App) {

        $Sp = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/servicePrincipals?`$filter=appId eq '$($App.appId)'" -ErrorAction Stop).value | Select-Object -First 1
        Write-Verbose "Found app registration '$DisplayName' ($($App.appId))."

    }

    Else {

        Write-Verbose "App registration '$DisplayName' not found. Skipping."

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

        }

        $Assignments = (Invoke-MgGraphRequest -Method GET -Uri "$GraphUri/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($Sp.id)'" -ErrorAction Stop).value

        ForEach ($Assignment in $Assignments) {

            If ($PSCmdlet.ShouldProcess($DisplayName, "Remove role assignment $($Assignment.id)")) {

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

    # Delete the app registration, which also removes its service principal, permission grant, and client secrets
    If ($App -and $PSCmdlet.ShouldProcess($DisplayName, 'Delete app registration')) {

        Invoke-MgGraphRequest -Method DELETE -Uri "$GraphUri/applications/$($App.id)" -ErrorAction Stop
        $Result.AppRegistrationDeleted = $true
        Write-Verbose "Deleted app registration '$DisplayName'."

        # Permanently delete the app registration from the recycle bin
        If (-not $KeepDeletedApp) {

            Invoke-MgGraphRequest -Method DELETE -Uri "$GraphUri/directory/deletedItems/$($App.id)" -ErrorAction Stop
            $Result.AppRegistrationPurged = $true
            Write-Verbose "Permanently deleted app registration '$DisplayName' from the recycle bin."

        }

    }

    # Delete the custom role, retrying while the assignment removal replicates
    If ($Role -and $PSCmdlet.ShouldProcess($RoleName, 'Delete custom Entra role')) {

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
        RoleAssignmentsRemoved = $Result.RoleAssignmentsRemoved
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

    Stop-Transcript | Out-Null

}

If ($ExitCode -ne 0) {

    Exit $ExitCode

}
