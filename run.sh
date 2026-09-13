#!/bin/sh
# Start Remote Mouse. Usage: ./run.sh [--port 7070] [--token SECRET] [--no-token]
cd "$(dirname "$0")" && exec .venv/bin/python server.py "$@"
