#!/bin/bash
shopt -s nullglob

ENVIRONMENTS=( hosts/* )
ENVIRONMENTS=( "${ENVIRONMENTS[@]##*/}" )
NUM_ARGS=4

show_usage() {
  echo "Usage: sync <environment> <site name> <type> <mode> [options]

<environment> is the environment to deploy to (\"staging\", \"production\", etc)
<site name> is the WordPress site to deploy (name defined in \"wordpress_sites\")
<type> is what we go to sync (\"uploads\", \"database\" or \"all\")
<mode> is the sync mode (\"pull\" or \"push\")

Available environments:
$( IFS=$'\n'; echo "${ENVIRONMENTS[*]}" )

Aliases:
  staging - stag - s
  production - prod - p
  uploads - media
  database - db
  pull - down
  push - up

Options:
  --skip=<extensions>  Exclude file types from uploads sync (comma-separated)
                       Example: --skip=mp3,m4a,wav
  --no-skip            Ignore the sync-skip file if it exists

Default Skip File:
  If a 'sync-skip' file exists in the trellis directory, its contents will be
  used as the default --skip value. The file should contain comma-separated
  extensions with no spaces (e.g., mp3,m4a,wav). Use --skip= to override or
  --no-skip to ignore the file.

Examples:
  sync staging example.com database push
  sync production example.com db pull
  sync staging example.com uploads pull
  sync prod example.com all up
  sync staging example.com uploads pull --skip=mp3
  sync staging example.com uploads push --skip=mp3,m4a,wav
"
}

DEBUG=0

[[ $# -lt NUM_ARGS ]] && { show_usage; exit 127; }

for arg
do
  [[ $arg = -h ]] && { show_usage; exit 0; }
  [[ $arg = -v ]] && { DEBUG=1; }
done

ENV="$1";
SITE="$2";
TYPE="$3";
MODE="$4";

# allow use of abbreviations of environments
if [[ $ENV = p || $ENV = prod ]]; then
  ENV="production"
elif [[ $ENV = s || $ENV = stag ]]; then
  ENV="staging"
fi

# allow use of alias of types
if [[ $TYPE = db ]]; then
  TYPE="database"
elif [[ $TYPE = media ]]; then
  TYPE="uploads"
fi

# allow use of alias of modes
if [[ $MODE = down ]]; then
  MODE="pull"
elif [[ $MODE = up ]]; then
  MODE="push"
fi

# Check for --skip and --no-skip flags
UPLOAD_SKIP_EXT=""
NO_SKIP=0
for arg in "$@"; do
  if [[ $arg == --skip=* ]]; then
    UPLOAD_SKIP_EXT="${arg#--skip=}"
  elif [[ $arg == --no-skip ]]; then
    NO_SKIP=1
  fi
done

# If --skip not provided and --no-skip not set, check for sync-skip file
if [[ -z $UPLOAD_SKIP_EXT && $NO_SKIP == 0 && -f sync-skip ]]; then
    SKIP_FILE_CONTENT=$(tr -d '[:space:]' < sync-skip)
  if [[ -n $SKIP_FILE_CONTENT ]]; then
    UPLOAD_SKIP_EXT="$SKIP_FILE_CONTENT"
  fi
fi

HOSTS_FILE="hosts/$ENV"

if [[ ! -e $HOSTS_FILE ]]; then
  echo "Error: '$ENV' is not a valid environment ($HOSTS_FILE does not exist)."
  echo
  echo "Available environments:"
  ( IFS=$'\n'; echo "${ENVIRONMENTS[*]}" )
  exit 1
fi

if [[ $TYPE != "database" && $TYPE != "uploads" && $TYPE != "all" ]]; then
  echo "Error: '$TYPE' is not a valid type (uploads or media, database or db, all)."
  exit 1
fi

if [[ $MODE != "pull" && $MODE != "push" ]]; then
  echo "Error: '$MODE' is not a valid sync mode (pull or down, push or up)."
  exit 1
fi

# Production push warning
if [[ $ENV = "production" && $MODE = "push" ]]; then
  echo "⚠️  WARNING: You are about to PUSH data to the PRODUCTION environment!"
  echo "   Environment: $ENV"
  echo "   Site: $SITE"
  echo "   Type: $TYPE"
  echo "   Mode: $MODE"
  if [[ -n $UPLOAD_SKIP_EXT ]]; then
    echo "   Extensions skipped: $UPLOAD_SKIP_EXT"
  fi
  echo
  echo "   This will OVERWRITE data on the production server."
  echo "   This action cannot be undone!"
  echo
  echo -n "Type 'yes' if you wish to continue, or anything else to cancel: "
  read -r confirmation

  if [[ $confirmation != "yes" ]]; then
    echo "Operation cancelled."
    exit 1
  fi
  echo
fi

INVENTORY_PARAMS="-i $HOSTS_FILE"

VAGRANT_ACTIVE=0
LIMA_ACTIVE=0

if which vagrant >/dev/null; then
  if test -e .vagrant/hostmanager/id; then
    VAGRANT_ID="$(cat .vagrant/hostmanager/id)"

    if test ${#VAGRANT_ID} -eq 36; then
      if vagrant status "$VAGRANT_ID" --no-tty 2>/dev/null | grep -q "is running"; then
        VAGRANT_ACTIVE=1
      fi
    fi
  fi
fi

if which trellis >/dev/null && which limactl >/dev/null; then
  if test -e .trellis/lima/inventory; then
    if limactl list "$SITE" 2>/dev/null | grep -q "Running"; then
      LIMA_ACTIVE=1
    fi
  fi
fi

if [[ $LIMA_ACTIVE == 0 ]] && [[ $VAGRANT_ACTIVE == 0 ]]; then
  echo "Could not find any local development VMs running."
  exit 1
fi

if [[ $LIMA_ACTIVE == 1 ]]; then
    INVENTORY_PARAMS="${INVENTORY_PARAMS} -i .trellis/lima/inventory"
elif [[ $VAGRANT_ACTIVE == 1 ]]; then
    INVENTORY_PARAMS="${INVENTORY_PARAMS} -i .vagrant/provisioners/ansible/inventory"
fi

if [[ $DEBUG == 1 ]]; then
  DEBUG_PARAMS="-vvv"
fi

ANSIBLE_PARAMS="$DEBUG_PARAMS -e env=$ENV -e site=$SITE -e mode=$MODE -e upload_skip_ext=$UPLOAD_SKIP_EXT $INVENTORY_PARAMS"

DATABASE_CMD="ansible-playbook database.yml $ANSIBLE_PARAMS"
UPLOADS_CMD="ansible-playbook uploads.yml $ANSIBLE_PARAMS"

if [[ $TYPE = database ]]; then
  $DATABASE_CMD
elif [[ $TYPE = uploads ]]; then
  $UPLOADS_CMD
else
  $UPLOADS_CMD
  $DATABASE_CMD
fi
