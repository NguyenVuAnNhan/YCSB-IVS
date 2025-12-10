package com.yahoo.yscb.db.neo4j;

import site.ycsb.DB;
import site.ycsb.Status;

public class Neo4jClient extends DB {

    private Neo4JConnection conn;
    private Neo4JClientConfig config;

    @Override
    public Status init() throws DBException {
        Properties props = getProperties();

        String url = props.getProperty("url");
        String username = props.getProperty("username");
        String password = props.getProperty("password");

        config = new Neo4JClientConfig(url, username, password);
        conn = new Neo4JConnection(config);

        return Status.OK;
    }

    @Override
    public Status cleanup() throws DBException {
        try {
            conn.close();
        } catch (Exception e) {
            return Status.ERROR;
        }
        return Status.OK;
    }

    @Override   
    public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result) {
        try {
            return conn.read(table, key, fields, result);
        } catch (Exception e) {
            return Status.ERROR;
        }
    }

    @Override
    public Status update(String table, String key, Map<String, ByteIterator> values) {
        try {
            return conn.update(table, key, values);
        } catch (Exception e) {
            return Status.ERROR;
        }
    }

    @Override
    public Status insert(String table, String key, Map<String, ByteIterator> values) {
        try {
            return conn.insert(table, key, values);
        } catch (Exception e) {
            return Status.ERROR;
        }
    }

    @Override
    public Status scan(String table, String startkey, int recordcount, Set<String> fields, Vector<HashMap<String, ByteIterator>> result) {
        try {
            return conn.scan(table, startkey, recordcount, fields, result);
        } catch (Exception e) {
            return Status.ERROR;
        }
    }

    @Override
    public Status delete(String table, String key) {
        try {
            return conn.delete(table, key);
        } catch (Exception e) {
            return Status.ERROR;
        }
    }
}
