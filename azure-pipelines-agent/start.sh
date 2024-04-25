#!/bin/bash
set -e

if [ -z "$AZP_URL" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi

if [ -z "$AZP_TOKEN_FILE" ]; then
  if [ -z "$AZP_TOKEN" ] && [[ -z $AZP_SP_CLIENTID || -z $AZP_SP_SECRET || -z $AZP_SP_TENANTID ]]; then
    echo 1>&2 "error: missing AZP_TOKEN or (AZP_SP_CLIENTID+AZP_SP_SECRET+AZP_SP_TENANTID) environment variable(s)"
    exit 1
  fi

  AZP_TOKEN_FILE=/azp/.token
  AZP_SP_SECRET_FILE=/azp/.sp_secret
  if [[ -z $AZP_SP_CLIENTID || -z $AZP_SP_SECRET || -z $AZP_SP_TENANTID ]]; then
    echo -n $AZP_TOKEN > "$AZP_TOKEN_FILE"
    AZP_AUTH_TYPE="pat"
  else
    az login --service-principal -u "$AZP_SP_CLIENTID" -p "$AZP_SP_SECRET" --tenant "$AZP_SP_TENANTID" --allow-no-subscriptions
    AZP_SP_TOKEN=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query "accessToken" --output tsv)
    echo -n $AZP_SP_TOKEN > "$AZP_TOKEN_FILE"
    echo -n $AZP_SP_SECRET > "$AZP_SP_SECRET_FILE"
    AZP_AUTH_TYPE="sp"
  fi
fi

unset AZP_TOKEN
unset AZP_SP_SECRET

if [ -n "$AZP_WORK" ]; then
  mkdir -p "$AZP_WORK"
fi

export AGENT_ALLOW_RUNASROOT="1"

cleanup() {
  # If $AZP_PLACEHOLDER is set, skip cleanup
  if [ -n "$AZP_PLACEHOLDER" ]; then
    echo 'Running in placeholder mode, skipping cleanup'
    return
  fi
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    # If the agent has some running jobs, the configuration removal process will fail.
    # So, give it some time to finish the job.
    while true; do
      if [[ "$AZP_AUTH_TYPE" == "pat" ]]; then
          ./config.sh remove --unattended --auth PAT --token $(cat "$AZP_TOKEN_FILE") && break
      else
          ./config.sh remove --unattended --auth SP --clientid "$AZP_SP_CLIENTID" --clientsecret $(cat "$AZP_SP_SECRET_FILE") --tenantid "$AZP_SP_TENANTID" && break
      fi

      echo "Retrying in 30 seconds..."
      sleep 30
    done
  fi
}

print_header() {
  lightcyan='\033[1;36m'
  nocolor='\033[0m'
  echo -e "${lightcyan}$1${nocolor}"
}

# Let the agent ignore the token env variables
export VSO_AGENT_IGNORE=AZP_TOKEN,AZP_TOKEN_FILE

print_header "1. Determining matching Azure Pipelines agent..."

AZP_AGENT_PACKAGES=$(curl -LsS \
    -u user:$(cat "$AZP_TOKEN_FILE") \
    -H 'Accept:application/json;' \
    "$AZP_URL/_apis/distributedtask/packages/agent?platform=$TARGETARCH&top=1")

AZP_AGENT_PACKAGE_LATEST_URL=$(echo "$AZP_AGENT_PACKAGES" | jq -r '.value[0].downloadUrl')

if [ -z "$AZP_AGENT_PACKAGE_LATEST_URL" -o "$AZP_AGENT_PACKAGE_LATEST_URL" == "null" ]; then
  echo 1>&2 "error: could not determine a matching Azure Pipelines agent"
  echo 1>&2 "check that account '$AZP_URL' is correct and the token is valid for that account"
  exit 1
fi

print_header "2. Downloading and extracting Azure Pipelines agent..."
echo "Agent package URL: $AZP_AGENT_PACKAGE_LATEST_URL"
curl -LsS $AZP_AGENT_PACKAGE_LATEST_URL | tar -xz & wait $!

source ./env.sh

trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

print_header "3. Configuring Azure Pipelines agent..."


if [[ "$AZP_AUTH_TYPE" == "pat" ]]; then
    ./config.sh --unattended \
      --agent "${AZP_AGENT_NAME:-$(hostname)}" \
      --url "$AZP_URL" \
      --auth PAT \
      --token $(cat "$AZP_TOKEN_FILE") \
      --pool "${AZP_POOL:-Default}" \
      --work "${AZP_WORK:-_work}" \
      --replace \
      --acceptTeeEula & wait $!
else
    ./config.sh --unattended \
      --agent "${AZP_AGENT_NAME:-$(hostname)}" \
      --url "$AZP_URL" \
      --auth SP \
      --clientid "$AZP_SP_CLIENTID"
      --clientsecret $(cat "$AZP_SP_SECRET_FILE")
      --tenantid "$AZP_SP_TENANTID"
      --pool "${AZP_POOL:-Default}" \
      --work "${AZP_WORK:-_work}" \
      --replace \
      --acceptTeeEula & wait $!
fi


print_header "4. Running Azure Pipelines agent..."

trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

chmod +x ./run.sh


# If $AZP_PLACEHOLDER is set, skipping running the agent
if [ -n "$AZP_PLACEHOLDER" ]; then
  echo 'Running in placeholder mode, skipping running the agent'
else
  # To be aware of TERM and INT signals call run.sh
  # Running it with the --once flag at the end will shut down the agent after the build is executed
  ./run.sh --once & wait $!
fi
