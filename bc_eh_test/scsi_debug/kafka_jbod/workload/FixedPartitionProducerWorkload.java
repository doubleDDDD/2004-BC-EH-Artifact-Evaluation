import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Properties;
import java.util.TreeSet;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.LockSupport;

import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.admin.DescribeTopicsResult;
import org.apache.kafka.clients.admin.TopicDescription;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;

public class FixedPartitionProducerWorkload {
    private static final long NANOS_PER_SECOND = 1_000_000_000L;

    private static final class Args {
        String bootstrapServer;
        String topic;
        String partitionsSpec = "all";
        int recordSize;
        int totalThroughput;
        int reportingIntervalMs;
        int runSecs;
        String acks;
        int batchSize;
        int lingerMs;
        String compressionType;
        int requestTimeoutMs;
        int deliveryTimeoutMs;
        int maxBlockMs;
        int maxInFlightRequestsPerConnection;
        String clientIdPrefix;
        String workerSummaryCsv;
    }

    private static final class PartitionSpec {
        final int partition;
        final int targetRps;

        PartitionSpec(int partition, int targetRps) {
            this.partition = partition;
            this.targetRps = targetRps;
        }
    }

    private static final class WorkerStats {
        final int partition;
        final int targetRps;
        long successCount;
        long errorCount;
        long bytesSent;
        long latencyNsTotal;
        long maxLatencyNs;

        WorkerStats(int partition, int targetRps) {
            this.partition = partition;
            this.targetRps = targetRps;
        }

        synchronized void recordSuccess(long bytes, long latencyNs) {
            successCount++;
            bytesSent += bytes;
            latencyNsTotal += latencyNs;
            if (latencyNs > maxLatencyNs) {
                maxLatencyNs = latencyNs;
            }
        }

        synchronized void recordError() {
            errorCount++;
        }
    }

    private static final class IntervalStats {
        private final AtomicLong intervalSuccessCount = new AtomicLong();
        private final AtomicLong intervalBytesSent = new AtomicLong();
        private final AtomicLong intervalLatencyNsTotal = new AtomicLong();
        private final AtomicLong intervalMaxLatencyNs = new AtomicLong();

        void recordSuccess(long bytes, long latencyNs) {
            intervalSuccessCount.incrementAndGet();
            intervalBytesSent.addAndGet(bytes);
            intervalLatencyNsTotal.addAndGet(latencyNs);
            updateMax(intervalMaxLatencyNs, latencyNs);
        }

        Snapshot drain() {
            long successCount = intervalSuccessCount.getAndSet(0L);
            long bytesSent = intervalBytesSent.getAndSet(0L);
            long latencyNsTotal = intervalLatencyNsTotal.getAndSet(0L);
            long maxLatencyNs = intervalMaxLatencyNs.getAndSet(0L);
            return new Snapshot(successCount, bytesSent, latencyNsTotal, maxLatencyNs);
        }
    }

    private static final class Snapshot {
        final long successCount;
        final long bytesSent;
        final long latencyNsTotal;
        final long maxLatencyNs;

        Snapshot(long successCount, long bytesSent, long latencyNsTotal, long maxLatencyNs) {
            this.successCount = successCount;
            this.bytesSent = bytesSent;
            this.latencyNsTotal = latencyNsTotal;
            this.maxLatencyNs = maxLatencyNs;
        }
    }

    private static final class Worker implements Runnable {
        private final Args args;
        private final PartitionSpec partitionSpec;
        private final byte[] payload;
        private final byte[] key;
        private final CountDownLatch readyLatch;
        private final CountDownLatch startLatch;
        private final CountDownLatch doneLatch;
        private final AtomicBoolean stop;
        private final IntervalStats intervalStats;
        private final WorkerStats workerStats;
        private final long runDurationNs;

        Worker(
            Args args,
            PartitionSpec partitionSpec,
            CountDownLatch readyLatch,
            CountDownLatch startLatch,
            CountDownLatch doneLatch,
            AtomicBoolean stop,
            IntervalStats intervalStats,
            WorkerStats workerStats
        ) {
            this.args = args;
            this.partitionSpec = partitionSpec;
            this.readyLatch = readyLatch;
            this.startLatch = startLatch;
            this.doneLatch = doneLatch;
            this.stop = stop;
            this.intervalStats = intervalStats;
            this.workerStats = workerStats;
            this.payload = buildPayload(args.recordSize, partitionSpec.partition);
            this.key = ("partition-" + partitionSpec.partition).getBytes(StandardCharsets.UTF_8);
            this.runDurationNs = args.runSecs * NANOS_PER_SECOND;
        }

