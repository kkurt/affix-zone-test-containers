
$Namespace = "affixzone-test-containers"

$services = @(
@{ ServiceName = "oracle-service"; LocalPort = "1521"; RemotePort = "5300" }
#@{ Name = "cassandra-service"; Port = "9042"; fwPort = "5500" },
#@{ Name = "postgresql-service"; Port = "5432"; fwPort = "5400" },
#@{ Name = "kafka-service"; Port = "9092"; fwPort = "9092" },
#@{ Name = "kafka-ui"; Port = "8080"; fwPort = "8080" }
    #@{ ServiceName = "minio-service"; LocalPort = "9000"; RemotePort = "9000" }
    #@{ ServiceName = "minio-service"; LocalPort = "9001"; RemotePort = "9001" }
# Add more services here as needed
)

# Directory to store logs
$logDir = "$env:TEMP\affixzone-logs"
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory | Out-Null
}

# Cleanup previous jobs
function Cleanup-PortForwardJobs {
    Get-Job -Name "affix_zone_*" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Stopping and removing job: $($_.Name)"
        Stop-Job -Job $_ -ErrorAction SilentlyContinue
        Remove-Job -Job $_ -ErrorAction SilentlyContinue
    }
}


# Start initial cleanup
Cleanup-PortForwardJobs

# Function to start port-forward jobs
function Start-PortForwardJob($service) {
    $jobName = "affix_zone_$($service.ServiceName)"
    $logFile = "$logDir\$($service.ServiceName).log"

    Write-Host "Starting job $jobName forwarding local port $($service.LocalPort) -> remote port $($service.RemotePort)"

    Start-Job -Name $jobName -ScriptBlock {
        param($serviceName, $localPort, $remotePort, $namespace, $logFile)

        while ($true) {
            kubectl port-forward svc/$serviceName "$localPort`:$remotePort" -n $namespace *> $logFile
            Start-Sleep -Seconds 2 # wait before retrying in case of failure
        }
    } -ArgumentList $service.ServiceName, $service.LocalPort, $service.RemotePort, $Namespace, $logFile
}

# Start jobs for each service
$services | ForEach-Object { Start-PortForwardJob $_ }

Write-Host "Port forwarding active. Press Enter to terminate."

# Monitoring loop: Restart jobs if needed
while ($true) {
    if ([Console]::KeyAvailable -and ([Console]::ReadKey($true)).Key -eq 'Enter') {
        break
    }

    foreach ($svc in $services) {
        $result = Test-NetConnection -ComputerName localhost -Port $svc.LocalPort -WarningAction SilentlyContinue

        if (-not $result.TcpTestSucceeded) {
            Write-Warning "Port $($svc.LocalPort) forwarding failed. Restarting..."
            $jobName = "affix_zone_$($svc.ServiceName)"
            Cleanup-PortForwardJobs
            Start-PortForwardJob $svc
        }
    }

    Start-Sleep -Seconds 1
}

# Final cleanup
Write-Host "Cleaning up port-forward jobs..."
Cleanup-PortForwardJobs

Write-Host "All jobs cleaned up. Exiting."