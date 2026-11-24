#!/bin/bash
cd "$(dirname "$0")"
exec /bin/bash ./build-app.sh "$@"