        @Override
        public void run() {
            Properties producerProps = buildProducerProps(args, partitionSpec.partition);
            try (KafkaProducer<byte[], byte[]> producer = new KafkaProducer<>(producerProps)) {
                readyLatch.countDown();
                startLatch.await();

                final long startNs = System.nanoTime();
                final long endNs = startNs + runDurationNs;
                long sequence = 0L;

                while (!stop.get()) {
                    long scheduledNs = startNs + ((sequence * NANOS_PER_SECOND) / partitionSpec.targetRps);
                    long nowNs = System.nanoTime();

                    if (nowNs >= endNs) {
                        break;
                    }

                    if (scheduledNs > nowNs) {
                        LockSupport.parkNanos(scheduledNs - nowNs);
                    }

                    if (System.nanoTime() >= endNs || stop.get()) {
                        break;
                    }

                    long sendStartNs = System.nanoTime();
                    ProducerRecord<byte[], byte[]> record =
                        new ProducerRecord<>(args.topic, partitionSpec.partition, key, payload);
                    try {
                        producer.send(record).get();
                        long latencyNs = System.nanoTime() - sendStartNs;
                        intervalStats.recordSuccess(payload.length, latencyNs);
                        workerStats.recordSuccess(payload.length, latencyNs);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        stop.set(true);
                        break;
                    } catch (ExecutionException e) {
                        workerStats.recordError();
                        System.err.printf(
                            Locale.US,
                            "[fixed-partition-workload][warn] partition=%d send failed: %s%n",
                            partitionSpec.partition,
                            e.getCause() == null ? e.toString() : e.getCause().toString()
                        );
                    }

                    sequence++;
                }

                producer.flush();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                stop.set(true);
            } finally {
                doneLatch.countDown();
            }
        }
    }

    public static void main(String[] rawArgs) throws Exception {
        Args args = parseArgs(rawArgs);
        validateArgs(args);

        List<Integer> partitions = resolvePartitions(args);
        if (partitions.isEmpty()) {
            throw new IllegalArgumentException("no partitions selected");
        }
        if (args.totalThroughput < partitions.size()) {
            throw new IllegalArgumentException(
                "total throughput must be >= selected partition count; got throughput="
                + args.totalThroughput + ", partitions=" + partitions.size()
            );
        }

        List<PartitionSpec> partitionSpecs = allocateThroughput(partitions, args.totalThroughput);
        List<WorkerStats> workerStatsList = new ArrayList<>();
        IntervalStats intervalStats = new IntervalStats();
        AtomicBoolean stop = new AtomicBoolean(false);
        CountDownLatch readyLatch = new CountDownLatch(partitionSpecs.size());
        CountDownLatch startLatch = new CountDownLatch(1);
        CountDownLatch doneLatch = new CountDownLatch(partitionSpecs.size());
        List<Thread> workers = new ArrayList<>();

        Runtime.getRuntime().addShutdownHook(new Thread(() -> stop.set(true)));

        for (PartitionSpec partitionSpec : partitionSpecs) {
            WorkerStats workerStats = new WorkerStats(partitionSpec.partition, partitionSpec.targetRps);
            workerStatsList.add(workerStats);
            Thread thread = new Thread(
                new Worker(args, partitionSpec, readyLatch, startLatch, doneLatch, stop, intervalStats, workerStats),
                "fixed-partition-worker-" + partitionSpec.partition
            );
            thread.setDaemon(true);
            workers.add(thread);
            thread.start();
        }

        readyLatch.await();
        System.err.printf(
            Locale.US,
            "[fixed-partition-workload] starting workers=%d partitions=%s throughput=%d rps report=%d ms at %s%n",
            partitionSpecs.size(),
            partitions.toString(),
            args.totalThroughput,
            args.reportingIntervalMs,
            Instant.now().toString()
        );
        writeWorkerSummaryCsv(args.workerSummaryCsv, workerStatsList);

        long workloadStartNs = System.nanoTime();
        long nextReportNs = workloadStartNs + (args.reportingIntervalMs * 1_000_000L);
        long workloadEndNs = workloadStartNs + (args.runSecs * NANOS_PER_SECOND);
        startLatch.countDown();

        while (System.nanoTime() < workloadEndNs && !stop.get()) {
            long nowNs = System.nanoTime();
            if (nextReportNs > nowNs) {
                LockSupport.parkNanos(nextReportNs - nowNs);
            }

            emitIntervalReport(intervalStats.drain(), args.reportingIntervalMs);
            writeWorkerSummaryCsv(args.workerSummaryCsv, workerStatsList);
            nextReportNs += args.reportingIntervalMs * 1_000_000L;
        }

        stop.set(true);
        doneLatch.await();

        for (Thread worker : workers) {
            worker.join();
        }

        emitIntervalReport(intervalStats.drain(), args.reportingIntervalMs);
        writeWorkerSummaryCsv(args.workerSummaryCsv, workerStatsList);
        emitFinalSummary(workerStatsList);
    }

