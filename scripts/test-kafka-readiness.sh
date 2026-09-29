#!/usr/bin/env bash
#
# test-kafka-readiness.sh — unit test for scripts/lib/kafka-consumer-stability.sh.
#
# Feeds canned `kafka-consumer-groups.sh --describe` output into
# kafka_consumer_group_members / kafka_consumer_group_member_count and checks
# the parsing decisions scripts/smoke-auth.sh's wait_for_game_kafka_ready
# fallback relies on. No Docker, no Kafka broker, no running stack — this
# only exercises the pure string parsing, in well under a second.
#
# Usage: scripts/test-kafka-readiness.sh
set -euo pipefail
shopt -s inherit_errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/kafka-consumer-stability.sh
source "$ROOT/scripts/lib/kafka-consumer-stability.sh"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "PASS: $*"; }
failc() { FAILED=$((FAILED + 1)); echo "FAIL: $*"; }
expect_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$desc"; else failc "$desc: expected '$expected', got '$actual'"; fi
}

# (1) A brand-new group: no rows at all (kafka-consumer-groups.sh prints a
# "Consumer group '...' has no active members." line instead of a table).
NO_MEMBERS='Consumer group '"'"'game-consumers'"'"' has no active members.'
expect_eq "no active members: 0 members" "0" "$(kafka_consumer_group_member_count "$NO_MEMBERS")"
expect_eq "no active members: member list is empty" "" "$(kafka_consumer_group_members "$NO_MEMBERS")"

# (2) A stable single member, spread across several partitions (one row per
# partition, same CONSUMER-ID in column 7).
STABLE_SINGLE='GROUP           TOPIC        PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID                                     HOST            CLIENT-ID
game-consumers  game-topic   0          15              15              0    consumer-1-6f2b3e4a-abcd-4c56-8901-abcdef123456 /172.18.0.5     consumer-1
game-consumers  game-topic   1          9               9               0    consumer-1-6f2b3e4a-abcd-4c56-8901-abcdef123456 /172.18.0.5     consumer-1
game-consumers  game-topic   2          3               3               0    consumer-1-6f2b3e4a-abcd-4c56-8901-abcdef123456 /172.18.0.5     consumer-1'
expect_eq "stable single member: count is 1" "1" "$(kafka_consumer_group_member_count "$STABLE_SINGLE")"
expect_eq "stable single member: the member id is exactly the one CONSUMER-ID" \
  "consumer-1-6f2b3e4a-abcd-4c56-8901-abcdef123456" "$(kafka_consumer_group_members "$STABLE_SINGLE")"

# (3) Mid-rebalance / two live members: two distinct CONSUMER-IDs across
# partitions. Must NOT be reported as a stable single member.
REBALANCING='GROUP           TOPIC        PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID                                     HOST            CLIENT-ID
game-consumers  game-topic   0          15              15              0    consumer-1-aaaaaaaa-abcd-4c56-8901-abcdef123456 /172.18.0.5     consumer-1
game-consumers  game-topic   1          9               9               0    consumer-2-bbbbbbbb-abcd-4c56-8901-abcdef123456 /172.18.0.6     consumer-2'
expect_eq "two live members: count is 2, not stable" "2" "$(kafka_consumer_group_member_count "$REBALANCING")"

# (4) Assigned partitions but no live consumer yet (columns show "-": offsets
# committed, nobody currently holds the assignment). Must count as 0 members,
# same as a totally fresh group, not as "one member named -".
UNASSIGNED='GROUP           TOPIC        PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID  HOST  CLIENT-ID
game-consumers  game-topic   0          0               0               0    -            -     -'
expect_eq "unassigned partitions ('-' columns): 0 members" "0" "$(kafka_consumer_group_member_count "$UNASSIGNED")"

# (5) Two samples with the SAME single member: this is exactly the "stable
# across polls" comparison wait_for_game_kafka_ready does (string equality of
# kafka_consumer_group_members's output between two calls).
SAMPLE_A="$STABLE_SINGLE"
SAMPLE_B='GROUP           TOPIC        PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID                                     HOST            CLIENT-ID
game-consumers  game-topic   0          20              20              0    consumer-1-6f2b3e4a-abcd-4c56-8901-abcdef123456 /172.18.0.5     consumer-1
game-consumers  game-topic   1          14              14              0    consumer-1-6f2b3e4a-abcd-4c56-8901-abcdef123456 /172.18.0.5     consumer-1
game-consumers  game-topic   2          8               8               0    consumer-1-6f2b3e4a-abcd-4c56-8901-abcdef123456 /172.18.0.5     consumer-1'
expect_eq "two polls of the same stable member compare equal (offsets advancing doesn't matter)" \
  "$(kafka_consumer_group_members "$SAMPLE_A")" "$(kafka_consumer_group_members "$SAMPLE_B")"

echo
echo "test-kafka-readiness: ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
