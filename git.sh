#!/bin/bash
home=$HOME
_pwd=`pwd`
ctime=`date +"%Y-%m-%d %H:%M:%S​"`
if [ ! $1 ]; then
    commitlog=$ctime
else
    commitlog="$1: $ctime"
fi

git add .
git commit -m "$commitlog"
git push
