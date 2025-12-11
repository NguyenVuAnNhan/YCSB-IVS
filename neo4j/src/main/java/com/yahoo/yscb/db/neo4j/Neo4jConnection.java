import org.neo4j.driver.AuthTokens;
import org.neo4j.driver.Driver;
import org.neo4j.driver.GraphDatabase;
import org.neo4j.driver.Session;

public class Neo4jConnection {
    private final Driver driver;
    private final Session session;

    public Neo4jConnection(Neo4jConfig config) {
        driver = GraphDatabase.driver(config.url(), AuthTokens.basic(config.username(), config.password()));
        session = driver.session();
    }

    public void close() {
        session.close();
        driver.close();
    }

    public Status insert(String table, String key, Map<String, ByteIterator> values) {
        try {
            Map<String, Object> props = new HashMap<>();
            values.forEach((k, v) -> props.put(k, v.toString()));

            Result result = session.run(
                "CREATE (n:" + table + " {id: $key}) SET n += $props",
                Values.parameters("key", key, "props", props)
            );

            result.consume();

            return Status.OK;
        } catch (Exception e) {
            return Status.ERROR;
        }
    }

    public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result) {
        try {
            Result result = session.run(
                "MATCH (n:" + table + " {id: $key}) RETURN n",
                Values.parameters("key", key)
            ).single();

            var node = result.single().get("n").asNode();

            node.asMap().forEach((k, v) -> {
                result.put(k, new StringByteIterator(v.toString()));
            });

            result.consume();

            return Status.OK;

        } catch (Exception e) {
            return Status.ERROR;
        }
    }

    public Status update(String table, String key, Map<String, ByteIterator> values) {
        try {
            Map<String, Object> props = new HashMap<>();
            values.forEach((k, v) -> props.put(k, v.toString()));

            Result result = session.run(
                "MATCH (n:" + table + " {id: $key}) SET n += $props",
                Values.parameters("key", key, "props", props)
            );

            result.consume();

            return Status.OK;
        } catch (Exception e) {
            return Status.ERROR;
        }
    }

    public Status delete(String table, String key) {
        try {
            Result result = session.run(
                "MATCH (n:" + table + " {id: $key}) DETACH DELETE n",
                Values.parameters("key", key)
            );

            result.consume();

            return Status.OK;
        } catch (Exception e) {
            return Status.ERROR;
        }
    }

    public Status scan(String table, String startKey, int recordCount, Set<String> fields, Vector<HashMap<String, ByteIterator>> result) {
        try {
            Result result = session.run(
                "MATCH (n:" + table + ") " +
                "WHERE n.id >= $startKey " +
                "RETURN n ORDER BY n.id LIMIT $limit",
                Values.parameters("startKey", startKey, "limit", recordCount)
            );

            while (result.hasNext()) {
                var node = result.next().get("n").asNode();
                var map = new HashMap<String, ByteIterator>();
                node.asMap().forEach((k, v) ->
                    map.put(k, new StringByteIterator(v.toString()))
                );
                result.add(map);
            }

            result.consume();

            return Status.OK;

        } catch (Exception e) {
            return Status.ERROR;
        }
    }
}
