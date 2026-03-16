/**
 * Copyright (c) 2010 - 2016 Yahoo! Inc., 2016, 2019 YCSB contributors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you
 * may not use this file except in compliance with the License. You
 * may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 * implied. See the License for the specific language governing
 * permissions and limitations under the License. See accompanying
 * LICENSE file.
 */
package site.ycsb.db;

import org.postgresql.util.PGobject;
import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;
import site.ycsb.StringByteIterator;
import site.ycsb.db.flavors.DBFlavor;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.Vector;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.regex.Pattern;

/**
 * A class that wraps a JDBC compliant database to allow it to be interfaced
 * with YCSB. This class extends {@link DB} and implements the database
 * interface used by YCSB client.
 *
 * <br>
 * Each client will have its own instance of this class. This client is not
 * thread safe.
 *
 * <br>
 * This interface expects a schema <key> <field1> <field2> <field3> ... All
 * attributes are JSON arrays stored in columns such as PostgreSQL JSONB.
 * All accesses are through the primary key. Therefore, only one index on the
 * primary key is needed.
 */
public class JdbcDBClient extends DB {

  /** The class to use as the jdbc driver. */
  public static final String DRIVER_CLASS = "db.driver";

  /** The URL to connect to the database. */
  public static final String CONNECTION_URL = "db.url";

  /** The user name to use to connect to the database. */
  public static final String CONNECTION_USER = "db.user";

  /** The password to use for establishing the connection. */
  public static final String CONNECTION_PASSWD = "db.passwd";

  /** The batch size for batched inserts. Set to >0 to use batching */
  public static final String DB_BATCH_SIZE = "db.batchsize";

  /** The JDBC fetch size hinted to the driver. */
  public static final String JDBC_FETCH_SIZE = "jdbc.fetchsize";

  /** The JDBC connection auto-commit property for the driver. */
  public static final String JDBC_AUTO_COMMIT = "jdbc.autocommit";

  public static final String JDBC_BATCH_UPDATES = "jdbc.batchupdateapi";

  /** The name of the property for the number of fields in a record. */
  public static final String FIELD_COUNT_PROPERTY = "fieldcount";

  /** Default number of fields in a record. */
  public static final String FIELD_COUNT_PROPERTY_DEFAULT = "10";

  /** Representing a NULL value. */
  public static final String NULL_VALUE = "NULL";

  /** The primary key in the user table. */
  public static final String PRIMARY_KEY = "YCSB_KEY";

  /** The field name prefix in the table. */
  public static final String COLUMN_PREFIX = "FIELD";

  /** The delimiter used to split/join array elements. */
  public static final String ARRAY_DELIMITER = "jdbc.array.delimiter";

  /** SQL:2008 standard: FETCH FIRST n ROWS after the ORDER BY. */
  private boolean sqlansiScans = false;
  /** SQL Server before 2012: TOP n after the SELECT. */
  private boolean sqlserverScans = false;

  private List<Connection> conns;
  private boolean initialized = false;
  private Properties props;
  private int jdbcFetchSize;
  private int batchSize;
  private boolean autoCommit;
  private boolean batchUpdates;
  private String arrayDelimiter;
  private String arrayDelimiterRegex;
  private boolean postgresJsonAppend;
  private static final String DEFAULT_PROP = "";
  private ConcurrentMap<StatementType, PreparedStatement> cachedStatements;
  private long numRowsInBatch = 0;
  /** DB flavor defines DB-specific syntax and behavior for the
   * particular database. Current database flavors are: {default, phoenix} */
  private DBFlavor dbFlavor;

  /**
   * Ordered field information for insert and update statements.
   */
  private static class OrderedFieldInfo {
    private String fieldKeys;
    private List<String> fieldValues;

    OrderedFieldInfo(String fieldKeys, List<String> fieldValues) {
      this.fieldKeys = fieldKeys;
      this.fieldValues = fieldValues;
    }

