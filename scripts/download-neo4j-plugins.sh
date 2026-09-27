#!/bin/sh
set -e

echo "📦 Downloading plugins..."

mkdir -p /plugins

# APOC must match the Neo4j CalVer release exactly (neo4j:2026.09 -> apoc 2026.09.0).
curl -Lf -o /plugins/apoc-2026.09.0-core.jar \
  https://github.com/neo4j/apoc/releases/download/2026.09.0/apoc-2026.09.0-core.jar

# apoc.import.graphml / apoc.import.xml use Woodstox as their StAX implementation
# (it's what the secure, non-XXE-vulnerable XML reader is built on since the
# GHSA-6wxg-wh7f-rqpr fix in APOC 5.5.0) but the apoc-core jar does not shade or
# bundle it, and the base neo4j image doesn't ship it either. Without these two
# jars, apoc.import.graphml fails at runtime with
# `ClassNotFoundException: com.ctc.wstx.io.InputBootstrapper`.
# Versions matched to what APOC 5.26.x/2026.x itself declares in NOTICE.txt/LICENSES.txt
# (the Woodstox/Stax2 versions APOC bundles against haven't moved across this bump).
curl -Lf -o /plugins/woodstox-core-5.4.0.jar \
  https://repo1.maven.org/maven2/com/fasterxml/woodstox/woodstox-core/5.4.0/woodstox-core-5.4.0.jar
curl -Lf -o /plugins/stax2-api-4.2.1.jar \
  https://repo1.maven.org/maven2/org/codehaus/woodstox/stax2-api/4.2.1/stax2-api-4.2.1.jar

# GDS is CalVer from 2026.03.0 on and requires a matching CalVer (2026.x) Neo4j
# (see https://neo4j.com/docs/graph-data-science/current/installation/supported-neo4j-versions/).
# Now that neo4j is on the 2026.09 CalVer line, GDS can be re-enabled at the
# matching 2026.09.0 release.
curl -Lf -o /plugins/neo4j-graph-data-science-2026.09.0.jar \
  https://github.com/neo4j/graph-data-science/releases/download/2026.09.0/neo4j-graph-data-science-2026.09.0.jar

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
