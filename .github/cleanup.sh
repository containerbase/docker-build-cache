#!/bin/bash

# Deletes old versions of the ghcr.io/<owner>/docker-build-cache package:
# - the handoff caches the `base` jobs of containerbase/base push, tagged
#   `<uuid>-<arch>` (see `setup` in its `.github/workflows/build.yml`), after
#   MAX_AGE hours. They are only read by the `lang` jobs of the same run.
# - untagged versions, caches whose tag was overwritten by a newer push, after
#   MAX_UNTAGGED_AGE days.
# Other tagged versions are never touched.
#
# The api lists the newest versions first, so this walks the pages from the
# last one, the oldest versions, to the first one: the backlog is deleted
# first. Deleting versions on a page only moves the versions of later pages,
# which were handled already. The order isn't documented, so it reads every
# page rather than stopping at the first page without old versions. It stops
# when the request budget or the time of this run is used up; the next run
# starts at the last page again.
#
# Usage: cleanup.sh, configured by the environment variables below.

set -euo pipefail

: "${ORG:?}" "${PACKAGE:?}"
DRY_RUN="${DRY_RUN:-false}"
MAX_AGE="${MAX_AGE:-24}"
MAX_UNTAGGED_AGE="${MAX_UNTAGGED_AGE:-7}"
# requests of the hourly api limit to leave for other workflows
RESERVE="${RESERVE:-100}"
# in seconds, stop before the job timeout
MAX_DURATION="${MAX_DURATION:-2700}"
# in seconds, for a single api request
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}"

api="/orgs/${ORG}/packages/container/${PACKAGE}/versions"
cutoff="$(date -u -d "-${MAX_AGE} hours" +%Y-%m-%dT%H:%M:%SZ)"
untagged_cutoff="$(date -u -d "-${MAX_UNTAGGED_AGE} days" +%Y-%m-%dT%H:%M:%SZ)"

# runs gh with a time limit, so a hanging request can't use up the run
gh_api() {
  timeout "${REQUEST_TIMEOUT}" gh api "$@"
}

# whether this run may send another request
can_request() {
  ((budget > 0 && SECONDS < MAX_DURATION))
}

# requests left of this run, from the remaining hourly limit of the token,
# checking it doesn't count against the limit
budget="$(gh_api /rate_limit --jq '.resources.core.remaining')"
budget=$((budget - RESERVE))
echo "deleting handoff tags before ${cutoff} and untagged versions before ${untagged_cutoff}, budget ${budget} requests"

# the last page from the link header, there is none with a single page
budget=$((budget - 1))
# a failed request fails the run, only a successful one without the link
# means a single page
first="$(gh_api -i "${api}?per_page=100")"
last="$(grep -i '^link:' <<< "${first}" | grep -o '<[^>]*>; rel="last"' | grep -o '[?&]page=[0-9]*' | cut -d= -f2 || true)"
last="${last:-1}"
echo "${last} pages"

deleted=0
failed=0
stopped=false
for ((page = last; page >= 1; page--)); do
  if ! can_request; then
    stopped=true
    break
  fi
  budget=$((budget - 1))
  versions="$(gh_api "${api}?per_page=100&page=${page}")"

  # in a variable, so a jq error fails the run
  selected="$(jq -r --arg cutoff "${cutoff}" --arg untagged_cutoff "${untagged_cutoff}" '
    .[]
    | .metadata.container.tags as $tags
    | select(
        (($tags | length) > 0
          and .updated_at < $cutoff
          and all($tags[]; test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-(amd64|arm64)$")))
        or (($tags | length) == 0 and .updated_at < $untagged_cutoff)
      )
    | "\(.id) \(if ($tags | length) > 0 then ($tags | join(",")) else "<untagged>" end)"
  ' <<< "${versions}")"

  while read -r id tags; do
    [[ -n "${id}" ]] || continue
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "would delete ${id} ${tags}"
      deleted=$((deleted + 1))
      continue
    fi
    if ! can_request; then
      stopped=true
      break 2
    fi
    budget=$((budget - 1))
    if gh_api --silent -X DELETE "${api}/${id}"; then
      echo "deleted ${id} ${tags}"
      deleted=$((deleted + 1))
    else
      echo "::warning::failed to delete ${id} ${tags}"
      failed=$((failed + 1))
    fi
  done <<< "${selected}"
done

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
if [[ "${stopped}" == "true" ]]; then
  echo "::notice::stopped at page ${page} of ${last}, the next run continues (budget ${budget}, ${SECONDS}s)"
  echo "stopped at page ${page} of ${last}, the next run continues" >> "${summary}"
fi
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "${deleted} versions would be deleted" | tee -a "${summary}"
else
  echo "${deleted} versions deleted, ${failed} failed" | tee -a "${summary}"
fi
if ((failed > 0)); then
  echo "::error::${failed} versions could not be deleted"
  exit 1
fi
