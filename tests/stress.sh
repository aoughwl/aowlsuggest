#!/usr/bin/env bash
# stress.sh -- realism stress test over DELIBERATELY malformed sources.
#
# The corpus is generated: each known-valid file (see valid_corpus in lib.sh) is
# damaged four ways with sed (drop a block-header colon, drop a closing paren,
# turn a `==` into `=` in an `if`, drop a routine's `=`), so the checker sees
# realistic breakage in real code.
#
# The zero-false-positive guarantee generalises to a monotonicity invariant the
# verify loop must never break:
#   (I1) error count AFTER fix  <=  error count BEFORE fix        (never worse)
#   (I2) if fix CHANGED the file, then AFTER < BEFORE            (every applied
#        edit strictly reduced errors -- because each was verified)
#
# A single violation means a fix corrupted code, so this is a hard gate. SAMPLE
# (default 40) caps the number of source files damaged; the sample is
# deterministic (every k-th file of the sorted corpus).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SAMPLE="${SAMPLE:-40}"
fail=0

mapfile -t ALL < <(valid_corpus)
[ "${#ALL[@]}" -gt 0 ] || { echo "stress: no corpus files (skipping)"; exit 0; }
stride=$(( (${#ALL[@]} + SAMPLE - 1) / SAMPLE ))
[ "$stride" -ge 1 ] || stride=1
FILES=()
for ((i=0; i<${#ALL[@]}; i+=stride)); do FILES+=("${ALL[$i]}"); done
echo "stress: damaging ${#FILES[@]} of ${#ALL[@]} corpus files (4 mutants each)"

scratch="$(mkwork)"; trap 'rm -rf "$scratch"' EXIT

errcount() {  # errors reported for $1
  "$AS" check --no-config --format:json "$1" 2>/dev/null | grep -o '"severity":"error"' | wc -l
}

mutate() {  # $1 = mode, stdin -> stdout
  case "$1" in
    colon)  sed '0,/:$/s/:$//' ;;
    paren)  sed '0,/)/s/)//' ;;
    eq)     sed '0,/^ *\(if\|while\|elif\) .*==/s/==/=/' ;;
    routine) sed '0,/^proc .* =$/s/ =$//' ;;
  esac
}

mutants=0
changedFiles=0
improved=0
worsened=0
for f in "${FILES[@]}"; do
  for mode in colon paren eq routine; do
    mutate "$mode" < "$f" > "$scratch/m.aowl"
    cmp -s "$f" "$scratch/m.aowl" && continue   # the pattern did not occur
    mutants=$((mutants+1))
    cp "$scratch/m.aowl" "$scratch/orig.aowl"
    before="$(errcount "$scratch/m.aowl")"
    "$AS" fix --no-config "$scratch/m.aowl" --write >/dev/null 2>&1
    after="$(errcount "$scratch/m.aowl")"
    if [ "$after" -gt "$before" ]; then
      echo "FAIL (I1): fix INCREASED errors ($before -> $after): $f [$mode]"
      worsened=$((worsened+1)); fail=1
    fi
    if ! cmp -s "$scratch/orig.aowl" "$scratch/m.aowl"; then
      changedFiles=$((changedFiles+1))
      if [ "$after" -ge "$before" ]; then
        echo "FAIL (I2): fix changed the file but did not reduce errors ($before -> $after): $f [$mode]"
        fail=1
      else
        improved=$((improved+1))
      fi
    fi
  done
done

echo "stress: mutants=$mutants changed=$changedFiles improved=$improved worsened=$worsened"
[ "$mutants" -gt 0 ] || { echo "stress: FAIL -- no mutants generated"; exit 1; }
if [ "$fail" -eq 0 ]; then
  echo "stress: PASS -- no fix ever increased errors; every change reduced them"
else
  echo "stress: FAILURES above"
fi
exit "$fail"
