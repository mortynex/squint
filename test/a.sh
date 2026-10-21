#!/bin/bash
set -e
for f in *.txt; do echo "$f" | grep -q x && exit 1; done
