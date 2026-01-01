#!/bin/bash

services=("../analyze-service" \
	  "../data-service" \
	  "../forecast-service" \
	  "../grype-service" \
	  "../input-service" \
	  "../nvd-service" \
	  "../orchestrate-service" \
	  "../package-index-service" \
	  "../recommend-service" \
	  "../databricks-dummy-service" \
          "../turbo" \
          "../turbo-auth-service"
)

for service in ${services[*]}; do
  echo "pulling: $service"
  cd $service
  GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519" git checkout main
  GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519" git pull
  GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519" git checkout develop
  GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519" git pull
  cd ../docker-compose
done 