    String getFieldKeys() {
      return fieldKeys;
    }

    List<String> getFieldValues() {
      return fieldValues;
    }
  }

  /**
   * For the given key, returns what shard contains data for this key.
   *
   * @param key Data key to do operation on
   * @return Shard index
   */
  private int getShardIndexByKey(String key) {
    int ret = Math.abs(key.hashCode()) % conns.size();
    return ret;
  }

  /**
   * For the given key, returns Connection object that holds connection to the
   * shard that contains this key.
   *
   * @param key Data key to get information for
   * @return Connection object
   */
  private Connection getShardConnectionByKey(String key) {
    return conns.get(getShardIndexByKey(key));
  }

  private void cleanupAllConnections() throws SQLException {
    for (Connection conn : conns) {
      if (!autoCommit) {
        conn.commit();
      }
      conn.close();
    }
  }

  /** Returns parsed int value from the properties if set, otherwise returns -1. */
  private static int getIntProperty(Properties props, String key) throws DBException {
    String valueStr = props.getProperty(key);
    if (valueStr != null) {
      try {
        return Integer.parseInt(valueStr);
      } catch (NumberFormatException nfe) {
        System.err.println("Invalid " + key + " specified: " + valueStr);
        throw new DBException(nfe);
      }
    }
    return -1;
  }

  /** Returns parsed boolean value from the properties if set, otherwise returns defaultVal. */
  private static boolean getBoolProperty(Properties props, String key, boolean defaultVal) {
    String valueStr = props.getProperty(key);
    if (valueStr != null) {
      return Boolean.parseBoolean(valueStr);
    }
    return defaultVal;
  }

  @Override
  public void init() throws DBException {
    if (initialized) {
      System.err.println("Client connection already initialized.");
      return;
    }
    props = getProperties();
    String urls = props.getProperty(CONNECTION_URL, DEFAULT_PROP);
    String user = props.getProperty(CONNECTION_USER, DEFAULT_PROP);
    String passwd = props.getProperty(CONNECTION_PASSWD, DEFAULT_PROP);
    String driver = props.getProperty(DRIVER_CLASS);

    this.jdbcFetchSize = getIntProperty(props, JDBC_FETCH_SIZE);
    this.batchSize = getIntProperty(props, DB_BATCH_SIZE);

    this.autoCommit = getBoolProperty(props, JDBC_AUTO_COMMIT, true);
    this.batchUpdates = getBoolProperty(props, JDBC_BATCH_UPDATES, false);
    this.arrayDelimiter = props.getProperty(ARRAY_DELIMITER, ",");
    this.arrayDelimiterRegex = Pattern.quote(arrayDelimiter);

    try {
//  The SQL Syntax for Scan depends on the DB engine
//  - SQL:2008 standard: FETCH FIRST n ROWS after the ORDER BY
//  - SQL Server before 2012: TOP n after the SELECT
//  - others (MySQL,MariaDB, PostgreSQL before 8.4)
//  TODO: check product name and version rather than driver name
      if (driver != null) {
        if (driver.contains("sqlserver")) {
          sqlserverScans = true;
          sqlansiScans = false;
        }
        if (driver.contains("oracle")) {
          sqlserverScans = false;
          sqlansiScans = true;
        }
        if (driver.contains("postgres")) {
          sqlserverScans = false;
          sqlansiScans = true;
        }
        Class.forName(driver);
      }
      int shardCount = 0;
      conns = new ArrayList<Connection>(3);
      // for a longer explanation see the README.md
      // semicolons aren't present in JDBC urls, so we use them to delimit
      // multiple JDBC connections to shard across.
      final String[] urlArr = urls.split(";");
      if (urlArr.length > 0) {
        postgresJsonAppend = urlArr[0].startsWith("jdbc:postgresql");
      }
      for (String url : urlArr) {
        System.out.println("Adding shard node URL: " + url);
        Connection conn = DriverManager.getConnection(url, user, passwd);

        // Since there is no explicit commit method in the DB interface, all
        // operations should auto commit, except when explicitly told not to
        // (this is necessary in cases such as for PostgreSQL when running a
        // scan workload with fetchSize)
        conn.setAutoCommit(autoCommit);

        shardCount++;
        conns.add(conn);
      }

      System.out.println("Using shards: " + shardCount + ", batchSize:" + batchSize + ", fetchSize: " + jdbcFetchSize);

      cachedStatements = new ConcurrentHashMap<StatementType, PreparedStatement>();

      this.dbFlavor = DBFlavor.fromJdbcUrl(urlArr[0]);
    } catch (ClassNotFoundException e) {
      System.err.println("Error in initializing the JDBS driver: " + e);
      throw new DBException(e);
    } catch (SQLException e) {
      System.err.println("Error in database operation: " + e);
      throw new DBException(e);
    } catch (NumberFormatException e) {
      System.err.println("Invalid value for fieldcount property. " + e);
      throw new DBException(e);
    }

    initialized = true;
  }

