#!/bin/bash

SLEEP_TIME=80
CHROME_BIN_PATH="/home/panjie/web/src/chromium/src/out/symbol/chrome"

if [ $# -lt 1 ]; then
	echo -e $0 "<pid>"
  exit 1
else
  CHROME_PID=$1
fi

type -p "pigz" && GZIP=pigz || GZIP=gzip
TMPDIR=/tmp/hf-prof

set -x
rm -rf $TMPDIR
mkdir $TMPDIR

CHROME_PID=${CHROME_PID:-$(pgrep -o '^hhvm$')}

if [[ -z $CHROME_PID ]] ; then
    echo "Error getting hhvm PID"
    exit 1
fi

perf record -BN --no-buffering -ag -e instructions:u -o /tmp/perf.data -- sleep ${SLEEP_TIME:-200}
#perf record -BN --no-buffering -g -p $CHROME_PID  -e instructions:u -o /tmp/perf.data -- sleep ${SLEEP_TIME:-200}

perf script -i /tmp/perf.data --fields comm,pid,ip | sed -ne "/^[^   ]\+[   ]*$CHROME_PID[   ]*\$/,+2p" | $GZIP -c > $TMPDIR/perf.pds.gz

nm -S ${CHROME_BIN_PATH:-/proc/$CHROME_PID/exe} > $TMPDIR/chrome.nm

pushd $TMPDIR/..

TARFILE=${TMPDIR}.tgz

tar cvzf $TARFILE `basename $TMPDIR`

popd

echo "Generated file $TARFILE"