    private static Args parseArgs(String[] rawArgs) {
        Args args = new Args();

        for (int i = 0; i < rawArgs.length; i += 2) {
            if (i + 1 >= rawArgs.length) {
                throw new IllegalArgumentException("missing value for argument: " + rawArgs[i]);
            }

            String key = rawArgs[i];
            String value = rawArgs[i + 1];

            switch (key) {
                case "--bootstrap-server":
                    args.bootstrapServer = value;
                    break;
                case "--topic":
                    args.topic = value;
                    break;
                case "--partitions":
                    args.partitionsSpec = value;
                    break;
                case "--record-size":
                    args.recordSize = Integer.parseInt(value);
                    break;
                case "--throughput":
                    args.totalThroughput = Integer.parseInt(value);
                    break;
                case "--reporting-interval-ms":
                    args.reportingIntervalMs = Integer.parseInt(value);
                    break;
                case "--run-secs":
                    args.runSecs = Integer.parseInt(value);
                    break;
                case "--acks":
                    args.acks = value;
                    break;
                case "--batch-size":
                    args.batchSize = Integer.parseInt(value);
                    break;
                case "--linger-ms":
                    args.lingerMs = Integer.parseInt(value);
                    break;
                case "--compression-type":
                    args.compressionType = value;
                    break;
                case "--request-timeout-ms":
                    args.requestTimeoutMs = Integer.parseInt(value);
                    break;
                case "--delivery-timeout-ms":
                    args.deliveryTimeoutMs = Integer.parseInt(value);
                    break;
                case "--max-block-ms":
                    args.maxBlockMs = Integer.parseInt(value);
                    break;
                case "--max-in-flight-requests-per-connection":
                    args.maxInFlightRequestsPerConnection = Integer.parseInt(value);
                    break;
                case "--client-id-prefix":
                    args.clientIdPrefix = value;
                    break;
                case "--worker-summary-csv":
                    args.workerSummaryCsv = value;
                    break;
                default:
                    throw new IllegalArgumentException("unsupported argument: " + key);
            }
        }

        return args;
    }

    private static void validateArgs(Args args) {
        requireNonEmpty(args.bootstrapServer, "bootstrapServer");
        requireNonEmpty(args.topic, "topic");
        requireNonEmpty(args.acks, "acks");
        requireNonEmpty(args.compressionType, "compressionType");
        requireNonEmpty(args.clientIdPrefix, "clientIdPrefix");
        requireNonEmpty(args.workerSummaryCsv, "workerSummaryCsv");

        if (args.recordSize <= 0) {
            throw new IllegalArgumentException("recordSize must be > 0");
        }
        if (args.totalThroughput <= 0) {
            throw new IllegalArgumentException("throughput must be > 0");
        }
        if (args.reportingIntervalMs <= 0) {
            throw new IllegalArgumentException("reportingIntervalMs must be > 0");
        }
        if (args.runSecs <= 0) {
            throw new IllegalArgumentException("runSecs must be > 0");
        }
        if (args.batchSize <= 0) {
            throw new IllegalArgumentException("batchSize must be > 0");
        }
        if (args.requestTimeoutMs <= 0 || args.deliveryTimeoutMs <= 0 || args.maxBlockMs <= 0) {
            throw new IllegalArgumentException("timeout values must be > 0");
        }
        if (args.maxInFlightRequestsPerConnection <= 0) {
            throw new IllegalArgumentException("maxInFlightRequestsPerConnection must be > 0");
        }
    }

