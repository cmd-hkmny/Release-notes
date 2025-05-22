<#
.SYNOPSIS
    Creates PROD stages by cloning PRE-PROD stages and updates configurations
.DESCRIPTION
    This script:
    1. Clones PRE-PROD stages to create PROD stages in specified pipelines
    2. Updates task configurations from a JSON config file (using ApiServer instead of Machines)
    3. Maintains proper stage ordering and validates results
#>

param(
    [string]$Org,
    [string]$Project,
    [string]$Pat,
    [string]$ApiVersion = "7.1-preview.4",
    [string[]]$PipelineIds,
    [string]$ConfigPath,
    [string]$ApprovalGroupId
)

# Set up authentication and headers
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{
    Authorization = "Basic $base64Auth"
    "Content-Type" = "application/json"
}

# Load configuration
$prodConfig = Get-Content $ConfigPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$baseUrl = "https://vsrm.dev.azure.com/$Org/$Project"

# Logging function
function Write-Log {
    param([string]$message, [string]$level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$level] $message"
    Write-Host $logEntry
    Add-Content -Path ".\DeploymentLog.log" -Value $logEntry
}

function Update-TaskConfiguration {
    param(
        [object]$task,
        [object]$config
    )

    if (-not $task -or -not $task.inputs) { return }

    # Update ApiServer if specified in config
    if ($config.ApiServer -and $task.inputs.PSObject.Properties['ApiServer']) {
        $task.inputs.ApiServer = $config.ApiServer
        Write-Log "Updated ApiServer for task $($task.name) to: $($config.ApiServer)"
    }

    # Update script arguments
    if ($task.inputs.PSObject.Properties['scriptArguments']) {
        $argsString = $task.inputs.scriptArguments
        
        # Handle ApiServer in script arguments if present
        if ($config.ApiServer) {
            if ($argsString -match "(-{1,2}ApiServer)\s+""[^""]*""") {
                $argsString = $argsString -replace "(-{1,2}ApiServer)\s+""[^""]*""", "`$1 ""$($config.ApiServer)"""
                Write-Log "Updated -ApiServer argument in task $($task.name)"
            }
            else {
                $argsString += " -ApiServer ""$($config.ApiServer)"""
                Write-Log "Added -ApiServer argument to task $($task.name)"
            }
        }

        # Update other parameters
        foreach ($property in $config.PSObject.Properties) {
            if ($property.Name -ne "ApiServer") {
                $pattern = "(-{1,2}$($property.Name))\s+""[^""]*"""
                if ($argsString -match $pattern) {
                    $argsString = $argsString -replace $pattern, "`$1 ""$($property.Value)"""
                    Write-Log "Updated argument $($property.Name) in task $($task.name)"
                }
                elseif (-not $argsString.Contains("-$($property.Name) ")) {
                    $argsString += " -$($property.Name) ""$($property.Value)"""
                    Write-Log "Added argument $($property.Name) to task $($task.name)"
                }
            }
        }
        
        $task.inputs.scriptArguments = $argsString.Trim()
    }
}

function Clone-Stage {
    param(
        [object]$sourceStage,
        [string]$newName
    )

    $newStage = $sourceStage | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $newStage.PSObject.Properties.Remove('id')
    $newStage.name = $newName

    # Update all tasks in the stage
    foreach ($phase in $newStage.deployPhases) {
        $phase.PSObject.Properties.Remove('phaseId')
        foreach ($task in $phase.workflowTasks) {
            $task.PSObject.Properties.Remove('id')
            Update-TaskConfiguration -task $task -config $prodConfig
        }
    }

    return $newStage
}

