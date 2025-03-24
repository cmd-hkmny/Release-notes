import requests
import json
import base64

# Set Azure DevOps Variables
ORG = "chand1502877"
PROJECT = "DevOps_pro1"
PAT = "AMNGntv1LLRpLKlNL82zFDouDPYm5fu6fsFzl3GC0jTx80cHNMqQJQQJ99BBACAAAAAMVcP5AAASAZDO1Dur"
API_VERSION = "7.1-preview.4"
BASE_URL = f"https://vsrm.dev.azure.com/{ORG}/{PROJECT}/_apis/release"


# Debug mode: Set to True for detailed logs
DEBUG_MODE = True

# Authentication
AUTH = base64.b64encode(f":{PAT}".encode()).decode()
HEADERS = {
    "Authorization": f"Basic {AUTH}",
    "Content-Type": "application/json"
}

def debug_log(message):
    """Prints debug logs if DEBUG_MODE is enabled."""
    if DEBUG_MODE:
        print(f"🛠 DEBUG: {message}")

# Get all release pipelines
def get_release_pipelines():
    url = f"{BASE_URL}/definitions?api-version={API_VERSION}"
    debug_log(f"Fetching all release pipelines: {url}")
    response = requests.get(url, headers=HEADERS)

    if response.status_code != 200:
        print(f"❌ Failed to fetch pipelines. Status Code: {response.status_code}")
        print(f"Response: {response.text}")
        return []

    pipelines = response.json().get("value", [])
    debug_log(f"Found {len(pipelines)} pipelines.")
    return pipelines

# Add PROD stage after PreProd with Approval
def add_prod_stage_with_approval(pipeline_id):
    url = f"{BASE_URL}/definitions/{pipeline_id}?api-version={API_VERSION}"
    debug_log(f"Fetching pipeline {pipeline_id}: {url}")
    
    response = requests.get(url, headers=HEADERS)
    if response.status_code != 200:
        print(f"❌ Failed to fetch pipeline {pipeline_id}. Status Code: {response.status_code}")
        print(f"Response: {response.text}")
        return

    pipeline = response.json()
    environments = pipeline.get("environments", [])

    # Print pipeline details before modification
    debug_log(f"Pipeline {pipeline_id} Environments (before modification): {[env['name'] for env in environments]}")

    # Find PreProd stage
    preprod_stage = next((env for env in environments if env["name"].lower() == "pre-prod"), None)

    if not preprod_stage:
        print(f"⚠️ No PreProd stage found in pipeline {pipeline_id}. Skipping...")
        return

    # Clone PreProd into PROD
    prod_stage = json.loads(json.dumps(preprod_stage))  # Deep copy
    prod_stage["name"] = "PROD"
    prod_stage["id"] = 0  # Set to 0 so Azure creates a new stage

    # ✅ FIX: Ensure a valid approver is added
    APPROVER_ID = "chand1502877@mastek.com"  # Replace with an actual Azure DevOps user ID

    if APPROVER_ID:
        prod_stage["preDeployApprovals"] = {
            "approvals": [
                {
                    "rank": 1,
                    "isAutomated": False,  # Manual Approval Required
                    "approver": {"id": APPROVER_ID},  # Ensure approver ID is valid
                    "status": "pending"
                }
            ],
            "approvalOptions": {
                "releaseCreatorCanBeApprover": False,
                "autoTriggeredAndPreviousEnvironmentApprovedCanBeSkipped": False,
                "enforceIdentityRevalidation": True
            }
        }
    else:
        print("⚠️ No valid approver ID found. Setting approval to automated.")
        prod_stage["preDeployApprovals"] = {
            "approvals": [],
            "approvalOptions": {
                "releaseCreatorCanBeApprover": False,
                "autoTriggeredAndPreviousEnvironmentApprovedCanBeSkipped": True,
                "enforceIdentityRevalidation": False
            }
        }

    # Insert PROD after PreProd
    index = environments.index(preprod_stage)
    environments.insert(index + 1, prod_stage)

    # ✅ Fix: Assign correct ranks to all stages (avoids VS402874 error)
    for i, env in enumerate(environments, start=1):
        env["rank"] = i  # Ensures ranks are 1, 2, 3, 4...

    # Print pipeline details after modification
    debug_log(f"Pipeline {pipeline_id} Environments (after modification): {[env['name'] for env in environments]}")

    # Update pipeline
    pipeline["environments"] = environments
    update_url = f"{BASE_URL}/definitions/{pipeline_id}?api-version={API_VERSION}"
    debug_log(f"Updating pipeline {pipeline_id}: {update_url}")

    response = requests.put(update_url, headers=HEADERS, data=json.dumps(pipeline))

    if response.status_code == 200:
        print(f"✅ PROD stage with approval added successfully to pipeline {pipeline_id}")
    else:
        print(f"❌ Failed to update pipeline {pipeline_id}. Status Code: {response.status_code}")
        print(f"Response: {response.text}")

# Main execution
pipelines = get_release_pipelines()

if not pipelines:
    print("⚠️ No Classic Release Pipelines found! Exiting...")
else:
    for pipeline in pipelines:
        add_prod_stage_with_approval(pipeline["id"])
