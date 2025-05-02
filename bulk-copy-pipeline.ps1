<#
.SYNOPSIS
    Automates adding release-notes-creation-pipeline.yml to multiple repos
.DESCRIPTION
    This script will:
    1. Get all repos in the specified project
    2. Clone each repo
    3. Add the pipeline file
    4. Create a new branch
    5. Commit and push changes
    6. Create a pull request
#>

param(
    [string]$orgName = "your-org",
    [string]$projectName = "your-project",
    [string]$pat = "your-pat"
)

# Base64 encode PAT for authentication
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))

# API Headers
$headers = @{
    Authorization = "Basic $base64AuthInfo"
    "Content-Type" = "application/json"
}

# 1. Get all repositories in the project
$reposUrl = "https://dev.azure.com/$orgName/$projectName/_apis/git/repositories?api-version=7.1"
$repos = (Invoke-RestMethod -Uri $reposUrl -Headers $headers).value

# Pipeline file content
$pipelineContent = @"
# release-notes-creation-pipeline.yml
trigger: none  # Manual trigger only

resources:
  repositories:
    - repository: templates
      type: git
      name: DevOps_pro1/YourTemplatesRepo
      ref: main

jobs:
- template: release-notes-template.yml@templates
"@

foreach ($repo in $repos) {
    try {
        $repoName = $repo.name
        Write-Host "Processing repository: $repoName"
        
        # 2. Clone the repository
        $cloneUrl = $repo.remoteUrl -replace "://", "://$($pat)@"
        $tempDir = Join-Path $env:TEMP "ado_temp_$repoName"
        
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force
        }
        
        git clone $cloneUrl $tempDir
        Set-Location $tempDir
        
        # 3. Create new branch
        $branchName = "add/release-notes-pipeline"
        git checkout -b $branchName
        
        # 4. Add pipeline file
        $pipelinePath = Join-Path $tempDir "release-notes-creation-pipeline.yml"
        $pipelineContent | Out-File -FilePath $pipelinePath -Encoding utf8
        
        # 5. Commit and push
        git add .
        git commit -m "Add release notes generation pipeline"
        git push origin $branchName
        
        # 6. Create pull request
        $prBody = @{
            sourceRefName = "refs/heads/$branchName"
            targetRefName = "refs/heads/main"
            title = "Add release notes generation pipeline"
            description = "Automated PR: Adding standardized release notes generation pipeline"
        } | ConvertTo-Json
        
        $prUrl = "https://dev.azure.com/$orgName/$projectName/_apis/git/repositories/$repoName/pullrequests?api-version=7.1"
        $prResponse = Invoke-RestMethod -Uri $prUrl -Method Post -Headers $headers -Body $prBody
        
        Write-Host "Created PR #$($prResponse.pullRequestId) for $repoName"
        
        # Clean up
        Set-Location ..
        Remove-Item $tempDir -Recurse -Force
    }
    catch {
        Write-Host "Error processing $repoName`: $_" -ForegroundColor Red
        # Continue with next repo
    }
}

Write-Host "Completed processing all repositories"
