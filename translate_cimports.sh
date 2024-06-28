#!/bin/bash

set -e

zig translate-c \
    -isystem /usr/local/include \
    $(pkg-config --cflags glfw3 SDL2) \
    src/cimports.h  > src/c.zig
