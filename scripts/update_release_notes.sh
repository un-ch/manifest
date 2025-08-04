#!/bin/bash

#
# update_release_notes.sh
#
# description:
#
# the script automates the process of generating GitHub release notes
# within a given organization, collects all new commits since the last
# published release, upload in the manifest repository with that file
# as its content and asset.
#
# features:
#
# - validates the release tag and prevents overwriting existing releases
# - fetches all relevant repositories in the organization
# - uses only commits from the main development path with "--first-parent"
#   flag by default.
# - displays the commit summary
# - handles script termination and cleanup of temporary directory
#

ORG="un-ch"
GITHUB_SSH_HOST="git@github.com"
GITHUB_URL="https://github.com"
MANIFEST_REPO="manifest"
NOTES_FILE_NAME="release_notes.md"

GIT_LOG_ARGS=(--first-parent)

cleanup()
{
	local exit_code=$?
	local signal=$1

	rm -rf "${TEMP_DIR}"

	if [[ "${signal}" == "INT" || "${signal}" == "TERM" ]]; then
		exit 3
	else
		exit "${exit_code}"
	fi
}

required_tools_installed()
{
	local missing=0
	local tools=("git" "gh" "grep")
	local result=0

	for tool in "${tools[@]}"; do
		if ! command -v "${tool}" >/dev/null 2>&1; then
		    echo "error: required tool '${tool}' is not found" >&2
		    result=1
		fi
	done

	return "${result}"
}

is_valid_release_tag()
{
	local tag="$1"
	local unexpected_chars='[*;\$`|&<>(){}[:space:]]'
	local published_date
	local result=0

	if [[ -z "${tag}" ]] || \
	   [[ "${tag}" == *".."* ]] || \
	   [[ "${tag}" == .* ]] || \
	   [[ "${tag}" =~ ${unexpected_chars} ]]; then
		echo "error: invalid release tag format: ${tag}" >&2
		result=1
	fi
	
	# get ${tag} release date or "not-found" string:
	published_date=$(
		gh api "repos/${ORG}/${MANIFEST_REPO}/releases/tags/${tag}" --jq '.published_at' 2>/dev/null
	)

	# check for ISO 8601 UTC format:
	if [[ "${published_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
		echo "error: release ${tag} already exists" >&2
		result=1
	fi

	return "${result}"
}

generate_details_section()
{
	local title="$1"
	local summary="$2"
	local content="$3"

	if [ -n "${title}" ]; then
		echo "${title}"
	fi

	echo "<details>"
	echo "<summary>$summary</summary>"
	echo
	echo "$content"
	echo
	echo "</details>"
	echo
}

# trap to call cleanup() function to delete temp directory on exit or interruption:
for signal in INT TERM EXIT; do
	trap "cleanup ${signal}" "${signal}";
done

if ! required_tools_installed; then
	exit 1
fi

# check that one argument is provided:
if [ "$#" -ne 1 ]; then
	echo "error: expected 1 argument" >&2
	echo "usage: $0 <release-tag>" >&2
	exit 2
fi

if ! is_valid_release_tag "$1"; then
	exit 3
fi

RELEASE_TAG="$1"

# create temporary directory for .git files:
TEMP_DIR=$(mktemp -d "./tmp_git_repos_XXXXXX")

# get all repos related to ORG variable:
REPOS=$(
	gh repo list "${ORG}" --limit 500 --json name --jq '.[].name' \
	| grep -E '^(manifest|last_prj|new_project|b_prj|a_prj|c_prj|release_notes)$'
)

# ensure manifest repo name appears first, followed by other repo names sorted alphabetically:
REPOS_SORTED=$(echo "${REPOS}" | grep -v '^manifest$' | sort)
REPOS_SORTED=$(echo -e "manifest\n$REPOS_SORTED")

NOTES_FILE="${TEMP_DIR}/${NOTES_FILE_NAME}"

# check previous manifest repo release date:
LATEST_RELEASE_DATE_UTC=$(
	gh api repos/${ORG}/${MANIFEST_REPO}/releases \
	--jq '[.[] | select(.draft == false and .prerelease == false)][0].published_at'
)

# if this is the first release, include all commits;
# otherwise, include only commits since the last release date:
if [ -n "${LATEST_RELEASE_DATE_UTC}" ]; then
	GIT_LOG_ARGS+=(
		--since="${LATEST_RELEASE_DATE_UTC}"
	)
fi

# write the release info to the header:
generate_details_section "" "release info" \
	"- tag: \`${RELEASE_TAG}\`
- generated: \`$(date -u '+%Y-%m-%d %H:%M:%S UTC')\`" \
	> "${NOTES_FILE}"

for REPO in $REPOS_SORTED; do
	echo "[INFO] processing ${REPO}..."
	REPO_DIR="$TEMP_DIR/${REPO}.git"

	# clone the .git directory:
	git clone --quiet --bare "${GITHUB_SSH_HOST}:${ORG}/${REPO}.git" "${REPO_DIR}"

	# get commits since the last release:
	COMMITS=$(
		git -C "${REPO_DIR}" log "${GIT_LOG_ARGS[@]}" \
		--pretty=format:"- %s [\`%h\`](${GITHUB_URL}/${ORG}/${REPO}/commit/%H)"
	)

	# if there are new commits, add a details section:
	if [[ -z "${COMMITS}" ]]; then
		NEW_COMMIT_COUNT=0
	else
		NEW_COMMIT_COUNT=$(echo "${COMMITS}" | grep -c "^- ")

		generate_details_section \
			"### [${REPO}](${GITHUB_URL}/${ORG}/${REPO})" \
			"commits (${NEW_COMMIT_COUNT})" \
			"${COMMITS}" >> "${NOTES_FILE}"
	fi
done

# create and publish release:
gh release create "${RELEASE_TAG}" \
	--latest \
	--notes-file "${NOTES_FILE}" \
	--title "${RELEASE_TAG}" \
	--repo "${ORG}/${MANIFEST_REPO}" > /dev/null

# upload notes file as an asset:
gh release upload "${RELEASE_TAG}" "${NOTES_FILE}" \
	--repo "${ORG}/${MANIFEST_REPO}" > /dev/null 2>&1
