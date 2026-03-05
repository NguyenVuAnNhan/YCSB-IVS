# PostgreSQL Array Operations Logic

This document explains how `INSERT`, `READ`, `UPDATE`, and `EXTEND` work in the PostgreSQL array experiment run by:

- `experiment_scripts/experiment_postgresql_array.sh`
- YCSB workload file `workloads/workloada-extend`
- JDBC array binding implementation in `jdbc-array/src/main/java/site/ycsb/db/JdbcDBClient.java`

## 1) Data model used by this experiment

The script creates:

- database(s): `ycsb`, `ycsb_unchange`, and temporary `ycsb_backup`
- table: `usertable`
- schema:
  - `ycsb_key TEXT PRIMARY KEY`
  - `field0 ... field9` as `TEXT[]`

Each logical YCSB record has 10 fields, and each field is stored as a PostgreSQL text array.

## 2) How operation type is selected

YCSB operation mix is controlled by workload properties:

- `readproportion`
- `updateproportion`
- `insertproportion`
- `scanproportion`
- `extendproportion`
- `readmodifywriteproportion`

The script rewrites these properties in `workloada-extend` before each phase.

Typical flow in this script:

1. **Load phase**: initial data load.
2. **Extend phase**: mostly/all `EXTEND`.
3. **Run phase**: post-extend mix (currently configured as read-heavy).
4. **Reference/clean/avg-run phases**: comparison runs.

## 3) INSERT logic

### In workload

`INSERT` is used during YCSB load and any run phase where `insertproportion > 0`.

### In JDBC array binding

`JdbcDBClient.insert(...)`:

1. Builds field list and values from the YCSB map.
2. Converts each field value string into JDBC array:
   - `createJdbcArray(...)`
   - internally uses `splitArrayValue(...)` and `Connection.createArrayOf(...)`.
3. Executes `INSERT INTO usertable (YCSB_KEY, field0..field9) VALUES (?, ?, ... ?)` via prepared statement.

Result:

- one row per YCSB key
- each field column stores an array value (`TEXT[]`).

## 4) READ logic

### In workload

`READ` operations happen when `readproportion > 0`.

### In JDBC array binding

`JdbcDBClient.read(...)`:

1. Executes prepared SQL:
   - `SELECT * FROM usertable WHERE YCSB_KEY = ?`
2. For requested fields, fetches PostgreSQL arrays with `ResultSet.getArray(...)`.
3. Converts array back to string representation using `joinArrayValue(...)`.

Result:

- reads one key at a time by primary key lookup
- returns string form to YCSB measurement layer.

## 5) UPDATE logic

### In workload

`UPDATE` operations happen when `updateproportion > 0`.

### In JDBC array binding

`JdbcDBClient.update(...)`:

1. Receives one or more fields to update.
2. Converts provided values to JDBC arrays.
3. Executes prepared SQL:
   - `UPDATE usertable SET fieldX=?, fieldY=?, ... WHERE YCSB_KEY=?`

Important behavior:

- This is a **replace update** for selected field columns (not append).
- Updated fields get new `TEXT[]` values for that operation.

## 6) EXTEND logic (key feature of this experiment)

### In workload

`CoreWorkload.doTransactionExtend(...)`:

1. Picks a key.
2. Picks one random target field (single-field extend).
3. Generates extend payload using `extendfieldlength` settings.
4. Calls `db.extend(table, key, values, maxfieldlength)`.

### In JDBC array binding

`JdbcDBClient.extend(...)` has PostgreSQL-specific behavior:

- For PostgreSQL URLs, uses:
  - `UPDATE ... SET field = array_append(field, ?) WHERE YCSB_KEY = ?`

So each EXTEND operation appends one new element to one field array.

For non-PostgreSQL paths, it falls back to read-modify-write array logic, but this experiment uses the PostgreSQL `array_append` path.

Result:

- value sizes grow over time per key and per field
- this growth is what the script measures via `octet_length(array_to_string(...))`.

## 7) How the script measures effects of these operations

After phases, the script collects:

- YCSB operation metrics (`[READ]`, `[UPDATE]`, `[EXTEND]`, `[OVERALL]`)
- PostgreSQL stats from `pg_stat_database`, `pg_stat_bgwriter`, `pg_stat_wal`
- Value-size data from SQL sums of 10 fields:
  - `octet_length(array_to_string(fieldN, ''))`

Outputs include:

- `analysis/Data/Workload_data/postgresql_array_run1_uniform_heavy_mixed.csv`
- `analysis/Data/Value_size_data/...before_mixed.csv`
- `analysis/Data/Value_size_data/...after_mixed.csv`
- `experiment_scripts/postgresql_array_query_plan.log`

## 8) Practical notes

- The script mutates `workloads/workloada-extend` in-place during execution.
- `EXTEND` is append semantics, while `UPDATE` is replace semantics.
- If delimiter-sensitive random payload is used, measured size can differ from nominal configured field length.

