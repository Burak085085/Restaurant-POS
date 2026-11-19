#!/usr/bin/env bash
# Usage: comment.sh <job title>
# Posts the tail of each CI log as a pull request comment so results can be read
# without signing in. A log that is missing means the step that writes it never ran.
# Needs GH_TOKEN, PR_NUMBER and GITHUB_REPOSITORY. Never fails the job itself.
title="$1"
body=$(mktemp)
{
  echo "## CI report: $title"
  echo "Run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  for f in dartfix.log analyze.log test.log build.log; do
    echo
    if [ -f "$f" ]; then
      echo "### $f (last 60 lines)"
      echo '```'
      tail -n 60 "$f" | cut -c1-300
      echo '```'
    else
      echo "### $f: NOT PRODUCED (an earlier step failed or this step did not run)"
    fi
  done
} > "$body"
gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --body-file "$body" || echo "Could not post the PR comment"
exit 0
