#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
while :; do
  printf 'beat\n' >> "$1"
  sleep .02
done
