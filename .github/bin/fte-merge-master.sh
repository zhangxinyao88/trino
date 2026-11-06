#!/usr/bin/env bash
set -euo pipefail
cd source
export MAVEN_ARGS="--global-settings $PWD/.mvn/settings-ci.xml -ntp"
export MAVEN_OPTS="-Xmx512M -XX:+ExitOnOutOfMemoryError"
evidence="$PWD/../evidence"
watch_test() {
    sleep 480
    jcmd -l > "$evidence/jvms.txt" 2>&1 || true
    while read -r pid rest; do
        [[ "$rest" == *surefirebooter* ]] || continue
        timeout 30s jcmd "$pid" Thread.print -l > "$evidence/threads-$pid.txt" 2>&1 || true
    done < "$evidence/jvms.txt"
}
watch_test &
watcher=$!
set +e
timeout 12m ./mvnw -B -ntp -pl testing/trino-faulttolerant-tests -P default test -Dmaven.source.skip=true -Dair.check.skip-all=true --fail-at-end -Dsurefire.runOrder.random.seed=400202005801 2>&1 | tee "$evidence/fte.log"
result=${PIPESTATUS[0]}
set -e
kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true
printf '%s\n' "$result" > "$evidence/test-exit.txt"
cp -R testing/trino-faulttolerant-tests/target/surefire-reports "$evidence/" || true
git diff --exit-code > "$evidence/source-diff.txt"
exit "$result"