  @Override
  public void cleanup() throws DBException {
    if (batchSize > 0) {
      try {
        // commit un-finished batches
        for (PreparedStatement st : cachedStatements.values()) {
          if (!st.getConnection().isClosed() && !st.isClosed() && (numRowsInBatch % batchSize != 0)) {
            st.executeBatch();
          }
        }
      } catch (SQLException e) {
        System.err.println("Error in cleanup execution. " + e);
        throw new DBException(e);
      }
    }

    try {
      cleanupAllConnections();
    } catch (SQLException e) {
      System.err.println("Error in closing the connection. " + e);
      throw new DBException(e);
    }

    super.cleanup();
  }

  private PreparedStatement createAndCacheInsertStatement(StatementType insertType, String key)
      throws SQLException {
    String insert = dbFlavor.createInsertStatement(insertType, key);
    PreparedStatement insertStatement = getShardConnectionByKey(key).prepareStatement(insert);
    PreparedStatement stmt = cachedStatements.putIfAbsent(insertType, insertStatement);
    if (stmt == null) {
      return insertStatement;
    }
    return stmt;
  }

  private PreparedStatement createAndCacheReadStatement(StatementType readType, String key)
      throws SQLException {
    String read = dbFlavor.createReadStatement(readType, key);
    PreparedStatement readStatement = getShardConnectionByKey(key).prepareStatement(read);
    PreparedStatement stmt = cachedStatements.putIfAbsent(readType, readStatement);
    if (stmt == null) {
      return readStatement;
    }
    return stmt;
  }

  private PreparedStatement createAndCacheDeleteStatement(StatementType deleteType, String key)
      throws SQLException {
    String delete = dbFlavor.createDeleteStatement(deleteType, key);
    PreparedStatement deleteStatement = getShardConnectionByKey(key).prepareStatement(delete);
    PreparedStatement stmt = cachedStatements.putIfAbsent(deleteType, deleteStatement);
    if (stmt == null) {
      return deleteStatement;
    }
    return stmt;
  }

  private PreparedStatement createAndCacheUpdateStatement(StatementType updateType, String key)
      throws SQLException {
    String update = dbFlavor.createUpdateStatement(updateType, key);
    PreparedStatement insertStatement = getShardConnectionByKey(key).prepareStatement(update);
    PreparedStatement stmt = cachedStatements.putIfAbsent(updateType, insertStatement);
    if (stmt == null) {
      return insertStatement;
    }
    return stmt;
  }

  private PreparedStatement createAndCacheScanStatement(StatementType scanType, String key)
      throws SQLException {
    String select = dbFlavor.createScanStatement(scanType, key, sqlserverScans, sqlansiScans);
    PreparedStatement scanStatement = getShardConnectionByKey(key).prepareStatement(select);
    if (this.jdbcFetchSize > 0) {
      scanStatement.setFetchSize(this.jdbcFetchSize);
    }
    PreparedStatement stmt = cachedStatements.putIfAbsent(scanType, scanStatement);
    if (stmt == null) {
      return scanStatement;
    }
    return stmt;
  }

