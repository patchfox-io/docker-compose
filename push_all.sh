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
  echo "pushing: $service"
  cd $service
  git add -A
  git commit -m "script update"
  GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519" git push

  git checkout main
  git merge develop
  GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519" git push

  git checkout develop
  cd ../docker-compose
done 
