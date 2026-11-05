#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence
export CONTINUOUS_INTEGRATION=true
export MAVEN_ARGS="--global-settings $PWD/.mvn/settings-ci.xml -ntp"
export MAVEN_OPTS='-Xmx3G -XX:+ExitOnOutOfMemoryError'
main=core/trino-main/src/main/java/io/trino/execution/scheduler/faulttolerant/EventDrivenFaultTolerantQueryScheduler.java
# Keep the actual fix in the commit; temporarily restore old ownership timing for the negative control.
cp "$main" evidence/scheduler-fixed.java
python3 - "$main" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text()
s=s.replace('PreSchedulingTaskContext context = preSchedulingTaskContexts.getContext(scheduledTask);', 'PreSchedulingTaskContext context = preSchedulingTaskContexts.removeContext(scheduledTask);',1)
a='Optional<RemoteTask> remoteTask = stageExecution.schedule(partitionId, sinkInstanceHandle, attempt, nodeLease, context.getExecutionClass().isSpeculative());\n            preSchedulingTaskContexts.removeContext(scheduledTask);'
assert a in s;s=s.replace(a,a.split('\n')[0],1);p.write_text(s)
PY
trap 'cp evidence/scheduler-fixed.java "$main"' EXIT
timeout 20m ./mvnw -B -T 1C -pl testing/trino-faulttolerant-tests -am install -DskipTests -Dmaven.source.skip=true -Dair.check.skip-all=true > evidence/control-build.log 2>&1
export MAVEN_OPTS='-Xmx512M -XX:+ExitOnOutOfMemoryError'
set +e
timeout 3m ./mvnw -B -pl testing/trino-faulttolerant-tests test -Dtest=TestFteSchedulingFailureLease -Dair.check.skip-all=true > evidence/control-test.log 2>&1
control_exit=$?
set -e
printf '%s\n' "$control_exit" > evidence/control-test.exit
cp -R testing/trino-faulttolerant-tests/target/surefire-reports evidence/control-reports
python3 - "$control_exit" <<'PY'
import sys,xml.etree.ElementTree as E
assert int(sys.argv[1]) == 1, 'negative control must fail with a test failure, not timeout/build error'
x=E.parse('evidence/control-reports/TEST-io.trino.faulttolerant.TestFteSchedulingFailureLease.xml').getroot()
assert x.get('failures') == '1' and x.get('errors') == '0', x.attrib
f=x.find('testcase/failure');print(f.get('message'))
assert 'expected: 0' in f.get('message',''), 'must fail on leaked acquired-node count'
PY
cp evidence/scheduler-fixed.java "$main"
trap - EXIT
export MAVEN_OPTS='-Xmx3G -XX:+ExitOnOutOfMemoryError'
timeout 10m ./mvnw -B -pl core/trino-main airstyle:check > evidence/format.log 2>&1
timeout 15m ./mvnw -B -T 1C -pl core/trino-main install -DskipTests -Dair.check.skip-all=true > evidence/fix-build.log 2>&1
export MAVEN_OPTS='-Xmx512M -XX:+ExitOnOutOfMemoryError'
timeout 3m ./mvnw -B -pl testing/trino-faulttolerant-tests test -Dtest=TestFteSchedulingFailureLease -Dair.check.skip-all=true > evidence/fix-test.log 2>&1
cp -R testing/trino-faulttolerant-tests/target/surefire-reports evidence/fix-reports
timeout 12m ./mvnw -B -pl testing/trino-faulttolerant-tests -P default test -Dtest=TestDistributedFaultTolerantEngineOnlyQueries,TestFaultTolerantExecutionDynamicFiltering,TestFaultTolerantExchangeDataLossRetry,TestFaultTolerantMetadataOnlyQueries -Dair.check.skip-all=true -Dsurefire.runOrder.random.seed=237457222018 > evidence/fte-test.log 2>&1
cp -R testing/trino-faulttolerant-tests/target/surefire-reports evidence/fte-reports
export MAVEN_OPTS='-Xmx3G -XX:+ExitOnOutOfMemoryError'
timeout 12m ./mvnw -B verify -DskipTests -P ci -pl core/trino-main,testing/trino-faulttolerant-tests > evidence/static.log 2>&1
timeout 12m ./mvnw -B clean test-compile -Dair.check.skip-all=true -P errorprone-compiler -pl core/trino-main,testing/trino-faulttolerant-tests > evidence/errorprone.log 2>&1
git diff --exit-code > evidence/source-restored.txt
printf 'CONTROL_FAIL_FIX_PASS_VERIFIED\n' > evidence/result.txt
