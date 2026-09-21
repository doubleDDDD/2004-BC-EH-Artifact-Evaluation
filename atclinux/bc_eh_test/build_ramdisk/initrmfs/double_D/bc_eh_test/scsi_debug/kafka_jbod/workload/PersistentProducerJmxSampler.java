import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import javax.management.Attribute;
import javax.management.AttributeList;
import javax.management.MBeanServerConnection;
import javax.management.ObjectName;
import javax.management.remote.JMXConnector;
import javax.management.remote.JMXConnectorFactory;
import javax.management.remote.JMXServiceURL;

public final class PersistentProducerJmxSampler {
    private static final String[] TOPIC_ATTRS = {
        "byte-total",
        "record-send-total",
        "record-error-total",
        "record-retry-total"
    };
    private static final String[] CLIENT_ATTRS = {
        "request-latency-avg",
        "request-latency-max",
        "requests-in-flight"
    };
    private static final DateTimeFormatter UTC_FMT =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
            .withZone(ZoneOffset.UTC);

    private final String jmxUrl;
    private final long intervalMs;
    private final String clientId;
    private final String topic;
    private final ObjectName topicQueryPattern;
    private final ObjectName clientQueryPattern;
    private final BufferedWriter topicWriter;
    private final BufferedWriter clientWriter;

    private volatile boolean running = true;
    private JMXConnector connector;
    private MBeanServerConnection connection;
    private boolean topicMissingLogged;
    private boolean clientMissingLogged;
    private boolean connectFailureLogged;
    private String selectedTopicObjectName;
    private String selectedClientObjectName;

    private PersistentProducerJmxSampler(
        String jmxUrl,
        String clientId,
        String topic,
        long intervalMs,
        Path topicOutput,
        Path clientOutput
    ) throws Exception {
        this.jmxUrl = jmxUrl;
        this.intervalMs = intervalMs;
        this.clientId = clientId;
        this.topic = topic;
        this.topicQueryPattern = new ObjectName("kafka.producer:type=producer-topic-metrics,*");
        this.clientQueryPattern = new ObjectName("kafka.producer:type=producer-metrics,*");
        this.topicWriter = Files.newBufferedWriter(topicOutput, java.nio.file.StandardOpenOption.APPEND);
        this.clientWriter = Files.newBufferedWriter(clientOutput, java.nio.file.StandardOpenOption.APPEND);
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 6) {
            System.err.println(
                "usage: java PersistentProducerJmxSampler.java "
                    + "<jmx_url> <client_id> <topic> <interval_ms> <topic_csv> <client_csv>"
            );
            System.exit(2);
        }

        long intervalMs = Long.parseLong(args[3]);
        PersistentProducerJmxSampler sampler = new PersistentProducerJmxSampler(
            args[0],
            args[1],
            args[2],
            intervalMs,
            Path.of(args[4]),
            Path.of(args[5])
        );

