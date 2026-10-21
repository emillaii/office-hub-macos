#!/bin/sh
exec "$(dirname "$0")/../MacOS/OfficeProxyAskpass" --askpass "$@"
