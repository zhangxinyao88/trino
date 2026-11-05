#!/usr/bin/env bash
set -euo pipefail
cd /source
mkdir -p /evidence
[[ $(uname -m) == x86_64 ]]
export JAVA_TOOL_OPTIONS=-XX:ActiveProcessorCount=4
export CONTINUOUS_INTEGRATION=true
{ uname -a; java -version; nproc; cat /etc/os-release; } > /evidence/environment.txt 2>&1
run_step() {
  local label=$1 cap=$2
  shift 2
  printf 'Starting %s\n' "$label"
  set +e
  timeout --signal=TERM --kill-after=30s "$cap" ./mvnw -B -ntp "$@" > "/evidence/${label}.log" 2>&1
  local result=$?
  set -e
  printf '%s\n' "$result" > "/evidence/${label}.exit"
  tail -40 "/evidence/${label}.log"
  if ((result != 0)); then exit "$result"; fi
}
export MAVEN_OPTS='-Xmx3G -XX:+ExitOnOutOfMemoryError'
run_step build 20m -T 1C -pl testing/trino-faulttolerant-tests -am install -DskipTests -Dmaven.source.skip=true -Dair.check.skip-all=true
export MAVEN_OPTS='-Xmx512M -XX:+ExitOnOutOfMemoryError'
run_step format 5m -pl core/trino-main airstyle:check
run_step focused-tests 10m -pl core/trino-main test -Dair.check.skip-all=true -Dtest=TestPreSchedulingTaskContext,TestBinPackingNodeAllocator
cp -r core/trino-main/target/surefire-reports /evidence/core-reports
run_step static-checks 15m -pl core/trino-main verify -DskipTests -P ci
run_step error-prone 15m -pl core/trino-main clean test-compile -Dair.check.skip-all=true -P errorprone-compiler
run_step fte-tests 12m -pl testing/trino-faulttolerant-tests test -Dair.check.skip-all=true -Dsurefire.runOrder.random.seed=400202005801
cp -r testing/trino-faulttolerant-tests/target/surefire-reports /evidence/fte-reports
