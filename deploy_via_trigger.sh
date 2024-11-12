#!/bin/bash
# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# You may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o pipefail
set -e  # Exit on any command failure for debugging

handle_error() {
    local exit_code=$?
    echo "Script encountered an error at line $LINENO with exit code $exit_code"
    exit $exit_code
}
trap 'handle_error' ERR

while getopts p: flag
do
    case "${flag}" in
        p) PROJECT_ID=${OPTARG};;
        *) echo "usage: $0 [-p PROJECT_ID]" >&2
           exit 1 ;;
    esac
done

if [ -z "$PROJECT_ID" ]; then
    echo "Failed to read the project id, exiting now!"
    exit 1
fi

SOLUTION_ID="ecommerce-platform-serverless"

IM_SUPPORTED_REGIONS=("us-central1")

for REGION in "${IM_SUPPORTED_REGIONS[@]}"; do
    echo "Checking for deployment in region: ${REGION}"
    DEPLOYMENT_NAME=$(gcloud infra-manager deployments list --location "${REGION}" \
                        --filter="labels.goog-solutions-console-deployment-name:* AND \
                        labels.goog-solutions-console-solution-id:${SOLUTION_ID}" \
                        --format='value(name)' || true)
    echo "DEPLOYMENT NAME ${DEPLOYMENT_NAME}"
    if [ -n "$DEPLOYMENT_NAME" ]; then
        echo "Found deployment: ${DEPLOYMENT_NAME} in region ${REGION}"
        break
    fi
done

# if [ -z "$DEPLOYMENT_NAME" ]; then
#     echo "Failed to find the existing deployment, exiting now!"
#     exit 1
# fi

DEPLOYMENT_NAME="dynamic-web-app"

echo "Project ID is ${PROJECT_ID}"
echo "Region is ${REGION}"
echo "Deployment name is ${DEPLOYMENT_NAME}"

SERVICE_ACCOUNT=$(gcloud infra-manager deployments describe "${DEPLOYMENT_NAME}" --location "${REGION}" --format='value(serviceAccount)')
if [ -z "$SERVICE_ACCOUNT" ]; then
    echo "Failed to retrieve service account for deployment ${DEPLOYMENT_NAME}"
    exit 1
fi
echo "Service Account: ${SERVICE_ACCOUNT}"

echo "Assigning required roles to the service account ${SERVICE_ACCOUNT}"
if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    apt-get update && apt-get install -y jq
fi

CURRENT_POLICY=$(gcloud projects get-iam-policy "${PROJECT_ID}" --format=json)
MEMBER_EMAIL=$(echo "${SERVICE_ACCOUNT}" | awk -F '/' '{print $NF}')
MEMBER="serviceAccount:${MEMBER_EMAIL}"

while IFS= read -r role || [[ -n "$role" ]]; do
    if echo "$CURRENT_POLICY" | jq -e --arg role "$role" --arg member "$MEMBER" '.bindings[] | select(.role == $role) | .members[] | select(. == $member)' > /dev/null; then
        echo "IAM policy binding already exists for member ${MEMBER} and role ${role}"
    else
        echo "Adding IAM policy binding for ${MEMBER} with role ${role}"
        gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="$MEMBER" \
        --role="$role" \
        --condition=None || { echo "Failed to add IAM policy binding for ${role}"; exit 1; }
    fi
done < "roles.txt"

DEPLOYMENT_DESCRIPTION=$(gcloud infra-manager deployments describe "${DEPLOYMENT_NAME}" --location "${REGION}" --format json)
cat <<EOF > input.tfvars
region="$(echo "$DEPLOYMENT_DESCRIPTION" | jq -r '.terraformBlueprint.inputValues.region.inputValue')"
project_id = "${PROJECT_ID}"
labels = {
  "goog-solutions-console-deployment-name" = "${DEPLOYMENT_NAME}",
  "goog-solutions-console-solution-id" = "${SOLUTION_ID}"
}
EOF

echo "Creating the cloud storage bucket if it does not exist already"
BUCKET_NAME="${PROJECT_ID}_infra_manager_staging"
if ! gsutil ls "gs://$BUCKET_NAME" &> /dev/null; then
    gsutil mb "gs://$BUCKET_NAME/" || { echo "Failed to create bucket $BUCKET_NAME"; exit 1; }
    echo "Bucket $BUCKET_NAME created successfully."
else
    echo "Bucket $BUCKET_NAME already exists."
fi

echo "Deploying the solution"
gcloud infra-manager deployments apply projects/"${PROJECT_ID}"/locations/"${REGION}"/deployments/"${DEPLOYMENT_NAME}" \
--service-account "${SERVICE_ACCOUNT}" --local-source="infra" --inputs-file="input.tfvars" \
--labels="modification-reason=make-it-mine,goog-solutions-console-deployment-name=${DEPLOYMENT_NAME},goog-solutions-console-solution-id=${SOLUTION_ID},goog-config-partner=sc" || { echo "Deployment failed"; exit 1; }

echo "Deployment completed successfully!"