  @Override
  public Status read(String tableName, String key, Set<String> fields, Map<String, ByteIterator> result) {
    try {
      StatementType type = new StatementType(StatementType.Type.READ, tableName, 1, "", getShardIndexByKey(key));
      PreparedStatement readStatement = cachedStatements.get(type);
      if (readStatement == null) {
        readStatement = createAndCacheReadStatement(type, key);
      }
      readStatement.setString(1, key);
      ResultSet resultSet = readStatement.executeQuery();
      if (!resultSet.next()) {
        resultSet.close();
        return Status.NOT_FOUND;
      }
      if (result != null && fields != null) {
        for (String field : fields) {
          String value = readJsonArrayValue(resultSet, field);
          if (value == null) {
            value = NULL_VALUE;
          }
          result.put(field, new StringByteIterator(value));
        }
      }
      resultSet.close();
      return Status.OK;
    } catch (SQLException e) {
      System.err.println("Error in processing read of table " + tableName + ": " + e);
      return Status.ERROR;
    }
  }

  @Override
  public Status scan(String tableName, String startKey, int recordcount, Set<String> fields,
                     Vector<HashMap<String, ByteIterator>> result) {
    try {
      StatementType type = new StatementType(StatementType.Type.SCAN, tableName, 1, "", getShardIndexByKey(startKey));
      PreparedStatement scanStatement = cachedStatements.get(type);
      if (scanStatement == null) {
        scanStatement = createAndCacheScanStatement(type, startKey);
      }
      // SQL Server TOP syntax is at first
      if (sqlserverScans) {
        scanStatement.setInt(1, recordcount);
        scanStatement.setString(2, startKey);
      // FETCH FIRST and LIMIT are at the end
      } else {
        scanStatement.setString(1, startKey);
        scanStatement.setInt(2, recordcount);
      }
      ResultSet resultSet = scanStatement.executeQuery();
      for (int i = 0; i < recordcount && resultSet.next(); i++) {
        if (result != null && fields != null) {
          HashMap<String, ByteIterator> values = new HashMap<String, ByteIterator>();
          for (String field : fields) {
            String value = readJsonArrayValue(resultSet, field);
            if (value == null) {
              value = NULL_VALUE;
            }
            values.put(field, new StringByteIterator(value));
          }
          result.add(values);
        }
      }
      resultSet.close();
      return Status.OK;
    } catch (SQLException e) {
      System.err.println("Error in processing scan of table: " + tableName + e);
      return Status.ERROR;
    }
  }

  @Override
  public Status update(String tableName, String key, Map<String, ByteIterator> values) {
    try {
      int numFields = values.size();
      OrderedFieldInfo fieldInfo = getFieldInfo(values);
      StatementType type = new StatementType(StatementType.Type.UPDATE, tableName,
          numFields, fieldInfo.getFieldKeys(), getShardIndexByKey(key));
      PreparedStatement updateStatement = cachedStatements.get(type);
      if (updateStatement == null) {
        updateStatement = createAndCacheUpdateStatement(type, key);
      }
      int index = 1;
      for (String value: fieldInfo.getFieldValues()) {
        setJsonArrayValue(updateStatement, index++, value);
      }
      updateStatement.setString(index, key);
      int result = updateStatement.executeUpdate();
      if (result == 1) {
        return Status.OK;
      }
      return Status.UNEXPECTED_STATE;
    } catch (SQLException e) {
      System.err.println("Error in processing update to table: " + tableName + e);
      return Status.ERROR;
    }
  }

