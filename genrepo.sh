#! /bin/bash -eu

###############################################################################
#
# set GITHUB_TOKEN to your GitHub or GHE access token
# set GITHUB_API_ENDPOINT to your GHE API endpoint (defaults to https://api.github.com)
#
###############################################################################
URL="${GITHUB_API_ENDPOINT:-https://api.github.com}"

###############################################################################
#
# REPO_USER: GitHub user name
# REPO_NAME: Name of GitHub repo to operate on
# CORE_TEAM: GitHub id for the MY/Core group
# MODE:      Script operation mode (create|labelsonly|branchesonly)
# BRANCHES:  Default branches in each repo per our lifecycle workflow
#
###############################################################################
REPO_USER="${REPO_USER:-MY}"
REPO_NAME=unset
CORE_TEAM="1623946"   # MY/core group
MODE=create
BRANCHES="dev int st prod"

###############################################################################
#
# Get the cmdline options
#
###############################################################################

optspec=":hv-:"
while getopts "$optspec" optchar; do
  case "${optchar}" in
    -)
      case "${OPTARG}" in
        labelsonly)
          MODE=labelsonly
          ;;
        branchesonly)
          MODE=branchesonly
          ;;
        loglevel)
          val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
          echo "Parsing option: '--${OPTARG}', value: '${val}'" >&2;
          ;;
        loglevel=*)
          val=${OPTARG#*=}
          opt=${OPTARG%=$val}
          echo "Parsing option: '--${opt}', value: '${val}'" >&2
          ;;
        repo=*)
          REPO_NAME=${OPTARG#*=}
          ;;
        *)
          if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then
            echo "Unknown option --${OPTARG}" >&2
          fi
          ;;
      esac
      ;;
    h)
      echo "usage: $0 --repo=<repo> [--labelsonly | --branchesonly]" >&2
      echo "OPTIND=${!OPTIND}"
      echo "OPTARG=$OPTARG"
      #echo "usage: $0 [-v] -r|--repo {repo} [-l|--labelsonly] [--loglevel[=]<value>]" >&2
      exit 2
      ;;
    v)
      echo "Parsing option: '-${optchar}'" >&2
      ;;
    *)
    if [ "$OPTERR" != 1 ] || [ "${optspec:0:1}" = ":" ]; then
      echo "Non-option argument: '-${OPTARG}'" >&2
    fi
    ;;
  esac
done
###############################################################################

###############################################################################
#
# debug
#
#  * if DEBUG_MODE set, spew out debugging info
#
###############################################################################
DEBUG_MODE=${DEBUG_MODE:-false}

function debug
{
  if [ ! "${DEBUG_MODE}" == "false" ] ; then
    echo $@ 1>&2
  fi
}


###############################################################################
#
# token_test
#
#  * Check for GITHUB_TOKEN in the environment
#
###############################################################################
token_test()
{
  if [ -z "${GITHUB_TOKEN}" ]; then
    echo "You must set a Personal Access Token to the GITHUB_TOKEN environment variable"
    exit 1
  else
    GITHUB_AUTH="Authorization: token ${GITHUB_TOKEN}"
  fi
}


###############################################################################
#
# git_curl
#
#  * Runs curl with required auth token header against the base URL for
#    the GitHub API URL
###############################################################################
function git_curl {
  #set -x
  RES_URL="$1"; shift
  curl -Ls -H "${GITHUB_AUTH}" ${URL}/${RES_URL} $@
}


###############################################################################
#
# delete_old_labels
#
#  * For a label reset, first remove all the old labels
#
###############################################################################
function delete_labels 
{
  # Delete default labels
  git_curl ${REPO_URL}/labels | jq -r '.[].name' |
  while read LABEL; do
    LABEL="$(echo ${LABEL} | sed -e 's/ /%20/g')"
    debug "Deleting ${LABEL}..."
    git_curl ${REPO_URL}/labels/${LABEL} --request DELETE
  done
}


