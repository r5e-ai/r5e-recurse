#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Both child and grandchild retain the cooperative group.
/bin/sh -c 'while :; do echo beat; sleep .02; done' &
wait
