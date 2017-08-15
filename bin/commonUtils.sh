#!/bin/bash

function py() {
  local OP=$1 PARAMS=() CURRENT_DIR=`pwd`
  shift

  cd $SCRIPTPATH

  while (( "$#" )); do
    if [ -n "$1" ] && (echo "$1" | grep -qE "[^0-9]"); then
      PARAMS+=("\"$1\"")
    else
      PARAMS+=($1)
    fi
    shift
  done

  python3 -c "import commonUtils; commonUtils.$OP($(IFS=$','; echo "${PARAMS[*]}"))"

  cd $CURRENT_DIR
}