#!/usr/bin/env bash
# Requires workflow_dispatch
TOKEN=XXX
BRANCH=XXX
ORG_OR_USERNAME=XXX
REPO=XXX
FILENAME_OR_WORKFLOW_ID=XXX

curl \
  -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: token $TOKEN" \
  https://api.github.com/repos/$ORG_OR_USERNAME/$REPO/actions/workflows/$FILENAME_OR_WORKFLOW_ID/dispatches \
  -d '{"ref":"refs/heads/'$BRANCH'"}'
