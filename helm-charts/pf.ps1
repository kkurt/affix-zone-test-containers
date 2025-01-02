# Traefik port-forwarding script for Kubernetes
# kubectl port-forward -n kube-system $(kubectl -n kube-system get pods --selector "app.kubernetes.io/name=traefik" --output=name | ForEach-Object { $_.Substring(4) }) 8080:9000
# Define the Kubernetes namespace
$namespace = "affixzone-test-containers"

# Define the array of services with their respective ports
$services = @(
    @{ Name = "oracle-service"; Port = "1521"; fwPort = "5300" },
    @{ Name = "cassandra-service"; Port = "9042"; fwPort = "5500" },
    @{ Name = "postgresql-service"; Port = "5432"; fwPort = "5400" },
    @{ Name = "kafka-service"; Port = "9092"; fwPort = "9092" },
    @{ Name = "kafka-ui"; Port = "8080"; fwPort = "8080" }
# Add more services here as needed
)

# List to keep track of started processes
$processes = @()

# Function to stop all port-forwarding processes gracefully
function Stop-PortForwarding {
    Write-Host "`nStopping all port-forwarding sessions..."
    foreach ($proc in $processes) {
        if (!$proc.HasExited) {
            $proc.Kill()
        }
    }
    Write-Host "All port-forwarding sessions stopped."
    # Unregister the event subscription
    Unregister-Event -SourceIdentifier 'CtrlCHandler' -ErrorAction SilentlyContinue
    exit
}

# Register the Ctrl+C event handler using Register-ObjectEvent
$null = Register-ObjectEvent -InputObject [Console] -EventName 'CancelKeyPress' -SourceIdentifier 'CtrlCHandler' -Action {
    Stop-PortForwarding
}

# Start port-forwarding for each service
foreach ($service in $services) {
    $name = $service.Name
    $servicePort = $service.Port
    $fwPort = $service.fwPort

    # Check if the service exists
    $kubectlOutput = kubectl get svc $name -n $namespace 2>&1

    if ($kubectlOutput -match "Error from server") {
        Write-Host "Service $name not found in namespace $namespace. Skipping."
    } else {
        Write-Host "Starting port-forwarding for $name on port $servicePort..."

        $process = Start-Process -FilePath "kubectl" -ArgumentList "port-forward svc/$name $fwPort`:$servicePort -n $namespace" -NoNewWindow -PassThru
        $processes += $process
    }
}

# Keep the script running and wait for Ctrl+C to stop
Write-Host "Press Ctrl+C to stop all port-forwarding sessions."

while ($true) {
    Start-Sleep -Seconds 1
}
