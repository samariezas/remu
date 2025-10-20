#!/usr/bin/env bash
set -xe
gdb ./trap --eval-command="target extended-remote localhost:1234" --eval-command="layout src" --eval-command="b _start" --eval-command="c"