###############################################################################
#
# create_labels
#
#  * Creates the default labels in the repo
#
###############################################################################
function create_labels 
{
  # hotish pink cc317c
  declare -a LABEL_NAME=('abandonded' 'deferred' 'help-wanted' 'ready-for-review' 'ready-to-merge' 'response-required' 'request-for-comment' 'work-in-progress' 'urgent')
  declare -a LABEL_COLOR=('905555' '888888' 'eb6420' 'bfe5bf' '009800' 'e4c5f9' '1d76db' 'fbca04' 'fc2929')

  # Create labels
  for i in $(seq ${#LABEL_NAME[@]}); do
    #debug $i
    ((i=i-1))
    debug "Creating label ${LABEL_NAME[${i}]}: ${LABEL_COLOR[${i}]}..."
    # Can't get this to work through the git_curl function -- the data packet gets all screwed up
    #set -x
    curl -Ls -H "${GITHUB_AUTH}" ${URL}/${REPO_URL}/labels --request POST --data '{ "name" : "'${LABEL_NAME[${i}]}'", "color" : "'${LABEL_COLOR[${i}]}'" }' >/dev/null
    #set +x
  done
}


###############################################################################
#
# enable_docker_autobuild
#
###############################################################################
function enable_docker_autobuild
{
  debug "Enabling Docker Hub autobuild..."
  curl -Ls -H "${GITHUB_AUTH}" ${URL}/${REPO_URL}/hooks --request POST -d '{ "name": "docker", "config" : {}, "events" : ["push"], "active": true }'
}


###############################################################################
#
# create_repo:
#
#  * Create a new repository
#  * Create a default README.md
#  * Change the default branch to "dev"
#  * Push the README.md to set up the repo on the GH server
#
###############################################################################
function create_repo
{
  debug "Creating ${REPO_USER}/${REPO_NAME}..."
  curl -Ls -H "${GITHUB_AUTH}" ${URL}/orgs/${REPO_USER}/repos -d '{ "name": "'${REPO_NAME}'", "team_id": "'${CORE_TEAM}'", "private": "true" }'

  # Init the repo, and set the default trunk to the "dev" branch
  TMPDIR="$(mktemp -d /tmp/gitXXXX)"
  (cd ${TMPDIR}
   echo "# asdf" >> README.md
   git init
   git symbolic-ref HEAD refs/heads/dev
   git add README.md
   git commit -m "first commit"
   git remote add origin git@github.com:${REPO_USER}/${REPO_NAME}.git
   git push -u origin dev)
  rm -fr ${TMPDIR}
}


###############################################################################
#
# check_or_create_branch
#
#  * If a branch doesn't exist, create it and set it's origin for git-push
#    to work as expected
#
###############################################################################
function check_or_create_branch
{
  if [ -z "$1" ] ; then
    echo "$0: set_branch_to_master: no param ... we should never see this."
    exit 1
  else
    BRANCH=$1
  fi

  debug "Checking for existing branch ${BRANCH}..."

  if [ "$(git_curl ${REPO_URL}/git/refs/heads/${BRANCH} | jq -r .ref)" == "null" ] ; then
    debug "Creating branch ${BRANCH}..."
    TMPDIR="$(mktemp -d /tmp/gitXXXXX)"
    (cd ${TMPDIR}
     git clone git@github.com:${REPO_USER}/${REPO_NAME}
     cd ${REPO_NAME}
     git branch ${BRANCH}
     git push -u origin ${BRANCH})
    rm -fr ${TMPDIR}
  else
    debug "Branch ${BRANCH} exists."
  fi
}


###############################################################################
#
# check_repo
#
#  * If repo doesn't exist then create it and its core branches
#
###############################################################################
function check_repo
{

  # check to see if repo already exists
  if [ "${REPO_NAME}" == "$(git_curl ${REPO_URL} | jq -r .name)" ] ; then
    echo "Repo ${REPO_USER}/${REPO_NAME} already exists..."
  else
    create_repo >/dev/null
    delete_labels >/dev/null
    create_labels >/dev/null
    enable_docker_autobuild >/dev/null
  fi

  for BRANCH in ${BRANCHES}
  do
    check_or_create_branch ${BRANCH}
  done
}


# git push MYREPO master:dev
# curl -L -H $TOKEN_CMD -d '{"name": "docker-baikal", "default_branch": "dev"}' https://api.github.com/repos/MY/docker-baikal


###############################################################################
#
#  Main
#
###############################################################################
#git_curl repos/${REPO_USER}/${REPO_NAME}/git/refs/heads

if [ "${REPO_NAME}" == "unset" ] ; then
  echo "$0: repo name must be provided"
  exit 1
fi

token_test

REPO_URL="repos/${REPO_USER}/${REPO_NAME}"

case $MODE in
  labelsonly)
    delete_labels
    create_labels
    ;;
  branchesonly)
    for BRANCH in ${BRANCHES}
    do
      check_or_create_branch ${BRANCH}
    done
    ;;
  create)
    echo check_repo
    ;;
esac

exit 0
