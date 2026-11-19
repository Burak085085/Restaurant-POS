#!/usr/bin/env bash
# Usage: publish.sh <job name>
# Publishes the tail of each CI log to the ci-reports branch so results can be read
# without signing in to the Actions UI. A log marked NOT PRODUCED means the step that
# writes it never ran (an earlier step failed). Needs GH_TOKEN, JOB_STATUS and the
# standard GITHUB_* variables. Never fails the job itself.
job="$1"
name="${GITHUB_RUN_ID}-${job}"
tmp=$(mktemp -d)
mkdir -p "$tmp/$name"
{
  echo "# $job"
  echo "- run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  echo "- commit: ${GITHUB_SHA}"
  echo "- ref: ${GITHUB_REF_NAME}"
  echo "- job status when reported: ${JOB_STATUS}"
} > "$tmp/$name/README.md"
for f in dartfix.log analyze.log test.log build.log; do
  if [ -f "$f" ]; then
    tail -n 200 "$f" | cut -c1-400 > "$tmp/$name/$f"
  else
    echo "NOT PRODUCED (an earlier step failed or this step did not run)" > "$tmp/$name/$f"
  fi
done
git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
repo_url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
for i in 1 2 3 4 5; do
  rm -rf "$tmp/repo"
  git clone --quiet --depth 1 --branch ci-reports "$repo_url" "$tmp/repo" || { echo "Could not clone ci-reports"; exit 0; }
  mkdir -p "$tmp/repo/runs"
  cp -r "$tmp/$name" "$tmp/repo/runs/"
  # -f: the repository .gitignore ignores *.log files, which would silently drop the logs.
  if (cd "$tmp/repo" && git add -f runs && git commit -q -m "CI report: $job run ${GITHUB_RUN_ID}" && git push -q origin ci-reports); then
    echo "Published CI report $name"
    break
  fi
  sleep $((i * 2))
done
exit 0
