#!/bin/bash

CONF=/etc/rubix-config-sync.conf
REPO_DIR=
COMMITS=

REPO=$1
shift
REV=$1
shift

if [ ! -r ${CONF} ]; then
    echo "Couldn't read ${CONF}!" 1>&2
    exit 1
fi

#
# Bring in COMMITS_DIR and TEMP_DIR
#
. ${CONF}

if [ ! -d ${COMMITS_DIR} -o ! -w ${COMMITS_DIR} ]; then
    echo "${COMMITS_DIR} doesn't exist or isn't writable!" 1>&2
    exit 1
fi

#
# Is it the repo we care about?
#
if [ "${REPO}" != "${REPO_DIR}" ]; then
    exit 0
fi

echo "${REPO} ${REV}" > ${COMMITS}