        Runtime.getRuntime().addShutdownHook(new Thread(sampler::shutdown));
        sampler.run();
    }

    private void run() {
        long intervalNanos = intervalMs * 1_000_000L;
        long nextTick = System.nanoTime();

        while (running) {
            long now = System.nanoTime();
            if (now < nextTick) {
                sleepNanos(nextTick - now);
            }

            Instant sampleInstant = Instant.now();
            long sampleEpochMs = sampleInstant.toEpochMilli();
            String sampleUtc = UTC_FMT.format(sampleInstant);

            try {
                ensureConnected();
                Map<String, String> topicValues = readAttributes(true, sampleUtc);
                Map<String, String> clientValues = readAttributes(false, sampleUtc);

                writeTopicRow(sampleUtc, sampleEpochMs, topicValues);
                writeClientRow(sampleUtc, sampleEpochMs, clientValues);
            } catch (Exception e) {
                System.err.println("[producer-jmx][warn] sample failed at " + sampleUtc + ": " + e);
                closeConnection();
                writeTopicRow(sampleUtc, sampleEpochMs, blankMap(TOPIC_ATTRS));
                writeClientRow(sampleUtc, sampleEpochMs, blankMap(CLIENT_ATTRS));
            }

            nextTick += intervalNanos;
            long after = System.nanoTime();
            if (nextTick <= after) {
                long behind = after - nextTick;
                long skip = behind / intervalNanos + 1;
                nextTick += skip * intervalNanos;
            }
        }

        closeQuietly(topicWriter);
        closeQuietly(clientWriter);
        closeConnection();
    }

    private void ensureConnected() throws IOException {
        if (connection != null) {
            return;
        }

        try {
            connector = JMXConnectorFactory.connect(new JMXServiceURL(jmxUrl));
            connection = connector.getMBeanServerConnection();
            topicMissingLogged = false;
            clientMissingLogged = false;
            connectFailureLogged = false;
            System.err.println("[producer-jmx] Connected to " + jmxUrl);
        } catch (IOException e) {
            if (!connectFailureLogged) {
                System.err.println("[producer-jmx][warn] Failed to connect to " + jmxUrl + ": " + e);
                connectFailureLogged = true;
            }
            throw e;
        }
    }

    private Map<String, String> readAttributes(boolean topicMetrics, String sampleUtc) throws Exception {
        ObjectName objectName = topicMetrics
            ? findMatchingObjectName(topicQueryPattern, true)
            : findMatchingObjectName(clientQueryPattern, false);
        String[] attrs = topicMetrics ? TOPIC_ATTRS : CLIENT_ATTRS;
        Map<String, String> out = blankMap(attrs);

        if (objectName == null) {
            if (topicMetrics) {
                if (!topicMissingLogged) {
                    System.err.println(
                        "[producer-jmx][warn] producer-topic MBean not found at "
                            + sampleUtc
                            + " for client-id="
                            + clientId
                            + ", topic="
                            + topic
                    );
                    dumpVisibleProducerMBeans();
                    topicMissingLogged = true;
                }
            } else {
                if (!clientMissingLogged) {
                    System.err.println(
                        "[producer-jmx][warn] producer-client MBean not found at "
                            + sampleUtc
                            + " for client-id="
                            + clientId
                    );
                    dumpVisibleProducerMBeans();
                    clientMissingLogged = true;
                }
            }
            return out;
        }

        if (topicMetrics) {
            topicMissingLogged = false;
        } else {
            clientMissingLogged = false;
        }

        AttributeList attrList = connection.getAttributes(objectName, attrs);
        for (Attribute attribute : attrList.asList()) {
            Object value = attribute.getValue();
            out.put(attribute.getName(), value == null ? "" : String.valueOf(value));
        }
        return out;
    }

    private ObjectName findMatchingObjectName(ObjectName queryPattern, boolean topicMetrics) throws IOException {
        Set<ObjectName> matches = connection.queryNames(queryPattern, null);
        if (matches.isEmpty()) {
            return null;
        }

        List<ScoredCandidate> scored = new ArrayList<>();
        for (ObjectName candidate : matches) {
            scored.add(new ScoredCandidate(candidate, scoreCandidate(candidate, topicMetrics)));
        }

        scored.sort(Comparator.comparingInt(ScoredCandidate::getScore).reversed());
        if (scored.isEmpty() || scored.get(0).getScore() <= 0) {
            return null;
        }

        ObjectName selected = scored.get(0).getObjectName();
        logSelectedObjectName(selected, topicMetrics);
        return selected;
    }

    private int scoreCandidate(ObjectName candidate, boolean topicMetrics) {
        String candidateType = valueOrEmpty(candidate.getKeyProperty("type"));
        String candidateClientId = valueOrEmpty(candidate.getKeyProperty("client-id"));
        String candidateTopic = valueOrEmpty(candidate.getKeyProperty("topic"));
        String candidateCanonical = candidate.getCanonicalName();
        String normalizedClientId = normalizeMetricIdentity(clientId);
        String normalizedTopic = normalizeMetricIdentity(topic);
        String normalizedCandidateClientId = normalizeMetricIdentity(candidateClientId);
        String normalizedCandidateTopic = normalizeMetricIdentity(candidateTopic);
        int score = 0;

        if (topicMetrics) {
            if ("producer-topic-metrics".equals(candidateType)) {
                score += 1000;
            }
        } else {
            if ("producer-metrics".equals(candidateType)) {
                score += 1000;
            }
        }

        if (candidateClientId.equals(clientId)) {
            score += 400;
        } else if (!normalizedClientId.isEmpty()
            && normalizedCandidateClientId.equals(normalizedClientId)) {
            score += 300;
        } else if (!normalizedClientId.isEmpty()
            && normalizeMetricIdentity(candidateCanonical).contains(normalizedClientId)) {
            score += 150;
        }

        if (topicMetrics) {
            if (candidateTopic.equals(topic)) {
                score += 400;
            } else if (!normalizedTopic.isEmpty()
                && normalizedCandidateTopic.equals(normalizedTopic)) {
                score += 300;
            } else if (!normalizedTopic.isEmpty()
                && normalizeMetricIdentity(candidateCanonical).contains(normalizedTopic)) {
                score += 150;
            }
        } else if (candidate.getKeyProperty("topic") == null) {
            score += 50;
        }

        if (!candidateClientId.isEmpty()) {
            score += 10;
        }
        if (topicMetrics && !candidateTopic.isEmpty()) {
            score += 10;
        }

        return score;
    }

    private static String normalizeMetricIdentity(String value) {
        if (value == null) {
            return "";
        }
        return value.toLowerCase().replaceAll("[^a-z0-9]+", "");
    }

    private static String valueOrEmpty(String value) {
        return value == null ? "" : value;
    }

    private void logSelectedObjectName(ObjectName selected, boolean topicMetrics) {
        String selectedCanonical = selected.getCanonicalName();
        if (topicMetrics) {
            if (!selectedCanonical.equals(selectedTopicObjectName)) {
                System.err.println("[producer-jmx] Using producer-topic MBean: " + selectedCanonical);
                selectedTopicObjectName = selectedCanonical;
            }
            return;
        }

        if (!selectedCanonical.equals(selectedClientObjectName)) {
            System.err.println("[producer-jmx] Using producer-client MBean: " + selectedCanonical);
            selectedClientObjectName = selectedCanonical;
        }
    }

    private void dumpVisibleProducerMBeans() {
        try {
            Set<ObjectName> all = connection.queryNames(new ObjectName("kafka.producer:*"), null);
            int shown = 0;
            for (ObjectName name : all) {
                if (shown == 0) {
                    System.err.println("[producer-jmx][debug] visible kafka.producer MBeans:");
                }
                System.err.println("[producer-jmx][debug]   " + name);
                shown++;
                if (shown >= 64) {
                    break;
                }
            }
            if (shown == 0) {
                System.err.println("[producer-jmx][debug] no kafka.producer MBeans visible yet");
            }
        } catch (Exception e) {
            System.err.println("[producer-jmx][debug] failed to enumerate kafka.producer MBeans: " + e);
        }
    }

    private void writeTopicRow(String sampleUtc, long sampleEpochMs, Map<String, String> values) {
        writeRow(
            topicWriter,
            sampleUtc,
            Long.toString(sampleEpochMs),
            values.get("byte-total"),
            values.get("record-send-total"),
            values.get("record-error-total"),
            values.get("record-retry-total")
        );
    }

    private void writeClientRow(String sampleUtc, long sampleEpochMs, Map<String, String> values) {
        writeRow(
            clientWriter,
            sampleUtc,
            Long.toString(sampleEpochMs),
            values.get("request-latency-avg"),
            values.get("request-latency-max"),
            values.get("requests-in-flight")
        );
    }

    private static Map<String, String> blankMap(String[] attrs) {
        Map<String, String> out = new HashMap<>();
        for (String attr : attrs) {
            out.put(attr, "");
        }
        return out;
    }

    private static void writeRow(BufferedWriter writer, String... columns) {
        try {
            for (int i = 0; i < columns.length; i++) {
                if (i > 0) {
                    writer.write(',');
                }
                writer.write(columns[i] == null ? "" : columns[i]);
            }
            writer.newLine();
            writer.flush();
        } catch (IOException e) {
            throw new RuntimeException("failed to write CSV row", e);
        }
    }

    private static void sleepNanos(long nanos) {
        long millis = nanos / 1_000_000L;
        int extraNanos = (int) (nanos % 1_000_000L);
        try {
            Thread.sleep(millis, extraNanos);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private void shutdown() {
        running = false;
        closeConnection();
        closeQuietly(topicWriter);
        closeQuietly(clientWriter);
    }

    private void closeConnection() {
        if (connector != null) {
            try {
                connector.close();
            } catch (IOException ignored) {
                // ignore
            }
        }
        connector = null;
        connection = null;
    }

    private static void closeQuietly(BufferedWriter writer) {
        if (writer == null) {
            return;
        }
        try {
            writer.close();
        } catch (IOException ignored) {
            // ignore
        }
    }

    private static final class ScoredCandidate {
        private final ObjectName objectName;
        private final int score;

        private ScoredCandidate(ObjectName objectName, int score) {
            this.objectName = objectName;
            this.score = score;
        }

        private ObjectName getObjectName() {
            return objectName;
        }

        private int getScore() {
            return score;
        }
    }
}
