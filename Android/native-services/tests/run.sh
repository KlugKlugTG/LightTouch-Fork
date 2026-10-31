#!/bin/sh
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
TASK_BUILD_DIR="$REPO_DIR/build/cydia-native-tests"
mkdir -p "$TASK_BUILD_DIR"
cc -Wall -Wextra -Wno-unused-parameter -Werror=implicit-function-declaration \
  "$TEST_DIR/deb_transfer.c" -o "$TASK_BUILD_DIR/deb-transfer" \
  $(pkg-config --cflags --libs libimobiledevice-1.0 libplist-2.0) -pthread
"$TASK_BUILD_DIR/deb-transfer" > "$TASK_BUILD_DIR/transfer-events.jsonl"