function Add-ProdStage {
    param([int]$pipelineId)

    try {
        $url = "$baseUrl/_apis/release/definitions/$pipelineId`?api-version=$ApiVersion"
        $pipeline = Invoke-RestMethod -Uri $url -Headers $headers -Method Get

        # Check if PROD stage already exists
        if ($pipeline.environments.name -contains 'prod') {
            Write-Log "Pipeline $pipelineId already has PROD stage - skipping" -level "WARN"
            return $false
        }

        # Find PRE-PROD stage
        $preProdStage = $pipeline.environments | Where-Object { $_.name -eq 'pre-prod' }
        if (-not $preProdStage) {
            Write-Log "No PRE-PROD stage found in pipeline $pipelineId - skipping" -level "WARN"
            return $false
        }

        # Clone PRE-PROD to create PROD
        $prodStage = Clone-Stage -sourceStage $preProdStage -newName "prod"

        # Insert PROD after PRE-PROD
        $environments = [System.Collections.ArrayList]@($pipeline.environments)
        $preProdIndex = $environments.IndexOf($preProdStage)
        $environments.Insert($preProdIndex + 1, $prodStage)

        # Update ranks
        for ($i = 0; $i -lt $environments.Count; $i++) {
            $environments[$i].rank = $i + 1
        }

        $pipeline.environments = $environments

        # Update the pipeline
        $updatedPipeline = Invoke-RestMethod -Uri $url -Headers $headers -Method Put `
            -Body ($pipeline | ConvertTo-Json -Depth 20)

        # Verify update
        $stageOrder = ($updatedPipeline.environments | Sort-Object rank | Select-Object -ExpandProperty name) -join " -> "
        Write-Log "Successfully updated pipeline $pipelineId. Stage order: $stageOrder"

        # Verify ApiServer was updated
        $prodStage = $updatedPipeline.environments | Where-Object { $_.name -eq 'prod' }
        foreach ($phase in $prodStage.deployPhases) {
            foreach ($task in $phase.workflowTasks) {
                if ($task.inputs.PSObject.Properties['ApiServer']) {
                    Write-Log "Task $($task.name) ApiServer: $($task.inputs.ApiServer)"
                }
                if ($task.inputs.scriptArguments -and $task.inputs.scriptArguments.Contains("ApiServer")) {
                    Write-Log "Task $($task.name) script arguments include ApiServer"
                }
            }
        }

        return $true
    }
    catch {
        Write-Log "ERROR processing pipeline $pipelineId : $($_.Exception.Message)" -level "ERROR"
        if ($_.ErrorDetails.Message) {
            Write-Log "Detailed error: $($_.ErrorDetails.Message)" -level "ERROR"
        }
        return $false
    }
}

# Main execution
Write-Log "Starting PROD stage creation process"
$successCount = 0

foreach ($id in $PipelineIds) {
    if (Add-ProdStage -pipelineId $id) {
        $successCount++
    }
}

Write-Log "Process completed. Successfully updated $successCount of $($PipelineIds.Count) pipelines"
exit ($successCount -eq $PipelineIds.Count ? 0 : 1)
--------------------------------------------------------------------------------------------------------------------------------
$healthCheckTask = @{
    taskId      = "e213ff0f-5d5c-4791-802d-52ea3e7be1f1"  # PowerShell@2
    version     = "2.*"
    name        = "HealthCheckAndRollback"
    enabled     = $true
    inputs      = @{
        targetType  = "inline"
        script      = @"
# Enable TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Configuration from parameters
`$servers = @('$($ApiServer -replace "'", "''")')
`$DeploymentRoot = '$($DeploymentRoot1 -replace "'", "''")'
`$WebApplicationName = '$($WebApplicationName -replace "'", "''")'
`$healthcheckurl = '$($healthcheckurl1 -replace "'", "''")'
`$timeoutSeconds = 20

# Debug output
Write-Host "Loaded configuration:"
Write-Host "Servers: `$servers"
Write-Host "Deployment Root: `$DeploymentRoot"
Write-Host "Web Application: `$WebApplicationName"
Write-Host "Healthcheck URL: `$healthcheckurl"

# Initialize counters
`$global:success = `$true
`$global:rollbackAttempted = `$false

function Invoke-HealthCheck {
    param (
        [string]`$server,
        [System.Management.Automation.PSCredential]`$cred
    )
    
    try {
        Write-Host "`n=== Health Check on `$server ==="
        
        # Create remote session
        `$sessionParams = @{
            ComputerName = `$server
            Credential = `$cred
            SessionOption = New-PSSessionOption -IdleTimeout ((`$timeoutSeconds + 5) * 1000)
            ErrorAction = 'Stop'
        }
        `$session = New-PSSession @sessionParams
        
        try {
            # Test basic connectivity first
            `$null = Invoke-Command -Session `$session -ScriptBlock { `$true } -ErrorAction Stop
            
            # Perform health check
            `$response = Invoke-Command -Session `$session -ScriptBlock {
                param(`$url, `$timeout)
                try {
                    Invoke-WebRequest -Uri `$url -UseBasicParsing -TimeoutSec `$timeout
                } catch {
                    # Return the exception details if the request fails
                    @{
                        StatusCode = 500
                        StatusDescription = `$_.Exception.Message
                    }
                }
            } -ArgumentList `$healthCheckUrl, `$timeoutSeconds
            
            if (`$response.StatusCode -eq 200) {
                Write-Host "[SUCCESS] Health check passed on `$server"
                return `$true
            } else {
                Write-Host "[FAILURE] Health check failed on `$server (Status: `$(`$response.StatusCode))"
                Write-Host "Response: `$(`$response.StatusDescription)"
                return `$false
            }
        }
        finally {
            if (`$session) { Remove-PSSession `$session -ErrorAction SilentlyContinue }
        }
    }
    catch {
        Write-Host "[ERROR] Connection/health check failed on `$server"
        Write-Host "Details: `$(`$_.Exception.Message)"
        return `$false
    }
}

function Invoke-Rollback {
    param (
        [string]`$server,
        [System.Management.Automation.PSCredential]`$cred
    )
    
    try {
        Write-Host "`n=== Attempting Rollback on `$server ==="
        
        `$sessionParams = @{
            ComputerName = `$server
            Credential = `$cred
            SessionOption = New-PSSessionOption -IdleTimeout 300000
            ErrorAction = 'Stop'
        }
        `$session = New-PSSession @sessionParams
        
        try {
            # Get available deployment folders
            `$folders = Invoke-Command -Session `$session -ScriptBlock {
                param(`$DeploymentRoot)
                Get-ChildItem -Path `$DeploymentRoot -Directory |
                    Where-Object { `$_.Name -match "^\d+(\.\d+)*_\d{8}\.\d{6}`$" } |
                    Sort-Object {
                        `$timestamp = `$_.Name.Split("_")[1]
                        [datetime]::ParseExact(`$timestamp, "ddMMyyyy.HHmmss", `$null)
                    } -Descending
            } -ArgumentList `$DeploymentRoot

            if (`$folders.Count -gt 1) {
                `$rollbackFolder = `$folders[1].FullName
                Write-Host "Found rollback candidate: `$rollbackFolder"
                
                # Perform the rollback
                `$rollbackResult = Invoke-Command -Session `$session -ScriptBlock {
                    param(`$rollbackFolder, `$WebApplicationName)
                    try {
                        `$sitePath = "IIS:\Sites\Default Web Site\`$WebApplicationName"
                        `$currentPath = (Get-ItemProperty -Path `$sitePath).physicalPath
                        
                        if (`$currentPath -ne `$rollbackFolder) {
                            Set-ItemProperty -Path `$sitePath -Name physicalPath -Value `$rollbackFolder
                            Write-Host "Rollback successful. Path changed from:"
                            Write-Host "`$currentPath"
                            Write-Host "to:"
                            Write-Host "`$rollbackFolder"
                            return `$true
                        } else {
                            Write-Host "Already pointing to rollback folder. No change needed."
                            return `$false
                        }
                    } catch {
                        Write-Host "Rollback failed: `$(`$_.Exception.Message)"
                        return `$false
                    }
                } -ArgumentList `$rollbackFolder, `$WebApplicationName
                
                if (`$rollbackResult) {
                    `$script:global:rollbackAttempted = `$true
                    Write-Host "[SUCCESS] Rollback completed on `$server"
                } else {
                    Write-Host "[WARNING] Rollback not performed on `$server"
                }
            } else {
                Write-Host "[ERROR] No suitable rollback folder found on `$server"
            }
        }
        finally {
            if (`$session) { Remove-PSSession `$session -ErrorAction SilentlyContinue }
        }
    }
    catch {
        Write-Host "[ERROR] Rollback failed on `$server"
        Write-Host "Details: `$(`$_.Exception.Message)"
    }
}

# Main execution
try {
    # Create credentials (passed as pipeline variables)
    `$securePassword = ConvertTo-SecureString "`$(AdminPassword)" -AsPlainText -Force
    `$cred = New-Object System.Management.Automation.PSCredential("`$(AdminUserName)", `$securePassword)
    
    # Perform health checks
    foreach (`$server in `$servers) {
        `$healthStatus = Invoke-HealthCheck -server `$server -cred `$cred
        if (-not `$healthStatus) {
            `$global:success = `$false
            Invoke-Rollback -server `$server -cred `$cred
        }
    }
    
    # Final status
    if (`$global:success) {
        Write-Host "`n[RESULT] All health checks passed successfully"
        exit 0
    } elseif (`$global:rollbackAttempted) {
        Write-Host "`n[RESULT] Health checks failed but rollback was attempted"
        exit 1
    } else {
        Write-Host "`n[RESULT] Health checks failed and rollback could not be completed"
        exit 1
    }
}
catch {
    Write-Host "`n[CRITICAL ERROR] Unexpected failure in health check process"
    Write-Host "Details: `$(`$_.Exception.Message)"
    exit 1
}
"@
    }
}
------------------------------------------------------------------------------------------------------------------------
