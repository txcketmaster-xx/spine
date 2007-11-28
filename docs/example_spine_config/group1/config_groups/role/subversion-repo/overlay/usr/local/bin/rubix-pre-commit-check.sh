#!/bin/bash
# vim:et:ts=4:sw=2
SVNLOOK=${SVN:-/usr/bin/svnlook}
DEBUG=${RSVN_DEBUG:-0}
VERBOSE=${RSVN_VERSOSE:-false}
RC=0
REPORTED=0

function debug()
{
    local level=$1
    shift

    [ ${DEBUG} -ge ${level} ] && echo -e "DEBUG: $*" 1>&2
}

function verbage()
{
    echo $*
}

function report()
{
    local file=$1
    shift

    if [ ${REPORTED} -eq 0 ]; then
        echo -e "\nErrors encountered!\n" 1>&2
        let REPORTED+=1
    fi

    echo "${file}: $*" 1>&2
}

function getprop()
{
    local file=$1
    shift
    local propname=$1
    shift

    ${SVNLOOK} propget ${REPOS} -t ${TXN} ${propname} ${file} 2> /dev/null
}

function is_special()
{
    local rc=0
    local foo=0
    local file=$1
    shift

    # See how many "rubix:" properties we have for this file.  More than 2
    # means it's a special file

    foo=`${SVNLOOK} pl ${REPOS} -t ${TXN} ${file} | grep -c 'rubix:'`

    let rc+=${foo}

    return ${rc}
}

function check_special()
{
    local rc=0
    local special=$1
    shift

    for property in filetype minordev majordev; do
        # Check to make sure filetype is set
        local prop=`getprop ${special} rubix:${property}`

        if [ -z "${prop}" ]; then
            report ${special} "special file is missing rubix:${property} property"
            let rc+=1
        fi
    done

    return ${rc}
}

function check_file()
{
    local rc=0
    local special=0
    local file=$1
    shift

    for property in perms ugid; do
        # Check to make sure filetype is set
        local prop=`getprop ${file} rubix:${property}`

        if [ -z "${prop}" ]; then
            report ${file} "file is missing rubix:${property} property"
            let rc+=1
        fi
    done

    is_special ${file}

    if [ $? -gt 2 ]; then
        check_special ${file}
        let rc+=1
    fi

    return ${rc}
}

function check_dir()
{
    local rc=0
    local base=''
    local perms=''
    local ugid=''
    local dir=$1
    shift

    base=`basename ${dir}`
    debug 3 "Base == \"${base}\""

    perms=`getprop ${dir} rubix:perms`
    ugid=`getprop ${dir} rubix:ugid`

    if [ ${base} = 'overlay' -o ${base} = 'class_overlay' ]; then
        if [ "${perms}" != '755' -a "${perms}" != '0755' ]; then
            report ${dir} 'is an overlay directory and MUST be mode 755!'
            let rc+=1
        fi

        if [ ${base} = 'overlay' ]; then
            if [ "${ugid}" != '0:0' ]; then
                report ${dir} 'is an overlay directory and MUST be owned by 0:0!'
                let rc+=1
            fi
        fi

    fi

    return ${rc}
}

#
# FIXME: Need to refine this to check what the flags are for the particular
#        item so that we don't check deletes.  Will likely mean re-writing
#        this script in perl.  Bleh.
#
# rtilder    Tue Mar  8 07:15:42 PST 2005
#
function check()
{
    local rc=0
    local item=$1
    shift
    local changed_dirs=$1
    shift

    # Is it in an overlay directory?
    echo "${item}" | grep -q '/\(overlay\|class_overlay\)/'
    if [ $? -ne 0 ]; then
        return ${rc}
    fi

    # We do a smidge different handling for dirs, to make sure the target /
    # dir doesn't get it's perms changed to anything other than 0755
    echo "${changed_dirs}" | grep -q ${item}
    if [ $? -eq 0 ]; then
        check_dir ${item}
        let rc+=$?
    else
        check_file ${item}
        let rc+=$?
    fi

    return ${rc}
}

script=`basename $0`
REPOS=$1
shift
TXN=$1
shift

changed_dirs=`${SVNLOOK} dirs-changed ${REPOS} -t ${TXN}`
debug 4 "Changed dirs are: ${changed_dirs}"

changed=`${SVNLOOK} changed ${REPOS} -t ${TXN} | grep -v ^D | sed -e 's/.* \(.*\)/\1/'`
debug 4 "Changed are: ${changed}"

for item in ${changed}; do
    debug 2 "Examining: ${item}"

    check ${item} "${changed_dirs}"
    let RC+=$?
done

if [ ${RC} -ne 0 ]; then
    exit 1
fi

exit 0
