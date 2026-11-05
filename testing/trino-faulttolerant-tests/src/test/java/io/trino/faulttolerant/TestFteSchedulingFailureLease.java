/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.trino.faulttolerant;

import com.google.inject.Key;
import io.airlift.units.Duration;
import io.trino.execution.scheduler.faulttolerant.BinPackingNodeAllocatorService;
import io.trino.execution.scheduler.faulttolerant.NodeAllocatorService;
import io.trino.plugin.memory.MemoryQueryRunner;
import io.trino.testing.AbstractTestQueryFramework;
import io.trino.testing.FaultTolerantExecutionConnectorTestHelper;
import io.trino.testing.QueryRunner;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;

import java.util.List;

import static io.trino.testing.assertions.Assert.assertEventually;
import static io.trino.tpch.TpchTable.NATION;
import static java.util.concurrent.TimeUnit.SECONDS;
import static org.assertj.core.api.Assertions.assertThat;

public class TestFteSchedulingFailureLease
        extends AbstractTestQueryFramework
{
    @Override
    protected QueryRunner createQueryRunner()
            throws Exception
    {
        return MemoryQueryRunner.builder()
                .setExtraProperties(FaultTolerantExecutionConnectorTestHelper.getExtraProperties())
                .withExchange("filesystem")
                .setInitialTables(List.of(NATION))
                .build();
    }

    @Test
    @Timeout(30)
    public void testSchedulingFailureReleasesNode()
    {
        BinPackingNodeAllocatorService allocator = (BinPackingNodeAllocatorService) getDistributedQueryRunner()
                .getCoordinator().getInstance(Key.get(NodeAllocatorService.class));
        assertEventually(new Duration(5, SECONDS), () -> assertThat(allocator.testingFulfilledAcquiresCount()).isZero());
        System.setProperty("trino.test.fail-task-scheduling", "true");
        try {
            assertQueryFails("SELECT count(*) FROM nation", ".*FTE_INJECTED_SCHEDULE_FAILURE.*");
        }
        finally {
            System.clearProperty("trino.test.fail-task-scheduling");
        }
        assertEventually(new Duration(5, SECONDS), () -> assertThat(allocator.testingFulfilledAcquiresCount()).isZero());
        assertQuery("SELECT count(*) FROM nation", "VALUES 25");
    }
}
