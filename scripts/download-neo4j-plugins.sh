#!/bin/sh
set -e

echo "📦 Downloading plugins..."

mkdir -p /plugins

# APOC must match the Neo4j MAJOR.MINOR line (neo4j:5.26 -> apoc 5.26.x).
# The 2025.x APOC CalVer stream is for Neo4j 2025.x and fails 5.26's version check.
curl -Lf -o /plugins/apoc-5.26.31-core.jar \
  https://github.com/neo4j/apoc/releases/download/5.26.31/apoc-5.26.31-core.jar

# apoc.import.graphml / apoc.import.xml use Woodstox as their StAX implementation
# (it's what the secure, non-XXE-vulnerable XML reader is built on since the
# GHSA-6wxg-wh7f-rqpr fix in APOC 5.5.0) but the apoc-core jar does not shade or
# bundle it, and the base neo4j image doesn't ship it either. Without these two
# jars, apoc.import.graphml fails at runtime with
# `ClassNotFoundException: com.ctc.wstx.io.InputBootstrapper`.
# Versions matched to what APOC 5.26.x itself declares in NOTICE.txt/LICENSES.txt.
curl -Lf -o /plugins/woodstox-core-5.4.0.jar \
  https://repo1.maven.org/maven2/com/fasterxml/woodstox/woodstox-core/5.4.0/woodstox-core-5.4.0.jar
curl -Lf -o /plugins/stax2-api-4.2.1.jar \
  https://repo1.maven.org/maven2/org/codehaus/woodstox/stax2-api/4.2.1/stax2-api-4.2.1.jar

# GDS: the last pre-CalVer line (up to 2.27.0) only supports Neo4j 5.26 at GDS
# 2.13 (see https://neo4j.com/docs/graph-data-science/current/installation/supported-neo4j-versions/),
# and every GDS release since 2026.03.0 is CalVer and requires a matching
# CalVer (2026.x) Neo4j. There is no currently-maintained GDS release that both
# supports Neo4j 5.26 and isn't several years stale, so this stays disabled
# rather than pinning either an ancient GDS or an incompatible Neo4j jump.
# Revisit together with the next Neo4j major/CalVer upgrade.
# curl -Lf -o /plugins/neo4j-graph-data-science-2.13.2.jar \
#   https://github.com/neo4j/graph-data-science/releases/download/2.13.2/neo4j-graph-data-science-2.13.2.jar

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
