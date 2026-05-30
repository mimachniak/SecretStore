# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
    DSC v3 resource script for managing Microsoft.PowerShell.SecretStore configuration.

.DESCRIPTION
    Implements Get, Set, and Test operations for the SecretStore vault configuration.
    Requires the Microsoft.PowerShell.SecretStore module to be installed.

.PARAMETER Operation
    The DSC operation to perform: Get, Set, or Test.

.PARAMETER jsonInput
    JSON string received via pipeline containing the desired state properties.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Get', 'Set', 'Test')]
    [string]$Operation,

    [Parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true)]
    [string]$jsonInput
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-DscTrace {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')]
        [string]$Level,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Message
    )

    $trace = @{ $Level.ToLower() = $Message } | ConvertTo-Json -Compress
    $host.ui.WriteErrorLine($trace)
}

function Assert-ModuleAvailable {
    param([string]$ModuleName)

    if (-not (Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue |
              Select-Object -First 1)) {
        Write-DscTrace -Level Error -Message (
            "Required module '$ModuleName' is not installed. " +
            "Install it with: Install-Module -Name $ModuleName -Repository PSGallery -Force"
        )
        exit 1
    }
}

function Get-CurrentState {
    <#
    .SYNOPSIS
        Returns a hashtable representing the current SecretStore configuration.
    #>
    param(
        [switch]$SuppressNonInteractiveError
    )

    try {
        $config = Get-SecretStoreConfiguration -ErrorAction Stop
        return [ordered]@{
            authentication  = $config.Authentication.ToString()
            passwordTimeout = [int]$config.PasswordTimeout
            interaction     = $config.Interaction.ToString()
            scope           = $config.Scope.ToString()
        }
    }
    catch {
        if ($_.ToString() -match 'NonInteractive mode') {
            if ($SuppressNonInteractiveError) {
                return [ordered]@{
                    authentication             = $null
                    passwordTimeout            = $null
                    interaction                = $null
                    scope                      = $null
                    requiresInteractiveInput   = $true
                }
            }

            Write-DscTrace -Level Error -Message (
                "SecretStore is configured to require interactive input. " +
                "This DSC resource runs PowerShell with -NonInteractive, so prompts are not allowed. " +
                "Reconfigure SecretStore in an interactive session first, for example: " +
                "Set-SecretStoreConfiguration -Authentication None -Interaction None -PasswordTimeout -1 -Confirm:`$false"
            )
            exit 1
        }

        Write-DscTrace -Level Error -Message "Failed to retrieve SecretStore configuration: $_"
        exit 1
    }
}

