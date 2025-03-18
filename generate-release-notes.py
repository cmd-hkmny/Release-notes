# Prerequisites:
# Install the required libraries using pip:
# pip install requests gitpython

import os
import requests
import base64
from git import Repo

# Define variables
organization = os.getenv("SYSTEM_TEAMFOUNDATIONCOLLECTIONURI").rstrip("/").replace("https://dev.azure.com/", "")
project = os.getenv("SYSTEM_TEAMPROJECT")
repo_id = os.getenv("BUILD_REPOSITORY_ID")
branch = os.getenv("BUILD_SOURCEBRANCH")  # e.g., refs/heads/release/v1.1.0
access_token = "AMNGntv1LLRpLKlNL82zFDouDPYm5fu6fsFzl3GC0jTx80cHNMqQJQQJ99BBACAAAAAMVcP5AAASAZDO1Dur"
output_file = os.path.join(os.getenv("BUILD_ARTIFACTSTAGINGDIRECTORY"), "ReleaseNotes.md")
repo_path = os.getenv("BUILD_SOURCESDIRECTORY")
git_user = os.getenv("BUILD_REQUESTEDFOR", "chandra batte")
git_email = os.getenv("BUILD_REQUESTEDFOREMAIL", "chand1502877@mastek.com")


# Encode the project name to handle spaces
import urllib.parse
encoded_project = urllib.parse.quote(project)

# Convert access token to base64 for authentication
base64_auth_info = f":{access_token}".encode("ascii")
base64_auth_info = base64.b64encode(base64_auth_info).decode("ascii")

# Headers for API requests
headers = {
    "Authorization": f"Basic {base64_auth_info}",
    "Content-Type": "application/json"
}

# Function to invoke REST API with error handling
def invoke_azure_devops_api(uri):
    try:
        print(f"Making API request to: {uri}")
        response = requests.get(uri, headers=headers)
        response.raise_for_status()
        print(f"API response: {response.text}") 
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"##vso[task.logissue type=error] Failed to invoke REST API: {uri}")
        print(f"##vso[task.logissue type=error] Error: {e}")
        return None

# Initialize Git repository
repo = Repo(repo_path)

# Fetch the latest tag
try:
    repo.git.fetch("--tags")
    latest_tag = repo.git.describe("--tags", "--abbrev=0")
    print(f"Latest release tag: {latest_tag}")
except Exception as e:
    print(f"##vso[task.logissue type=warning] No release tags found. Using initial commit.")
    latest_tag = repo.git.rev_list("--max-parents=0", "HEAD")  # Get the initial commit
    print(f"Using initial commit: {latest_tag}")

# Fetch commits since the latest release
commits_uri = f"https://dev.azure.com/{organization}/{encoded_project}/_apis/git/repositories/{repo_id}/commits?searchCriteria.itemVersion={branch}&searchCriteria.compareVersion={latest_tag}&api-version=7.1-preview.1"
commits = invoke_azure_devops_api(commits_uri)

# Check if commits were fetched successfully
if not commits or not commits.get("value"):
    print(f"##vso[task.logissue type=warning] No commits found since the latest release: {latest_tag}")
    commits = {"value": []}

# Initialize release notes content
release_notes = f"# Release Notes for Branch: {branch}\n\n"
release_notes += f"## Changes since {latest_tag}\n\n"

# Add associated work items
release_notes += "### Associated Work Items\n"
work_items = []
for commit in commits["value"]:
    commit_id = commit["commitId"]
    commit_work_items_uri = f"https://dev.azure.com/{organization}/{encoded_project}/_apis/git/repositories/{repo_id}/commits/{commit_id}/workItems?api-version=7.1-preview.1"
    commit_work_items = invoke_azure_devops_api(commit_work_items_uri)

    # Check if work items were fetched successfully
    if commit_work_items and commit_work_items.get("value"):
        for work_item in commit_work_items["value"]:
            work_items.append(work_item)
    else:
        print(f"##vso[task.logissue type=warning] No work items found for commit: {commit_id}")

# Remove duplicate work items
unique_work_items = {item["id"]: item for item in work_items}.values()
if unique_work_items:
    for work_item in unique_work_items:
        release_notes += f"- {work_item['id']}: {work_item['fields']['System.Title']} ({work_item['fields']['System.WorkItemType']})\n"
else:
    release_notes += "No work items found.\n"

# Add associated PRs
release_notes += "\n### Associated Pull Requests\n"
prs_uri = f"https://dev.azure.com/{organization}/{encoded_project}/_apis/git/repositories/{repo_id}/pullrequests?searchCriteria.targetRefName={branch}&api-version=7.1-preview.1"
prs = invoke_azure_devops_api(prs_uri)

# Check if PRs were fetched successfully
if prs and prs.get("value"):
    for pr in prs["value"]:
        release_notes += f"- PR {pr['pullRequestId']}: {pr['title']}\n"
else:
    release_notes += "No pull requests found.\n"

# Save release notes to a file
# Save release notes to a file in the repository root
output_file = os.path.join(repo_path, "ReleaseNotes.md")

try:
    with open(output_file, "w", encoding="utf-8") as file:
        file.write(release_notes)
    print(f"Release notes saved to: {output_file}")
except Exception as e:
    print(f"##vso[task.logissue type=error] Failed to save release notes to: {output_file}")
    print(f"##vso[task.logissue type=error] Error: {e}")
    exit(1)

# print the release notes
print(f"{release_notes}")

# Format the remote URL with the token for Git authentication
remote_url = f"https://{access_token}@dev.azure.com/{organization}/{project}/_git/{repo_id}"
repo.git.remote("set-url", "origin", remote_url)


# Check if branch exists locally; create it if necessary
try:
    # Set the Git config (use --local instead of --global)
    repo.git.config("--local", "user.name", git_user)
    repo.git.config("--local", "user.email", git_email)
    current_branch = repo.git.rev_parse("--abbrev-ref", "HEAD")
    if current_branch != branch.replace("refs/heads/", ""):
        repo.git.checkout("-b", branch.replace("refs/heads/", ""))
except Exception as e:
    print(f"##vso[task.logissue type=error] Failed to detect or create branch.")
    print(f"##vso[task.logissue type=error] Error: {e}")
    exit(1)

# Stage and commit
try:
    # Set the Git config (use --local instead of --global)
    repo.git.config("--local", "user.name", git_user)
    repo.git.config("--local", "user.email", git_email)
    
    # Fetch the latest changes to avoid conflicts
    repo.git.fetch("origin", branch.replace("refs/heads/", ""))

    repo.git.add(output_file)
    repo.git.commit("-m", f"Automated update: Added release notes for branch {branch} [skip ci]")

    # Push and set upstream using the token-based URL
    repo.git.push("--set-upstream", "origin", branch.replace("refs/heads/", ""), "--force-with-lease")

    print("Release notes pushed to repository.")
except Exception as e:
    print(f"##vso[task.logissue type=error] Failed to push release notes to repository.")
    print(f"##vso[task.logissue type=error] Error: {e}")
    exit(1)

