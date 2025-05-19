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
