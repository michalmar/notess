#!/bin/sh
exec sandbox-exec -p '(version 1)(allow default)(deny file-write* (subpath "/private/tmp/n109/sb"))' /opt/homebrew/bin/copilot "$@"
