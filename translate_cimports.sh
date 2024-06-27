#!/bin/bash

set -e

zig translate-c -isystem /usr/local/include src/cimports.h > src/c.zig
