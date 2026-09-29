# verify-counts-compare.jq — sourced by `scripts/deploy/verify.sh --mode
# counts --baseline FILE` (never run standalone). Given $current and
# $baseline (two counts JSON objects with the postgres/keycloak/neo4j shape
# audit/m7/baseline-counts.json uses), $sections (array of section names to
# check), $userDelta/$credDelta (the allowed Keycloak demo-user/-credential
# count increase, 0 unless --verify-overlay-seeded/--allow-realm-*-delta was
# passed) and $allowConstraints (array of constraint names allowed to be
# newly added), prints one line per mismatch found (raw strings, via -r) and
# nothing at all when everything matches at tolerance 0 modulo the
# documented, named exceptions below. verify.sh fails the check iff this
# prints at least one line — every mismatch line already says exactly what
# differed, so verify.sh doesn't need to re-derive that.
#
# Documented exceptions (see scripts/deploy/verify.sh's own --mode counts
# header comment for the "why" of each):
#   - keycloak sockbowlRealmUserCount / sockbowlRealmCredentialCount may
#     each be exactly $userDelta / $credDelta higher than baseline (the
#     verify-overlay's demo users), never any other amount.
#   - keycloak sslRequired: baseline "NONE" -> current "EXTERNAL" only (Keycloak's SslRequired enum stores uppercase; compared case-insensitively).
#   - neo4j constraints: a name may be present in current but absent from
#     baseline only if it's in $allowConstraints; nothing may be present in
#     baseline but absent from current (that's data/schema loss).
#   - neo4j indexCount may only be higher than baseline by exactly the
#     number of such newly-added, allow-listed constraints.
# Every other field — every Neo4j label and relationship-type count in
# particular — must match baseline exactly, in both directions (a count
# present in one side and not the other is reported too, via the `// 0`
# defaults below), with no exception.

def leafdiff($path; $b; $c):
  if ($b == $c) then empty
  else "\($path): baseline=\($b) current=\($c)"
  end;

($sections[]) as $sec |
if $sec == "postgres" then
  ( $baseline.postgres // {} ) as $bp |
  ( $current.postgres // {} ) as $cp |
  (leafdiff("postgres.keycloak_db_size"; $bp.keycloak_db_size; $cp.keycloak_db_size)),
  ( ["bans","user_game_history","user_stats","users","user_used_question"][] as $f |
    leafdiff("postgres.sockbowl.\($f)"; ($bp.sockbowl[$f]); ($cp.sockbowl[$f])) )
elif $sec == "keycloak" then
  ( $baseline.keycloak // {} ) as $bk |
  ( $current.keycloak // {} ) as $ck |
  (leafdiff("keycloak.realmCount"; $bk.realmCount; $ck.realmCount)),
  (leafdiff("keycloak.sockbowlRealmServiceAccountUserCount"; $bk.sockbowlRealmServiceAccountUserCount; $ck.sockbowlRealmServiceAccountUserCount)),
  (leafdiff("keycloak.sockbowlRealmEnabledIdentityProviderCount"; $bk.sockbowlRealmEnabledIdentityProviderCount; $ck.sockbowlRealmEnabledIdentityProviderCount)),
  (leafdiff("keycloak.sockbowlRealmFederatedIdentityCount"; $bk.sockbowlRealmFederatedIdentityCount; $ck.sockbowlRealmFederatedIdentityCount)),
  (leafdiff("keycloak.loginTheme"; $bk.loginTheme; $ck.loginTheme)),
  ( ($ck.sslRequired) as $cs | ($bk.sslRequired) as $bs |
     if $bs == $cs then empty
     elif (($bs|ascii_upcase) == "NONE" and ($cs|ascii_upcase) == "EXTERNAL") then empty
     else "keycloak.sslRequired: baseline=\($bs) current=\($cs) (only NONE->EXTERNAL (case-insensitive) is an allowed delta)" end ),
  ( (($bk.sockbowlRealmUserCount|tonumber)) as $bu | (($ck.sockbowlRealmUserCount|tonumber)) as $cu | ($cu-$bu) as $d |
     if $d==0 or $d==$userDelta then empty
     else "keycloak.sockbowlRealmUserCount: baseline=\($bu) current=\($cu) delta=\($d) (allowed: 0 or \($userDelta))" end ),
  ( (($bk.sockbowlRealmCredentialCount|tonumber)) as $bc | (($ck.sockbowlRealmCredentialCount|tonumber)) as $cc | ($cc-$bc) as $d |
     if $d==0 or $d==$credDelta then empty
     else "keycloak.sockbowlRealmCredentialCount: baseline=\($bc) current=\($cc) delta=\($d) (allowed: 0 or \($credDelta))" end )
elif $sec == "neo4j" then
  ( $baseline.neo4j // {} ) as $bn |
  ( $current.neo4j // {} ) as $cn |
  ( (($bn.labels // {}) ) as $bl | (($cn.labels // {})) as $cl |
    ( (($bl | keys) + ($cl | keys) | unique)[] as $k |
      leafdiff("neo4j.labels.\($k)"; ($bl[$k] // 0); ($cl[$k] // 0)) ) ),
  ( (($bn.relationships // {})) as $br | (($cn.relationships // {})) as $cr |
    ( (($br | keys) + ($cr | keys) | unique)[] as $k |
      leafdiff("neo4j.relationships.\($k)"; ($br[$k] // 0); ($cr[$k] // 0)) ) ),
  ( (($bn.constraints // []) ) as $bcns | (($cn.constraints // [])) as $ccns |
    ( ($bcns - $ccns)[] | "neo4j.constraints: \(.) present in baseline but MISSING from current" ),
    ( ($ccns - $bcns)[] as $extra |
      if ($allowConstraints | index($extra)) then empty
      else "neo4j.constraints: \($extra) present in current but not in baseline and not in --allow-added-constraint" end )
  ),
  ( (($bn.indexCount|tonumber)) as $bi | (($cn.indexCount|tonumber)) as $ci |
     ((($cn.constraints // []) - ($bn.constraints // [])) | length) as $addedCount |
     if ($ci - $bi) == $addedCount then empty
     else "neo4j.indexCount: baseline=\($bi) current=\($ci) delta=\($ci-$bi) expected_delta=\($addedCount) (one index per newly-added, allow-listed constraint)" end
  )
else
  "unknown section: \($sec)"
end