    private static void requireNonEmpty(String value, String name) {
        if (value == null || value.isEmpty()) {
            throw new IllegalArgumentException(name + " must not be empty");
        }
    }

    private static List<Integer> resolvePartitions(Args args) throws Exception {
        int topicPartitionCount = queryTopicPartitionCount(args.bootstrapServer, args.topic);
        if (topicPartitionCount <= 0) {
            throw new IllegalArgumentException("invalid topic partition count: " + topicPartitionCount);
        }

        if ("all".equalsIgnoreCase(args.partitionsSpec)) {
            List<Integer> partitions = new ArrayList<>(topicPartitionCount);
            for (int partition = 0; partition < topicPartitionCount; partition++) {
                partitions.add(partition);
            }
            return partitions;
        }

        TreeSet<Integer> partitions = new TreeSet<>();
        for (String token : args.partitionsSpec.split(",")) {
            String trimmed = token.trim();
            if (trimmed.isEmpty()) {
                continue;
            }

            int dashIndex = trimmed.indexOf('-');
            if (dashIndex >= 0) {
                int start = Integer.parseInt(trimmed.substring(0, dashIndex));
                int end = Integer.parseInt(trimmed.substring(dashIndex + 1));
                if (end < start) {
                    throw new IllegalArgumentException("invalid partition range: " + trimmed);
                }
                for (int partition = start; partition <= end; partition++) {
                    partitions.add(partition);
                }
                continue;
            }

            partitions.add(Integer.parseInt(trimmed));
        }

        List<Integer> selected = new ArrayList<>(partitions);
        for (int partition : selected) {
            if (partition < 0 || partition >= topicPartitionCount) {
                throw new IllegalArgumentException(
                    "partition " + partition + " is outside topic partition count " + topicPartitionCount
                );
            }
        }

        return selected;
    }

    private static int queryTopicPartitionCount(String bootstrapServer, String topic) throws Exception {
        Properties adminProps = new Properties();
        adminProps.setProperty("bootstrap.servers", bootstrapServer);

        try (Admin admin = Admin.create(adminProps)) {
            DescribeTopicsResult describeResult = admin.describeTopics(Collections.singletonList(topic));
            TopicDescription topicDescription = describeResult.topicNameValues().get(topic).get();
            return topicDescription.partitions().size();
        }
    }

    private static List<PartitionSpec> allocateThroughput(List<Integer> partitions, int totalThroughput) {
        int workerCount = partitions.size();
        int baseRate = totalThroughput / workerCount;
        int remainder = totalThroughput % workerCount;
        List<PartitionSpec> specs = new ArrayList<>(workerCount);

        for (int i = 0; i < workerCount; i++) {
            int targetRps = baseRate + (i < remainder ? 1 : 0);
            specs.add(new PartitionSpec(partitions.get(i), targetRps));
        }

        return specs;
    }

    private static Properties buildProducerProps(Args args, int partition) {
        Properties props = new Properties();
        props.setProperty("bootstrap.servers", args.bootstrapServer);
        props.setProperty("acks", args.acks);
        props.setProperty("batch.size", Integer.toString(args.batchSize));
        props.setProperty("linger.ms", Integer.toString(args.lingerMs));
        props.setProperty("compression.type", args.compressionType);
        props.setProperty("request.timeout.ms", Integer.toString(args.requestTimeoutMs));
        props.setProperty("delivery.timeout.ms", Integer.toString(args.deliveryTimeoutMs));
        props.setProperty("max.block.ms", Integer.toString(args.maxBlockMs));
        props.setProperty(
            "max.in.flight.requests.per.connection",
            Integer.toString(args.maxInFlightRequestsPerConnection)
        );
        props.setProperty("client.id", args.clientIdPrefix + "-p" + partition);
        props.setProperty(
            "key.serializer",
            "org.apache.kafka.common.serialization.ByteArraySerializer"
        );
        props.setProperty(
            "value.serializer",
            "org.apache.kafka.common.serialization.ByteArraySerializer"
        );
        return props;
    }

