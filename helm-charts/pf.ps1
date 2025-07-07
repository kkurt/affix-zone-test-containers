<#
.SYNOPSIS
    Kubernetes port-forward automation with process and port cleanup and colored output.
.DESCRIPTION
    - Starts port-forward for all services (excluding specified) with optional custom port mappings.
    - Before starting, stops any process using the intended local port.
    - When stopping, kills any process using those ports (even if not started by this script).
    - Colored status output (PowerShell 7+).
.NOTES
    Requires PowerShell 7+ and kubectl.
#>

# --- CONFIGURATION ---
$Namespace = "affixzone-test-containers"
$ExcludeServices = @("svc-to-exclude1", "svc-to-exclude2")
#$ExcludeServices = @("int-service", "affix-zone-web","int-def-service")
$CustomServices = @(
    [PSCustomObject]@{
        name = "postgresql-service"
        mappings = @(
            [PSCustomObject]@{ localPort = 5400; remotePort = 5432 }
        )
    }
)
# --- END CONFIGURATION ---

# Hashtable: ServiceName => PSCustomObject with process info and ports
$PortForwardProcs = @{}

function Write-Colored($Message, $Color = 'White') {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSStyle) {
        $colorCode = $PSStyle.Foreground.$Color
        Write-Host "$colorCode$logMessage$($PSStyle.Reset)"
    } else {
        Write-Host $logMessage -ForegroundColor $Color
    }
}

function Stop-ExistingPortForward {
    param([int]$Port)
    $tcp = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($tcp) {
        $pids = $tcp | Select-Object -ExpandProperty OwningProcess -Unique
        foreach ($processId in $pids) {
            try {
                $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($proc) {
                    Write-Colored "Stopping existing process (PID: $processId) on port $Port..." "Yellow"
                    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
                    Write-Colored "Stopped existing process (PID: $processId) on port $Port." "Green"
                }
            } catch {
                Write-Colored "Failed to stop process (PID: $processId) on port ${Port}: $_" "Red"
            }
        }
    }
}

Write-Colored "`nRetrieving services from namespace '$Namespace'..." "Cyan"
if ($ExcludeServices.Count -gt 0) {
    Write-Colored "Excluding services: $($ExcludeServices -join ', ')" "Cyan"
} else {
    Write-Colored "No services will be excluded." "Cyan"
}

try {
    $servicesJson = kubectl get svc -n $Namespace -o json | ConvertFrom-Json
} catch {
    Write-Colored "Failed to retrieve services from namespace '$Namespace'. Please check your kubectl configuration." "Red"
    exit 1
}
if (-not $servicesJson.items) {
    Write-Colored "No services found in namespace '$Namespace'. Exiting." "Yellow"
    exit 0
}

# Track used local ports to avoid conflicts across services
$usedPorts = [System.Collections.Generic.HashSet[int]]::new()

foreach ($svc in $servicesJson.items) {
    $svcName = $svc.metadata.name
    if ($ExcludeServices -contains $svcName) {
        Write-Colored "Skipping excluded service: $svcName" "Yellow"
        continue
    }
    if (-not $svc.spec.ports -or $svc.spec.ports.Count -eq 0) {
        Write-Colored "Service '$svcName' has no ports defined. Skipping." "Yellow"
        continue
    }

    $mappingArray   = @()
    $forwardedPorts = @()
    $customMapping  = $CustomServices | Where-Object { $_.name -eq $svcName }
    foreach ($portDef in $svc.spec.ports) {
        $servicePort = $portDef.port
        $localPort   = $servicePort
        $customForThisPort = $null
        if ($customMapping -and $customMapping.mappings) {
            $customForThisPort = $customMapping.mappings | Where-Object { $_.remotePort -eq $servicePort } | Select-Object -First 1
        }
        if ($customForThisPort) {
            $localPort = $customForThisPort.localPort
        }
        # If this port is already forwarded by a previous service, skip it to avoid conflict
        if ($usedPorts.Contains($localPort)) {
            Write-Colored "Skipping port-forward for ${svcName}: local port $localPort already forwarded by another service. Skipping." "Yellow"
            continue
        }
        # Add this port mapping to the list (local:remote)
        $mappingArray += "$($localPort):$($servicePort)"
        $forwardedPorts += $localPort
        $usedPorts.Add($localPort) | Out-Null

        # Clean up any existing process on this port, then brief pause to ensure it's free
        Stop-ExistingPortForward -Port $localPort
        # Brief pause to ensure port is free before starting new port-forward
        Start-Sleep -Milliseconds 100
    }

    if ($mappingArray.Count -eq 0) {
        Write-Colored "Skipping service ${svcName}: no available local ports to forward (all ports conflict or none specified)." "Yellow"
        continue
    }

    # Build the kubectl port-forward command arguments
    $args = @("port-forward", "svc/$svcName")
    $args += $mappingArray
    $args += @("-n", $Namespace)

    Write-Colored "Starting port-forward for $svcName with mappings: $($mappingArray -join ' ')" "Green"

    $proc = Start-Process -FilePath "kubectl" -ArgumentList $args -PassThru -WindowStyle Hidden
    $PortForwardProcs[$svcName] = [PSCustomObject]@{
        Proc         = $proc
        LocalPorts   = $forwardedPorts
        Args         = $args
        RestartCount = 0
    }
}

