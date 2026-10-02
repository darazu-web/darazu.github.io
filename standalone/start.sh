#!/bin/sh
# 検査情報アプリを起動する（Mac / Linux）
cd "$(dirname "$0")" && exec python3 server.py "$@"
