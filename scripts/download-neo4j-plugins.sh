#!/bin/sh
set -e

echo "📦 Downloading plugins..."

mkdir -p /plugins

curl -Lf -o /plugins/apoc-2025.06.2-core.jar \
  https://github.com/neo4j/apoc/releases/download/2025.06.2/apoc-2025.06.2-core.jar

curl -Lf -o /plugins/neo4j-graph-data-science-2.19.0.jar \
  https://github.com/neo4j/graph-data-science/releases/download/2.19.0/neo4j-graph-data-science-2.19.0.jar

echo "✅ Plugins downloaded to /plugins"

echo "🛠️  Updating neo4j.conf..."

CONF_PATH="/var/lib/neo4j/conf/neo4j.conf"

if [ -f "$CONF_PATH" ]; then
  sed -i 's/^#\(dbms\.security\.procedures\.unrestricted=.*\)/\1/' "$CONF_PATH"
  sed -i 's/^#\(dbms\.security\.procedures\.allowlist=.*\)/\1/' "$CONF_PATH"
  echo "✅ Config uncommented"
else
  echo "⚠️  Config not found at $CONF_PATH. Skipping update."
fi