  @Override
  public Status extend(String tableName, String key, Map<String, ByteIterator> values, long maxfieldlength) {
    if (values == null || values.isEmpty()) {
      return Status.BAD_REQUEST;
    }
    Map.Entry<String, ByteIterator> entry = values.entrySet().iterator().next();
    String field = entry.getKey();
    String element = entry.getValue().toString();

    try {
      if (postgresJsonAppend) {
        String sql = "UPDATE " + tableName + " SET " + field + " = COALESCE(" + field
            + ", '[]'::jsonb) || jsonb_build_array(CAST(? AS text)) WHERE " + PRIMARY_KEY + " = ?";
        try (PreparedStatement stmt = getShardConnectionByKey(key).prepareStatement(sql)) {
          stmt.setString(1, element);
          stmt.setString(2, key);
          int result = stmt.executeUpdate();
          if (result == 1) {
            return Status.OK;
          }
          return Status.UNEXPECTED_STATE;
        }
      }

      Connection conn = getShardConnectionByKey(key);
      String selectSql = "SELECT " + field + " FROM " + tableName + " WHERE " + PRIMARY_KEY + " = ?";
      try (PreparedStatement selectStmt = conn.prepareStatement(selectSql)) {
        selectStmt.setString(1, key);
        try (ResultSet resultSet = selectStmt.executeQuery()) {
          if (!resultSet.next()) {
            return Status.NOT_FOUND;
          }
          String existingJson = resultSet.getString(1);
          String nextJson = appendJsonArrayValue(existingJson, element);
          String updateSql = "UPDATE " + tableName + " SET " + field + " = ? WHERE " + PRIMARY_KEY + " = ?";
          try (PreparedStatement updateStmt = conn.prepareStatement(updateSql)) {
            setSerializedJsonValue(updateStmt, 1, nextJson);
            updateStmt.setString(2, key);
            int result = updateStmt.executeUpdate();
            if (result == 1) {
              return Status.OK;
            }
            return Status.UNEXPECTED_STATE;
          }
        }
      }
    } catch (SQLException e) {
      System.err.println("Error in processing extend to table: " + tableName + e);
      return Status.ERROR;
    }
  }

  @Override
  public Status insert(String tableName, String key, Map<String, ByteIterator> values) {
    try {
      int numFields = values.size();
      OrderedFieldInfo fieldInfo = getFieldInfo(values);
      StatementType type = new StatementType(StatementType.Type.INSERT, tableName,
          numFields, fieldInfo.getFieldKeys(), getShardIndexByKey(key));
      PreparedStatement insertStatement = cachedStatements.get(type);
      if (insertStatement == null) {
        insertStatement = createAndCacheInsertStatement(type, key);
      }
      insertStatement.setString(1, key);
      int index = 2;
      for (String value: fieldInfo.getFieldValues()) {
        setJsonArrayValue(insertStatement, index++, value);
      }
      // Using the batch insert API
      if (batchUpdates) {
        insertStatement.addBatch();
        // Check for a sane batch size
        if (batchSize > 0) {
          // Commit the batch after it grows beyond the configured size
          if (++numRowsInBatch % batchSize == 0) {
            int[] results = insertStatement.executeBatch();
            for (int r : results) {
              // Acceptable values are 1 and SUCCESS_NO_INFO (-2) from reWriteBatchedInserts=true
              if (r != 1 && r != -2) {
                return Status.ERROR;
              }
            }
            // If autoCommit is off, make sure we commit the batch
            if (!autoCommit) {
              getShardConnectionByKey(key).commit();
            }
            return Status.OK;
          } // else, the default value of -1 or a nonsense. Treat it as an infinitely large batch.
        } // else, we let the batch accumulate
        // Added element to the batch, potentially committing the batch too.
        return Status.BATCHED_OK;
      } else {
        // Normal update
        int result = insertStatement.executeUpdate();
        // If we are not autoCommit, we might have to commit now
        if (!autoCommit) {
          // Let updates be batcher locally
          if (batchSize > 0) {
            if (++numRowsInBatch % batchSize == 0) {
              // Send the batch of updates
              getShardConnectionByKey(key).commit();
            }
            // uhh
            return Status.OK;
          } else {
            // Commit each update
            getShardConnectionByKey(key).commit();
          }
        }
        if (result == 1) {
          return Status.OK;
        }
      }
      return Status.UNEXPECTED_STATE;
    } catch (SQLException e) {
      System.err.println("Error in processing insert to table: " + tableName + e);
      return Status.ERROR;
    }
  }