function Ensure-SecretStoreVaultRegistered {
    <#
    .SYNOPSIS
        Ensures the SecretStore vault is registered before configuration changes.
    #>
    try {
        $vault = Get-SecretVault -Name 'SecretStore' -ErrorAction SilentlyContinue
        if ($null -eq $vault) {
            Register-SecretVault -Name 'SecretStore' -ModuleName 'Microsoft.PowerShell.SecretStore' -DefaultVault -ErrorAction Stop
            Write-DscTrace -Level Info -Message 'Registered SecretStore vault.'
        }
    }
    catch {
        Write-DscTrace -Level Error -Message "Failed to register SecretStore vault: $_"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

Assert-ModuleAvailable -ModuleName 'Microsoft.PowerShell.SecretStore'

try {
    Import-Module Microsoft.PowerShell.SecretStore -ErrorAction Stop
}
catch {
    Write-DscTrace -Level Error -Message "Failed to import Microsoft.PowerShell.SecretStore: $_"
    exit 1
}

# ---------------------------------------------------------------------------
# Parse input
# ---------------------------------------------------------------------------

$desired = $null
try {
    $desired = $jsonInput | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}
catch {
    Write-DscTrace -Level Error -Message "Failed to parse JSON input: $_"
    exit 1
}

if ($null -eq $desired) {
    $desired = @{}
}

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

switch ($Operation) {
    'Get' {
        try {
            Get-CurrentState | ConvertTo-Json -Compress
        }
        catch {
            Write-DscTrace -Level Error -Message "Get operation failed: $_"
            exit 1
        }
    }

    'Set' {
        try {
            $setParams = @{ Confirm = $false }

            if ($desired.ContainsKey('authentication'))  { $setParams['Authentication']  = $desired['authentication'] }
            if ($desired.ContainsKey('passwordTimeout')) { $setParams['PasswordTimeout'] = [int]$desired['passwordTimeout'] }
            if ($desired.ContainsKey('interaction'))     { $setParams['Interaction']     = $desired['interaction'] }
            if ($desired.ContainsKey('scope'))           { $setParams['Scope']           = $desired['scope'] }

            if ($setParams.Count -eq 1) {
                # Only Confirm was in params - nothing to change
                Write-DscTrace -Level Info -Message 'No configurable properties specified; nothing to set.'
            }
            else {
                Ensure-SecretStoreVaultRegistered
                try {
                    Set-SecretStoreConfiguration @setParams -ErrorAction Stop
                }
                catch {
                    if ($_.ToString() -match 'NonInteractive mode') {
                        # If SecretStore requires prompts, reset it with the desired settings so DSC can proceed unattended.
                        $resetParams = @{
                            Force   = $true
                            Confirm = $false
                        }

                        if ($setParams.ContainsKey('Authentication'))  { $resetParams['Authentication']  = $setParams['Authentication'] }
                        if ($setParams.ContainsKey('PasswordTimeout')) { $resetParams['PasswordTimeout'] = $setParams['PasswordTimeout'] }
                        if ($setParams.ContainsKey('Interaction'))     { $resetParams['Interaction']     = $setParams['Interaction'] }
                        if ($setParams.ContainsKey('Scope'))           { $resetParams['Scope']           = $setParams['Scope'] }

                        Write-DscTrace -Level Warn -Message (
                            'SecretStore requires interactive input; attempting Reset-SecretStore with desired settings to enable unattended DSC execution.'
                        )
                        Reset-SecretStore @resetParams -ErrorAction Stop
                    }
                    else {
                        throw
                    }
                }
                Write-DscTrace -Level Info -Message 'SecretStore configuration updated successfully.'
            }

            # Return the resulting state
            Get-CurrentState | ConvertTo-Json -Compress
        }
        catch {
            if ($_.ToString() -match 'NonInteractive mode') {
                Write-DscTrace -Level Error -Message (
                    "Set operation requires interactive input with the current SecretStore settings. " +
                    "Run this once in an interactive PowerShell session to allow unattended DSC runs: " +
                    "Set-SecretStoreConfiguration -Authentication None -Interaction None -PasswordTimeout -1 -Confirm:`$false"
                )
                exit 1
            }

            Write-DscTrace -Level Error -Message "Set operation failed: $_"
            exit 1
        }
    }

    'Test' {
        try {
            $current        = Get-CurrentState -SuppressNonInteractiveError
            $inDesiredState = $true

            if ($current['requiresInteractiveInput']) {
                Write-DscTrace -Level Info -Message (
                    'SecretStore currently requires interactive input, so it is not in the desired state for unattended DSC execution.'
                )
                $inDesiredState = $false
            }

            $propertyMap = @{
                authentication  = 'authentication'
                passwordTimeout = 'passwordTimeout'
                interaction     = 'interaction'
                scope           = 'scope'
            }

            foreach ($key in $propertyMap.Keys) {
                if ($desired.ContainsKey($key)) {
                    $desiredValue = $desired[$key]
                    $currentValue = $current[$key]

                    if ($current['requiresInteractiveInput']) {
                        continue
                    }

                    # Normalize integer comparison
                    if ($key -eq 'passwordTimeout') {
                        $desiredValue = [int]$desiredValue
                        $currentValue = [int]$currentValue
                    }

                    if ($currentValue -ne $desiredValue) {
                        Write-DscTrace -Level Info -Message (
                            "Property '$key' is not in desired state. " +
                            "Current: '$currentValue', Desired: '$desiredValue'."
                        )
                        $inDesiredState = $false
                    }
                }
            }

            $current['_inDesiredState'] = $inDesiredState
            $current | ConvertTo-Json -Compress
        }
        catch {
            Write-DscTrace -Level Error -Message "Test operation failed: $_"
            exit 1
        }
    }
}
