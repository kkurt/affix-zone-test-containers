<#
.SYNOPSIS
    Dynamically port-forwards services in a given namespace (configured in the script)
    excluding specified services and optionally applying custom port mappings for each port.

.DESCRIPTION
    This script defines a Kubernetes namespace, a list of service names to exclude, and an array
    of custom service mappings. Each custom service mapping has a name and a 'mappings' array,
    where each entry defines a localPort and a remotePort. For a service matching a custom mapping,
    the script will compare each defined service port (remote port) to the custom mapping's remotePort.
    If a match is found, that port is forwarded using the custom local port; otherwise, the default
    mapping (port:port) is used. Before starting new port-forward background jobs, the script cleans up
    any existing jobs with names starting with the namespace prefix. It then retrieves all services
    in the namespace and, for each service (excluding those filtered out), builds an array of port mappings
    and starts a background job that runs "kubectl port-forward" with all the mappings. When you press Enter,
    all port-forward jobs are stopped and removed.

.NOTES
    - Ensure that kubectl is installed and configured in your environment.
    - Adjust the variables $Namespace, $ExcludeServices, and $CustomServices as needed.
#>

# --- Configuration ---
# Set the target Kubernetes namespace
$Namespace = "affixzone-test-containers"

# Provide a list of service names to exclude. Leave as an empty array if no exclusions.
$ExcludeServices = @("svc-to-exclude1", "svc-to-exclude2")

# Define custom service port mappings.
# Each entry is an object with:
#   - name: the service name (must match exactly as deployed)
#   - mappings: an array of mapping objects where each mapping defines:
#         localPort: the desired local port
#         remotePort: the container (service) port to which the local port should forward.
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
# --- End Configuration ---

Write-Host "`nCleaning up any pre-existing port-forward jobs with the namespace prefix '$Namespace-'..."

# Find and stop existing jobs whose names start with the namespace prefix.
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

# Retrieve all services in the specified namespace as JSON and convert to a PowerShell object.
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

# Initialize an array to store new background jobs for port forwarding.
$jobs = @()

foreach ($svc in $servicesJson.items) {
    $svcName = $svc.metadata.name

    # Skip excluded services.
    if ($ExcludeServices -contains $svcName) {
        Write-Host "Skipping excluded service: $svcName"
        continue
    }

    # Verify that the service has at least one port defined.
    if (-not $svc.spec.ports -or $svc.spec.ports.Count -eq 0) {
        Write-Host "Service '$svcName' has no ports defined. Skipping port-forward."
        continue
    }

    # Build an array of port mappings for the service.
    $mappingArray = @()
    # Look up a custom mapping for this service (if any).
    $customMapping = $CustomServices | Where-Object { $_.name -eq $svcName }

    foreach ($portDef in $svc.spec.ports) {
        $servicePort = $portDef.port
        # Look for a custom mapping whose remotePort matches this service port.
        $customForThisPort = $null
        if ($customMapping -and $customMapping.mappings) {
            $customForThisPort = $customMapping.mappings | Where-Object { $_.remotePort -eq $servicePort } | Select-Object -First 1
        }

        if ($customForThisPort) {
            $mappingArray += "$($customForThisPort.localPort):$($servicePort)"
        }
        else {
            $mappingArray += "$($servicePort):$($servicePort)"
        }
    }

    Write-Host "Starting port-forward for service '$svcName' with mappings: $($mappingArray -join ' ')..."

    # Start a background job for the port-forward command.
    $jobName = "$Namespace-$svcName-forward"
    $job = Start-Job -Name $jobName -ScriptBlock {
        param($ns, $name, [string[]]$mappings)
        kubectl port-forward "svc/$name" $mappings -n $ns
    } -ArgumentList $Namespace, $svcName, $mappingArray

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
