#!/bin/sh
set -e

# Use environment variables with defaults
NEO4J_USER=${NEO4J_USER:-neo4j}
NEO4J_PASSWORD=${NEO4J_PASSWORD:-123456789}
NEO4J_HOST=${NEO4J_HOST:-localhost}
NEO4J_PORT=${NEO4J_PORT:-7687}

NEO4J_URL="bolt://${NEO4J_HOST}:${NEO4J_PORT}"

echo "⏳ Waiting for Neo4j to be ready at ${NEO4J_URL}..."
until cypher-shell -a "${NEO4J_URL}" -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" "RETURN 1" >/dev/null 2>&1; do
  echo "   Still waiting for Neo4j..."
  sleep 5
done

echo "✅ Neo4j is up. Creating vector indexes if they don't exist..."

# Create Spring AI default vector index (spring-ai-document-index)
echo "Creating spring-ai-document-index..."
cypher-shell -a "${NEO4J_URL}" -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" --format plain << 'CYPHER' || echo "Index may already exist"
CREATE VECTOR INDEX `spring-ai-document-index` IF NOT EXISTS
FOR (n:Document) ON (n.embedding)
OPTIONS {indexConfig: {
  `vector.dimensions`: 1024,
  `vector.similarity_function`: 'cosine'
}};
CYPHER

# Create custom vector index (as configured in application.yml)
echo "Creating custom-index..."
cypher-shell -a "${NEO4J_URL}" -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" --format plain << 'CYPHER' || echo "Index may already exist"
CREATE VECTOR INDEX `custom-index` IF NOT EXISTS
FOR (n:Document) ON (n.embedding)
OPTIONS {indexConfig: {
  `vector.dimensions`: 1024,
  `vector.similarity_function`: 'cosine'
}};
CYPHER

# Verify indexes were created
echo "Verifying vector indexes..."
cypher-shell -a "${NEO4J_URL}" -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" --format plain "SHOW INDEXES YIELD name, type WHERE type = 'VECTOR' RETURN name, type" || echo "Could not verify indexes"

echo "✅ Vector indexes created. Checking for existing Packet nodes..."
PACKET_COUNT=$(cypher-shell -a "${NEO4J_URL}" -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" --format plain \
  "MATCH (n:Packet) RETURN count(n)" | tail -1)

if [ "$PACKET_COUNT" -gt 0 ]; then
  echo "🟡 Packet nodes already exist ($PACKET_COUNT found). Skipping import."
else
  echo "🟢 Importing GraphML from S3..."
  cypher-shell -a "${NEO4J_URL}" -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" --format plain \
    "CALL apoc.import.graphml('https://sockbowl-data.s3.us-east-2.amazonaws.com/base.graphml', {batchSize: 10000, useTypes: true, storeNodeIds: true, readLabels: true})"
  echo "✅ GraphML import completed!"
fi

# Seed the local question bank (:BankTossup / :BankBonus) so questions'
# import-random/generate endpoints and ng's Generate-tab e2e specs have
# something to sample on a fresh stack. base.graphml above only ships
# :Packet/:Tossup/:Bonus nodes (already-built packets), not the separate
# qbreader-dump bank the Generate tab samples from, so a stack that only
# imports the GraphML still has an empty bank. Idempotent: skipped if any
# :BankTossup already exists.
echo "✅ Checking for existing BankTossup nodes..."
BANK_COUNT=$(cypher-shell -a "${NEO4J_URL}" -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" --format plain \
  "MATCH (n:BankTossup) RETURN count(n)" | tail -1)

if [ "$BANK_COUNT" -gt 0 ]; then
  echo "🟡 BankTossup nodes already exist ($BANK_COUNT found). Skipping bank seed."
else
  echo "🟢 Seeding the question bank across the standard categories..."
  cypher-shell -a "${NEO4J_URL}" -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" --format plain << 'CYPHER'
WITH ["Literature", "History", "Science", "Fine Arts", "Religion", "Mythology",
      "Philosophy", "Social Science", "Geography", "Current Events", "Other Academic", "Pop Culture"] AS categories
UNWIND categories AS category
UNWIND range(1, 8) AS i
CREATE (:BankTossup {
  remoteId: 'seed-' + category + '-t' + i,
  question: category + ' seed tossup ' + i + '?',
  answer: category + ' seed answer ' + i,
  category: category,
  subcategory: category,
  difficulty: (i % 5) + 1,
  year: 2015 + (i % 10),
  standard: true
});
CYPHER
  cypher-shell -a "${NEO4J_URL}" -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" --format plain << 'CYPHER'
WITH ["Literature", "History", "Science", "Fine Arts", "Religion", "Mythology",
      "Philosophy", "Social Science", "Geography", "Current Events", "Other Academic", "Pop Culture"] AS categories
UNWIND categories AS category
UNWIND range(1, 4) AS i
CREATE (b:BankBonus {
  remoteId: 'seed-' + category + '-b' + i,
  preamble: category + ' seed bonus preamble ' + i,
  category: category,
  subcategory: category,
  difficulty: (i % 5) + 1,
  year: 2015 + (i % 10),
  standard: true
})
CREATE (b)-[:HAS_PART {order: 0}]->(:BankBonusPart {question: category + ' seed part one ' + i + '?', answer: category + ' seed part one answer ' + i})
CREATE (b)-[:HAS_PART {order: 1}]->(:BankBonusPart {question: category + ' seed part two ' + i + '?', answer: category + ' seed part two answer ' + i})
CREATE (b)-[:HAS_PART {order: 2}]->(:BankBonusPart {question: category + ' seed part three ' + i + '?', answer: category + ' seed part three answer ' + i});
CYPHER
  echo "✅ Bank seed completed (96 tossups, 48 bonuses across 12 categories)."
fi