if ($PortForwardProcs.Count -eq 0) {
    Write-Colored "No port-forwards started. Exiting." "Yellow"
    exit 0
}

Write-Colored "----------------------------------------" "Cyan"
Write-Colored "Port forwarding is now running for the above services." "Cyan"
Write-Colored "Port-forward processes will be automatically restarted if they exit unexpectedly." "Cyan"
Write-Colored "Press Enter to stop all port-forward processes..." "Cyan"
Write-Colored "----------------------------------------" "Cyan"

# Monitor port-forward processes and restart if they exit unexpectedly
$stopRequested = $False
while (-not $stopRequested) {
    if ([System.Console]::KeyAvailable) {
        $key = [System.Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
            $stopRequested = $True
            break
        }
    }
    foreach ($svcName in $PortForwardProcs.Keys) {
        $proc = $PortForwardProcs[$svcName].Proc
        if ($proc -and $proc.HasExited) {
            # Port-forward process exited unexpectedly
            $PortForwardProcs[$svcName].RestartCount += 1
            $exitCode = $proc.ExitCode
            Write-Colored "Port-forward for $svcName exited (code $exitCode). Restarting (attempt $($PortForwardProcs[$svcName].RestartCount))..." "Yellow"
            # Restart the kubectl port-forward process
            $PortForwardProcs[$svcName].Proc = Start-Process -FilePath "kubectl" -ArgumentList $PortForwardProcs[$svcName].Args -PassThru -WindowStyle Hidden
            Start-Sleep -Milliseconds 500  # short delay to let new process initialize

        }
    }
    Start-Sleep -Seconds 1
}

Write-Colored "`n[Stop] Stopping all port-forward processes..." "Magenta"

# 1. Stop all port-forward processes started by this script
foreach ($svcName in $PortForwardProcs.Keys) {
    $procInfo = $PortForwardProcs[$svcName]
    $proc = $procInfo.Proc
    if ($proc -and -not $proc.HasExited) {
        Write-Colored "Stopping process for $svcName (PID: $($proc.Id))..." "Yellow"
        try {
            Stop-Process -Id $proc.Id -ErrorAction Stop

            # Wait until process exits (up to 20s)
            $maxWait = 20
            $interval = 0.5
            $elapsed = 0
            while (-not $proc.HasExited -and $elapsed -lt $maxWait) {
                Start-Sleep -Seconds $interval
                $elapsed += $interval
            }

            if ($proc.HasExited) {
                Write-Colored "Stopped:  $svcName (PID: $($proc.Id))" "Green"
            } else {
                Write-Colored "Timeout waiting for: $svcName (PID: $($proc.Id)), may still be running!" "Red"
            }
        } catch {
            Write-Colored "Error stopping: $svcName (PID: $($proc.Id)): $_" "Red"
        }
    } else {
        Write-Colored "Already exited: $svcName (PID: $($proc.Id))" "DarkGray"
    }
}

# 2. Ensure no stray processes remain listening on forwarded ports; kill any stragglers
$allForwardedPorts = $PortForwardProcs.Values | ForEach-Object { $_.LocalPorts } | Select-Object -Unique
foreach ($port in $allForwardedPorts) {
    $tcp = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
    if ($tcp) {
        $pids = $tcp | Select-Object -ExpandProperty OwningProcess -Unique
        foreach ($processId in $pids) {
            try {
                $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($proc) {
                    Write-Colored "Final cleanup: Stopping process (PID: $processId) still using port $port..." "Yellow"
                    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
                    Write-Colored "Final cleanup: Stopped process (PID: $processId) on port $port." "Green"
                }
            } catch {
                Write-Colored "Final cleanup: Failed to stop process (PID: $processId) on port ${port}: $_" "Red"
            }
        }
    }
}

Write-Colored "All port-forward processes and port listeners have been stopped." "Green"