  @Override
  public Status delete(String tableName, String key) {
    try {
      StatementType type = new StatementType(StatementType.Type.DELETE, tableName, 1, "", getShardIndexByKey(key));
      PreparedStatement deleteStatement = cachedStatements.get(type);
      if (deleteStatement == null) {
        deleteStatement = createAndCacheDeleteStatement(type, key);
      }
      deleteStatement.setString(1, key);
      int result = deleteStatement.executeUpdate();
      if (result == 1) {
        return Status.OK;
      }
      return Status.UNEXPECTED_STATE;
    } catch (SQLException e) {
      System.err.println("Error in processing delete to table: " + tableName + e);
      return Status.ERROR;
    }
  }

  private OrderedFieldInfo getFieldInfo(Map<String, ByteIterator> values) {
    String fieldKeys = "";
    List<String> fieldValues = new ArrayList<String>();
    int count = 0;
    for (Map.Entry<String, ByteIterator> entry : values.entrySet()) {
      fieldKeys += entry.getKey();
      if (count < values.size() - 1) {
        fieldKeys += ",";
      }
      fieldValues.add(count, entry.getValue().toString());
      count++;
    }

    return new OrderedFieldInfo(fieldKeys, fieldValues);
  }

  private String[] splitArrayValue(String value) {
    if (value == null) {
      return new String[] {NULL_VALUE};
    }
    if (arrayDelimiter.isEmpty()) {
      return new String[] {value};
    }
    return value.split(arrayDelimiterRegex, -1);
  }

  private String readJsonArrayValue(ResultSet resultSet, String field) throws SQLException {
    String jsonValue = resultSet.getString(field);
    if (jsonValue == null) {
      return null;
    }
    return joinArrayValue(parseJsonArray(jsonValue));
  }

  private String joinArrayValue(List<String> values) {
    StringBuilder builder = new StringBuilder();
    for (int i = 0; i < values.size(); i++) {
      if (i > 0) {
        builder.append(arrayDelimiter);
      }
      String value = values.get(i);
      if (value == null) {
        builder.append(NULL_VALUE);
      } else {
        builder.append(value);
      }
    }
    return builder.toString();
  }

  private void setJsonArrayValue(PreparedStatement statement, int index, String logicalValue)
      throws SQLException {
    setSerializedJsonValue(statement, index, serializeJsonArray(splitArrayValue(logicalValue)));
  }

  private void setSerializedJsonValue(PreparedStatement statement, int index, String jsonValue)
      throws SQLException {
    if (postgresJsonAppend) {
      PGobject object = new PGobject();
      object.setType("jsonb");
      object.setValue(jsonValue);
      statement.setObject(index, object);
    } else {
      statement.setString(index, jsonValue);
    }
  }

  private String appendJsonArrayValue(String jsonValue, String element) throws SQLException {
    List<String> values = parseJsonArray(jsonValue);
    values.add(element);
    return serializeJsonArray(values);
  }

  private String serializeJsonArray(String[] values) {
    List<String> list = new ArrayList<String>(values.length);
    for (String value : values) {
      list.add(value);
    }
    return serializeJsonArray(list);
  }

  private String serializeJsonArray(List<String> values) {
    StringBuilder builder = new StringBuilder();
    builder.append('[');
    for (int i = 0; i < values.size(); i++) {
      if (i > 0) {
        builder.append(',');
      }
      String value = values.get(i);
      if (value == null) {
        builder.append("null");
      } else {
        appendJsonString(builder, value);
      }
    }
    builder.append(']');
    return builder.toString();
  }

