#!/bin/sh
set -e

echo "⏳ Waiting for Neo4j to be ready..."
until cypher-shell -a bolt://localhost:7687 -u neo4j -p 123456789 "RETURN 1" >/dev/null 2>&1; do
  sleep 5
done

echo "✅ Neo4j is up. Checking for existing Packet nodes..."
PACKET_COUNT=$(cypher-shell -a bolt://localhost:7687 -u neo4j -p 123456789 --format plain \
  "MATCH (n:Packet) RETURN count(n)" | tail -1)

if [ "$PACKET_COUNT" -gt 0 ]; then
  echo "🟡 Packet nodes already exist. Skipping import."
else
  echo "🟢 Importing GraphML..."
  cypher-shell -a bolt://localhost:7687 -u neo4j -p 123456789 --format plain \
    "CALL apoc.import.graphml('https://sockbowl-data.s3.us-east-2.amazonaws.com/base.graphml', {batchSize: 10000, useTypes: true, storeNodeIds: true, readLabels: true})"
fi
