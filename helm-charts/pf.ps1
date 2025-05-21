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
#Get-Process -Id (Get-NetTCPConnection -LocalPort "8401").OwningProcess| Stop-Process
# --- CONFIGURATION ---
$Namespace = "affixzone-test-containers"
$ExcludeServices = @("svc-to-exclude1", "svc-to-exclude2")
$CustomServices = @(
    [PSCustomObject]@{
        name = "minio-service"
        mappings = @(
        # For example, this mapping applies only for the port where remotePort equals 9001.
            [PSCustomObject]@{ localPort = 9100; remotePort = 9000 }
        # You can add more mapping objects if needed.
        )
    },
    [PSCustomObject]@{
        name = "postgresql-service"
        mappings = @(
            [PSCustomObject]@{ localPort = 5400; remotePort = 5432 }
        )
    }
)
# --- END CONFIGURATION ---

# Hashtable: ServiceName => [PSCustomObject]@{ Proc = process; LocalPorts = @(ports) }
$PortForwardProcs = @{}

function Write-Colored($Message, $Color = 'White') {
    $colorCode = $PSStyle.Foreground.$Color
    Write-Host "$colorCode$Message$($PSStyle.Reset)"
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

    $mappingArray = @()
    $forwardedPorts = @()
    $customMapping = $CustomServices | Where-Object { $_.name -eq $svcName }
    foreach ($portDef in $svc.spec.ports) {
        $servicePort = $portDef.port
        $localPort = $servicePort
        $customForThisPort = $null
        if ($customMapping -and $customMapping.mappings) {
            $customForThisPort = $customMapping.mappings | Where-Object { $_.remotePort -eq $servicePort } | Select-Object -First 1
        }
        if ($customForThisPort) {
            $localPort = $customForThisPort.localPort
            $mappingArray += "$($customForThisPort.localPort):$($servicePort)"
        } else {
            $mappingArray += "$($servicePort):$($servicePort)"
        }
        $forwardedPorts += $localPort

        # Clean up any process already using this port
        Stop-ExistingPortForward -Port $localPort
    }

    $args = @("port-forward", "svc/$svcName")
    $args += $mappingArray
    $args += @("-n", $Namespace)

    Write-Colored "Starting port-forward for $svcName with mappings: $($mappingArray -join ' ')" "Green"

    $proc = Start-Process -FilePath "kubectl" -ArgumentList $args -PassThru -WindowStyle Hidden
    $PortForwardProcs[$svcName] = [PSCustomObject]@{
        Proc = $proc
        LocalPorts = $forwardedPorts
    }
}

if ($PortForwardProcs.Count -eq 0) {
    Write-Colored "No port-forwards started. Exiting." "Yellow"
    exit 0
}

Write-Colored ""
Write-Colored "----------------------------------------" "Cyan"
Write-Colored "Port forwarding is now running for the above services." "Cyan"
Write-Colored "Press Enter to stop all port-forward processes..." "Cyan"
Write-Colored "----------------------------------------" "Cyan"
[void][System.Console]::ReadLine()

Write-Colored "`n[Stop] Stopping all port-forward processes..." "Magenta"

# 1. Try to stop the port-forward processes started by this script
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

# 2. For **each forwarded port**, make sure no process is still listening; kill any stragglers
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

