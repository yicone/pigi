#!/bin/bash
# macOS only. Requires Go >= 1.26.1, git and Swift Command Line Tools.
# GO_BIN may point to a verified local Go binary. GOPROXY remains caller-owned.
# Usage: bash tools/proton-spike/run.sh [build|test|run]
# All credentials enter through a native secure prompt, never arguments or env.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
bash ./prepare.sh
go_bin="${GO_BIN:-go}"
case "${1:-run}" in
    test)
        "$go_bin" test -mod=readonly ./... -count=1 -v
        "$go_bin" vet -mod=readonly ./...
        swiftc prompt.swift -o .cache/proton-prompt
        .cache/proton-prompt verification-parser-selftest synthetic-parser-test
        ;;
    build|run)
        "$go_bin" build -mod=readonly -o .cache/proton-spike .
        swiftc prompt.swift -o .cache/proton-prompt
        if [ "${1:-run}" = run ]; then
            exec .cache/proton-spike
        fi
        ;;
    *) echo 'Usage: run.sh [build|test|run]' >&2; exit 2 ;;
esac
