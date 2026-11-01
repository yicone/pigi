#!/bin/bash
# Shared locked dependency preparation for spike tests and the shipping helper.
set -euo pipefail
cd "$(dirname "$0")"
api_sha=3f8fbebac58d144861efb8c41a04562389498125
mkdir -p .cache
if [ ! -d .cache/api ]; then
    git init -q .cache/api
    git -C .cache/api fetch --depth 1 https://github.com/ProtonMail/go-proton-api.git "$api_sha"
    git -C .cache/api checkout -q --detach FETCH_HEAD
fi
if [ "$(git -C .cache/api rev-parse HEAD)" != "$api_sha" ] ||
   [ -n "$(git -C .cache/api status --porcelain)" ]; then
    echo 'API cache revision/content mismatch; refusing to build.' >&2
    exit 1
fi
