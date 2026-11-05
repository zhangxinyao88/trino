#!/usr/bin/env bash
# Diagnostic harness only; does not modify the checked-out test sources.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
probe_evidence="$PWD/evidence"
mkdir -p ${probe_evidence}
[[ $(uname -m) == x86_64 ]]
{ uname -a; cat /etc/os-release; java -version; nproc; } > ${probe_evidence}/environment.txt 2>&1
export MAVEN_ARGS="--global-settings $PWD/.mvn/settings-ci.xml -ntp"
export MAVEN_OPTS='-Xmx3G -XX:+ExitOnOutOfMemoryError'
export CONTINUOUS_INTEGRATION=true
set +e
timeout --signal=TERM --kill-after=30s 20m ./mvnw -B -ntp -T 1C -pl testing/trino-faulttolerant-tests -am install -DskipTests -Dmaven.source.skip=true -Dair.check.skip-all=true > ${probe_evidence}/build.log 2>&1
build_rc=$?
set -e
printf '%s\n' "$build_rc" > ${probe_evidence}/build.exit
if ((build_rc != 0)); then tail -100 ${probe_evidence}/build.log; exit "$build_rc"; fi
export MAVEN_OPTS='-Xmx512M -XX:+ExitOnOutOfMemoryError'
# Capture before CI's outer timeout can kill the JVM. A heap snapshot after
# ten minutes retains scheduler event queues and allocator pending/held leases.
watch_test() {
  local started=$SECONDS elapsed heap_taken=false
  while sleep 60; do
    elapsed=$((SECONDS - started))
    if ((elapsed < 480)); then continue; fi
    jcmd -l > "${attempt_dir}/jvms-${elapsed}.txt" 2>&1 || true
    while read -r pid rest; do
      [[ "$rest" == *surefirebooter* ]] || continue
      timeout 30s jcmd "$pid" Thread.print -l > "${attempt_dir}/threads-${pid}-${elapsed}.txt" 2>&1 || true
      if ((elapsed >= 600)) && [[ $heap_taken == false ]]; then
        timeout 90s jcmd "$pid" GC.heap_dump -gz=3 "${attempt_dir}/heap-${pid}.hprof.gz" > "${attempt_dir}/heap-${pid}.log" 2>&1 || true
      fi
    done < "${attempt_dir}/jvms-${elapsed}.txt"
    if ((elapsed >= 600)); then heap_taken=true; fi
    { cat /proc/meminfo; cat /proc/loadavg; } > "${attempt_dir}/resources-${elapsed}.txt"
  done
}
# Five native repetitions, then one higher-concurrency stress invocation.
# Stop this source on the first failed invocation and retain its evidence.
started_tests=$SECONDS
for attempt in 1 2 3 4 5 6; do
  extra_args=()
  if ((attempt == 6)); then
    extra_args=(-Djunit.jupiter.execution.parallel.config.strategy=fixed -Djunit.jupiter.execution.parallel.config.fixed.parallelism=8)
  fi
  # Reserve a full invocation timeout and collection overhead before starting.
  if ((SECONDS - started_tests > 1800)); then
    printf 'INCOMPLETE: test budget reached before attempt %s\n' "$attempt" > ${probe_evidence}/repetition-status.txt
    exit 125
  fi
  attempt_dir="${probe_evidence}/attempt-${attempt}"
  mkdir -p "$attempt_dir"
  date -u +%FT%TZ > "$attempt_dir/started.txt"
  printf 'Starting attempt %s of 6\n' "$attempt"
  watch_test &
  watcher=$!
  trap 'kill "$watcher" 2>/dev/null || true' EXIT
  set +e
  timeout --signal=TERM --kill-after=30s 12m ./mvnw -B -ntp -pl testing/trino-faulttolerant-tests -P default test -Dmaven.source.skip=true -Dair.check.skip-all=true --fail-at-end -Dsurefire.runOrder.random.seed=237457222018 "${extra_args[@]}" > "$attempt_dir/test.log" 2>&1
  test_rc=$?
  set -e
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  trap - EXIT
  printf '%s\n' "$test_rc" > "$attempt_dir/test.exit"
  date -u +%FT%TZ > "$attempt_dir/finished.txt"
  # Move rather than reuse XML from a previous invocation.
  if [[ -d testing/trino-faulttolerant-tests/target/surefire-reports ]]; then
    mv testing/trino-faulttolerant-tests/target/surefire-reports "$attempt_dir/"
  fi
  tail -30 "$attempt_dir/test.log"
  if ((test_rc != 0)); then
    printf 'STOPPED: attempt %s exit %s\n' "$attempt" "$test_rc" > ${probe_evidence}/repetition-status.txt
    exit "$test_rc"
  fi
done
printf 'COMPLETED: 5 of 6 invocations exited zero\n' > ${probe_evidence}/repetition-status.txt
