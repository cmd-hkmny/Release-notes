<#
.SYNOPSIS
    Automates adding release-notes-creation-pipeline.yml to specified repos using System.AccessToken
#>

param(
    [string]$orgName = "your-org",
    [string]$projectName = "your-project",
    [string]$inputFilePath = "repos.csv"
)

# Use system access token (ensure 'Allow scripts to access OAuth token' is enabled in pipeline)
$accessToken = $env:SYSTEM_ACCESSTOKEN

if (-not $accessToken) {
    Write-Error "System.AccessToken not available. Make sure 'Allow scripts to access OAuth token' is enabled in the pipeline."
    exit 1
}

# Base64 encode token for REST API authentication
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$accessToken"))
$headers = @{
    Authorization = "Basic $base64AuthInfo"
    "Content-Type" = "application/json"
}

$pipelineContent = @"
# release-notes-creation-pipeline.yml
trigger: none
resources:
  repositories:
    - repository: templates
      type: git
      name: DevOps_pro1/YourTemplatesRepo
      ref: main
jobs:
- template: release-notes-template.yml@templates
"@

try {
    $repos = Import-Csv -Path $inputFilePath | Select-Object -ExpandProperty RepositoryName
    if (-not $repos -or $repos.Count -eq 0) {
        Write-Host "No repositories found in the input file." -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "Error reading input file: $_" -ForegroundColor Red
    exit 1
}

foreach ($repoName in $repos) {
    try {
        Write-Host "`nProcessing repository: $repoName"
        
        $encodedRepoName = [System.Web.HttpUtility]::UrlEncode($repoName)
        $repoUrl = "https://dev.azure.com/$orgName/$projectName/_apis/git/repositories/$encodedRepoName?api-version=7.1"

        Write-Host "Checking repository existence..."
        $repo = Invoke-RestMethod -Uri $repoUrl -Headers $headers -ErrorAction Stop
        $cloneUrl = $repo.remoteUrl

        # Use credential helper for Git to authenticate using System.AccessToken
        git config --global credential.helper store
        $creds = "@https://:$accessToken@dev.azure.com`n"
        $creds | Out-File "$env:USERPROFILE\.git-credentials" -Encoding ASCII

        $tempDir = Join-Path $env:TEMP "ado_temp_$repoName"
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }

        Write-Host "Cloning repository..."
        git clone $cloneUrl $tempDir
        Set-Location $tempDir

        git checkout -b "add/release-notes-pipeline"
        $pipelineContent | Out-File -FilePath "release-notes-creation-pipeline.yml" -Encoding utf8
        git add .
        git commit -m "Add release notes generation pipeline"
        git push origin "add/release-notes-pipeline"

        $prUrl = "https://dev.azure.com/$orgName/$projectName/_apis/git/repositories/$encodedRepoName/pullrequests?api-version=7.1"
        $prBody = @{
            sourceRefName = "refs/heads/add/release-notes-pipeline"
            targetRefName = "refs/heads/main"
            title = "Add release notes generation pipeline"
            description = "Automated PR: Adding standardized release notes generation pipeline"
        } | ConvertTo-Json -Depth 10

        $prResponse = Invoke-RestMethod -Uri $prUrl -Method Post -Headers $headers -Body $prBody
        Write-Host "Successfully created PR #$($prResponse.pullRequestId)" -ForegroundColor Green

        Set-Location ..
        Remove-Item $tempDir -Recurse -Force
    }
    catch {
        Write-Host "Error processing $repoName`: $_" -ForegroundColor Red
    }
}

Write-Host "`nCompleted processing all specified repositories" -ForegroundColor Cyan
