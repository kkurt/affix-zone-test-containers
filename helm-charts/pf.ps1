<#
.SYNOPSIS
    Dynamically port-forwards services in a given namespace (configured in the script)
    excluding a provided list of services.

.DESCRIPTION
    The script defines a Kubernetes namespace and a list of service names to exclude.
    Before starting new port-forward background jobs, it cleans up any existing jobs that have
    a name starting with the namespace prefix. It then retrieves all services in the namespace,
    filters out the excluded ones, and for each remaining service creates a background job (with
    a name composed of the namespace prefix and service name) that executes a port-forward command
    using the first defined port of the service. When you press Enter, all port-forward jobs are
    stopped and removed.

.NOTES
    - Ensure that `kubectl` is installed and configured in your environment.
    - Adjust the variables $Namespace and $ExcludeServices as needed.
    - The job names are created using the format "$Namespace-$svcName-forward".
#>

# --- Configuration ---
# Set the target Kubernetes namespace
$Namespace = "affixzone-test-containers"

# Provide a list of service names to exclude. Leave as empty array if no exclusions.
$ExcludeServices = @("svc-to-exclude1", "svc-to-exclude2")
# --- End Configuration ---

Write-Host "`nCleaning up any pre-existing port-forward jobs with the namespace prefix '$Namespace-'..."

# Find and stop existing jobs that have a name starting with the namespace prefix.
$existingJobs = Get-Job | Where-Object { $_.Name -like "$Namespace-*" }
if ($existingJobs) {
    foreach ($job in $existingJobs) {
        Write-Host "Stopping pre-existing job: $($job.Name) (ID: $($job.Id))"
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -ErrorAction SilentlyContinue
    }
    Write-Host "Pre-existing jobs cleaned up."
} else {
    Write-Host "No matching pre-existing jobs found."
}

Write-Host "`nRetrieving services from namespace '$Namespace'..."
if ($ExcludeServices.Count -gt 0) {
    Write-Host "Excluding services:" ($ExcludeServices -join ', ')
} else {
    Write-Host "No services will be excluded."
}

# Retrieve all services in the specified namespace as JSON and convert to a PowerShell object
try {
    $servicesJson = kubectl get svc -n $Namespace -o json | ConvertFrom-Json
} catch {
    Write-Error "Failed to retrieve services from namespace '$Namespace'. Please check your kubectl configuration."
    exit 1
}

if (-not $servicesJson.items) {
    Write-Host "No services found in namespace '$Namespace'. Exiting."
    exit 0
}

# Initialize an array to store new background jobs for port forwarding
$jobs = @()

foreach ($svc in $servicesJson.items) {
    $svcName = $svc.metadata.name

    # Skip excluded services
    if ($ExcludeServices -contains $svcName) {
        Write-Host "Skipping excluded service: $svcName"
        continue
    }

    # Verify that the service has at least one port defined
    if (-not $svc.spec.ports -or $svc.spec.ports.Count -eq 0) {
        Write-Host "Service '$svcName' has no ports defined. Skipping port-forward."
        continue
    }

    # Use the first defined port for port forwarding (local port equals target port)
    $targetPort = $svc.spec.ports[0].port
    $localPort = $targetPort

    Write-Host "Starting port-forward for service '$svcName' on local port $localPort (target port: $targetPort)..."

    # Start a background job for the port-forward command and name it using the namespace prefix and service name.
    $jobName = "$Namespace-$svcName-forward"
    $job = Start-Job -Name $jobName -ScriptBlock {
        param($ns, $name, $lPort, $tPort)
        kubectl port-forward "svc/$name" "$lPort`:$tPort" -n $ns
    } -ArgumentList $Namespace, $svcName, $localPort, $targetPort

    $jobs += $job
}

Write-Host ""
Write-Host "----------------------------------------"
Write-Host "Port forwarding is now running for the above services."
Write-Host "Press Enter to stop all port-forward jobs..."
Write-Host "----------------------------------------"
[void][System.Console]::ReadLine()

Write-Host "`nStopping port-forward jobs..."
foreach ($job in $jobs) {
    Write-Host "Stopping job $($job.Name) (ID: $($job.Id))..."
    try {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -ErrorAction SilentlyContinue
    } catch {
        Write-Host "Error stopping job $($job.Name) (ID: $($job.Id)): $_"
    }
}

Write-Host "All port-forward jobs have been stopped and removed."
