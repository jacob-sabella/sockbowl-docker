#!/bin/sh
set -e

echo "⏳ Copying Redis modules..."

mkdir -p /modules

cp /opt/redis-stack/lib/modules/redisearch.so /modules/
cp /opt/redis-stack/lib/modules/rejson.so /modules/

echo "✅ Redis modules copied."
