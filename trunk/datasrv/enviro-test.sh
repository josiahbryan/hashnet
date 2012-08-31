#!/bin/sh

if [ "${UNTAR_ONLY}" = "true" ]; then
#if [ $myname = root ]; then
        echo "Welcome to FooSoft 3.0"
else
        echo "You must be root to run this script"
        exit 1
fi
