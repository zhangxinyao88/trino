#!/usr/bin/env bash
# Diagnostic harness only; does not modify the checked-out test sources.
set -euo pipefail
cd /source
mkdir -p /evidence
[[ $(uname -m) == x86_64 ]]
{ uname -a; cat /etc/os-release; java -version; nproc; } > /evidence/environment.txt 2>&1
export JAVA_TOOL_OPTIONS=-XX:ActiveProcessorCount=4
export MAVEN_OPTS='-Xmx3G -XX:+ExitOnOutOfMemoryError'
export CONTINUOUS_INTEGRATION=true
set +e
timeout --signal=TERM --kill-after=30s 40m ./mvnw -B -ntp -T 1C -pl testing/trino-faulttolerant-tests -am install -DskipTests -Dmaven.source.skip=true -Dair.check.skip-all=true > /evidence/build.log 2>&1
build_rc=$?
set -e
printf '%s\n' "$build_rc" > /evidence/build.exit
if ((build_rc != 0)); then tail -100 /evidence/build.log; exit "$build_rc"; fi
export MAVEN_OPTS='-Xmx512M -XX:+ExitOnOutOfMemoryError'
# Capture before CI's outer timeout can kill the JVM. A heap snapshot after
# ten minutes retains scheduler event queues and allocator pending/held leases.
watch_test() {
  local elapsed=0
  while sleep 60; do
    elapsed=$((elapsed + 60))
    if ((elapsed < 480)); then continue; fi
    jcmd -l > "/evidence/jvms-${elapsed}.txt" 2>&1 || true
    while read -r pid rest; do
      [[ "$rest" == *surefirebooter* ]] || continue
      timeout 30s jcmd "$pid" Thread.print -l > "/evidence/threads-${pid}-${elapsed}.txt" 2>&1 || true
      if ((elapsed == 600)); then
        timeout 90s jcmd "$pid" GC.heap_dump -gz=3 "/evidence/heap-${pid}.hprof.gz" > "/evidence/heap-${pid}.log" 2>&1 || true
      fi
    done < "/evidence/jvms-${elapsed}.txt"
    { cat /proc/meminfo; cat /proc/loadavg; } > "/evidence/resources-${elapsed}.txt"
  done
}
watch_test &
watcher=$!
trap 'kill "$watcher" 2>/dev/null || true' EXIT
set +e
timeout --signal=TERM --kill-after=30s 28m ./mvnw -B -ntp -pl testing/trino-faulttolerant-tests test -Dmaven.source.skip=true -Dair.check.skip-all=true --fail-at-end -Dsurefire.runOrder.random.seed=400202005801 > /evidence/test.log 2>&1
test_rc=$?
set -e
printf '%s\n' "$test_rc" > /evidence/test.exit
cp -r testing/trino-faulttolerant-tests/target/surefire-reports /evidence/ 2>/dev/null || true
tail -100 /evidence/test.log
exit "$test_rc"
