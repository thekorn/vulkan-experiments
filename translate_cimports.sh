#!/bin/bash

set -e

zig translate-c -isystem /usr/local/include $(sdl2-config --cflags) src/cimports.h  > src/c.zig