  private List<String> parseJsonArray(String jsonValue) throws SQLException {
    List<String> values = new ArrayList<String>();
    if (jsonValue == null) {
      return values;
    }

    String trimmed = jsonValue.trim();
    if (trimmed.isEmpty()) {
      return values;
    }
    if (trimmed.charAt(0) != '[') {
      values.add(trimmed);
      return values;
    }

    int index = skipWhitespace(trimmed, 1);
    if (index < trimmed.length() && trimmed.charAt(index) == ']') {
      return values;
    }

    while (index < trimmed.length()) {
      index = skipWhitespace(trimmed, index);
      if (index >= trimmed.length()) {
        break;
      }
      char current = trimmed.charAt(index);
      if (current == '"') {
        StringBuilder value = new StringBuilder();
        index = parseJsonString(trimmed, index + 1, value);
        values.add(value.toString());
      } else if (trimmed.startsWith("null", index)) {
        values.add(null);
        index += 4;
      } else {
        throw new SQLException("Unsupported JSON array value: " + jsonValue);
      }

      index = skipWhitespace(trimmed, index);
      if (index >= trimmed.length()) {
        break;
      }
      current = trimmed.charAt(index);
      if (current == ',') {
        index++;
        continue;
      }
      if (current == ']') {
        return values;
      }
      throw new SQLException("Invalid JSON array value: " + jsonValue);
    }

    throw new SQLException("Unterminated JSON array value: " + jsonValue);
  }

  private int parseJsonString(String json, int index, StringBuilder value) throws SQLException {
    while (index < json.length()) {
      char current = json.charAt(index);
      if (current == '"') {
        return index + 1;
      }
      if (current == '\\') {
        if (index + 1 >= json.length()) {
          throw new SQLException("Invalid JSON escape sequence: " + json);
        }
        char escaped = json.charAt(index + 1);
        switch (escaped) {
        case '"':
        case '\\':
        case '/':
          value.append(escaped);
          index += 2;
          break;
        case 'b':
          value.append('\b');
          index += 2;
          break;
        case 'f':
          value.append('\f');
          index += 2;
          break;
        case 'n':
          value.append('\n');
          index += 2;
          break;
        case 'r':
          value.append('\r');
          index += 2;
          break;
        case 't':
          value.append('\t');
          index += 2;
          break;
        case 'u':
          if (index + 6 > json.length()) {
            throw new SQLException("Invalid JSON unicode escape: " + json);
          }
          String codePoint = json.substring(index + 2, index + 6);
          try {
            value.append((char) Integer.parseInt(codePoint, 16));
          } catch (NumberFormatException e) {
            throw new SQLException("Invalid JSON unicode escape: " + json, e);
          }
          index += 6;
          break;
        default:
          throw new SQLException("Invalid JSON escape sequence: " + json);
        }
      } else {
        value.append(current);
        index++;
      }
    }
    throw new SQLException("Unterminated JSON string: " + json);
  }

  private int skipWhitespace(String value, int index) {
    while (index < value.length() && Character.isWhitespace(value.charAt(index))) {
      index++;
    }
    return index;
  }

  private void appendJsonString(StringBuilder builder, String value) {
    builder.append('"');
    for (int i = 0; i < value.length(); i++) {
      char current = value.charAt(i);
      switch (current) {
      case '"':
        builder.append("\\\"");
        break;
      case '\\':
        builder.append("\\\\");
        break;
      case '\b':
        builder.append("\\b");
        break;
      case '\f':
        builder.append("\\f");
        break;
      case '\n':
        builder.append("\\n");
        break;
      case '\r':
        builder.append("\\r");
        break;
      case '\t':
        builder.append("\\t");
        break;
      default:
        if (current < 0x20) {
          builder.append(String.format("\\u%04x", (int) current));
        } else {
          builder.append(current);
        }
        break;
      }
    }
    builder.append('"');
  }
}
