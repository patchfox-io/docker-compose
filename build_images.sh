#!/bin/bash

poms=("../analyze-service/pom.xml" \
	"../data-service/pom.xml" \
	"../forecast-service/pom.xml" \
	"../grype-service/pom.xml" \
	"../input-service/pom.xml" \
	"../nvd-service/pom.xml" \
	"../orchestrate-service/pom.xml" \
	"../package-index-service/pom.xml" \
	"../recommend-service/pom.xml"\
	"../databricks-dummy-service/pom.xml"
)

for pom in ${poms[*]}; do
  echo "building image for: $pom"
  mvn -f $pom clean install
  mvn -f $pom compile jib:dockerBuild
done

# docker build -t python-databricks-service ../python-databricks-service