    private static byte[] buildPayload(int recordSize, int partition) {
        byte[] payload = new byte[recordSize];
        byte[] prefix = String.format(Locale.US, "partition=%d;", partition).getBytes(StandardCharsets.UTF_8);
        for (int i = 0; i < payload.length; i++) {
            payload[i] = (byte) ('a' + (i % 26));
        }
        System.arraycopy(prefix, 0, payload, 0, Math.min(prefix.length, payload.length));
        return payload;
    }

    private static void emitIntervalReport(Snapshot snapshot, int reportingIntervalMs) {
        double intervalSecs = reportingIntervalMs / 1000.0;
        double rate = snapshot.successCount / intervalSecs;
        double mbPerSec = snapshot.bytesSent / intervalSecs / (1024.0 * 1024.0);
        double avgLatencyMs = snapshot.successCount == 0
            ? 0.0
            : (snapshot.latencyNsTotal / 1_000_000.0) / snapshot.successCount;
        double maxLatencyMs = snapshot.maxLatencyNs / 1_000_000.0;

        System.out.printf(
            Locale.US,
            "%d records sent, %.1f records/sec (%.2f MB/sec), %.1f ms avg latency, %.1f ms max latency.%n",
            snapshot.successCount,
            rate,
            mbPerSec,
            avgLatencyMs,
            maxLatencyMs
        );
        System.out.flush();
    }

    private static void writeWorkerSummaryCsv(String workerSummaryCsv, List<WorkerStats> workerStatsList)
        throws Exception {
        try (java.io.PrintWriter writer = new java.io.PrintWriter(workerSummaryCsv, StandardCharsets.UTF_8.name())) {
            writer.println("partition,target_rps,records_sent,error_count,bytes_sent,avg_latency_ms,max_latency_ms");
            for (WorkerStats workerStats : workerStatsList) {
                synchronized (workerStats) {
                    double avgLatencyMs = workerStats.successCount == 0
                        ? 0.0
                        : (workerStats.latencyNsTotal / 1_000_000.0) / workerStats.successCount;
                    double maxLatencyMs = workerStats.maxLatencyNs / 1_000_000.0;
                    writer.printf(
                        Locale.US,
                        "%d,%d,%d,%d,%d,%.3f,%.3f%n",
                        workerStats.partition,
                        workerStats.targetRps,
                        workerStats.successCount,
                        workerStats.errorCount,
                        workerStats.bytesSent,
                        avgLatencyMs,
                        maxLatencyMs
                    );
                }
            }
        }
    }

    private static void emitFinalSummary(List<WorkerStats> workerStatsList) {
        long totalSuccess = 0L;
        long totalErrors = 0L;
        long totalBytes = 0L;
        long totalLatencyNs = 0L;
        long maxLatencyNs = 0L;

        for (WorkerStats workerStats : workerStatsList) {
            synchronized (workerStats) {
                totalSuccess += workerStats.successCount;
                totalErrors += workerStats.errorCount;
                totalBytes += workerStats.bytesSent;
                totalLatencyNs += workerStats.latencyNsTotal;
                if (workerStats.maxLatencyNs > maxLatencyNs) {
                    maxLatencyNs = workerStats.maxLatencyNs;
                }
            }
        }

        double avgLatencyMs = totalSuccess == 0 ? 0.0 : (totalLatencyNs / 1_000_000.0) / totalSuccess;
        double maxLatencyMs = maxLatencyNs / 1_000_000.0;

        System.err.printf(
            Locale.US,
            "[fixed-partition-workload] final success=%d errors=%d bytes=%d avg_latency_ms=%.3f max_latency_ms=%.3f%n",
            totalSuccess,
            totalErrors,
            totalBytes,
            avgLatencyMs,
            maxLatencyMs
        );
    }

    private static void updateMax(AtomicLong target, long candidate) {
        long current = target.get();
        while (candidate > current && !target.compareAndSet(current, candidate)) {
            current = target.get();
        }
    }
}
