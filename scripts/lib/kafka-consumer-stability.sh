#!/usr/bin/env bash
#
# kafka-consumer-stability.sh — FIX-D1 (plans/m2-auth.md fixWps, M2-LIVE-01).
#
# A pure parsing helper, split out of scripts/smoke-auth.sh so it can be unit
# tested (scripts/test-kafka-readiness.sh) against canned
# `kafka-consumer-groups.sh --describe` output, without Docker or a running
# Kafka broker.
#
# scripts/smoke-auth.sh polls a Kafka consumer group's --describe output
# across a couple of samples to decide "has this group settled on a stable
# single member yet" — the fallback readiness check for M2-LIVE-01 (game
# reports healthy before its Kafka consumer group has a stable partition
# assignment, so an early STOMP SEND is silently dropped with no error
# frame), used when the game build under test has no
# /actuator/health/readiness group (i.e. FIX-G2's Kafka-listener readiness
# HealthIndicator hasn't landed, or isn't in this image).
#
# kafka-consumer-groups.sh --describe prints one row per assigned partition:
#   GROUP  TOPIC  PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID  HOST  CLIENT-ID
# (column 7 is CONSUMER-ID). A group with no active members yet — freshly
# created, or mid-rebalance — either prints no rows at all, or prints "-" in
# the CONSUMER-ID/HOST/CLIENT-ID columns; both are treated as "no member"
# here, not as a (missing) stable member.

# kafka_consumer_group_members <describe-output>
#   Prints the sorted, de-duplicated list of non-placeholder CONSUMER-ID
#   values found in a `kafka-consumer-groups.sh --describe` table (one per
#   line; empty output if there are no active members). The caller compares
#   this across two polls a few seconds apart: unchanged and exactly one line
#   means the group has a stable single member.
kafka_consumer_group_members() {
  local describe_output="$1"
  awk 'NR>1 && NF>=7 && $7 != "" && $7 != "-" {print $7}' <<<"$describe_output" | sort -u
}

# kafka_consumer_group_member_count <describe-output>
#   Convenience wrapper: prints how many distinct CONSUMER-IDs
#   kafka_consumer_group_members found (0 if none).
kafka_consumer_group_member_count() {
  local members
  members="$(kafka_consumer_group_members "$1")"
  if [ -z "$members" ]; then
    echo 0
  else
    wc -l <<<"$members"
  fi
}
