#!/bin/sh
set -xe
tcc hello.c -o hello
tcc qpu-basic.c -lqpu -o qpu-basic
