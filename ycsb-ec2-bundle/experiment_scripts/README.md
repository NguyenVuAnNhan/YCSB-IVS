### Running Experiments with YCSB-IVS  

This directory contains Bash scripts for running workloads and experiments while varying value sizes for the following databases:  

- MariaDB + RocksDB 
- MariaDB + InnoDB
- MongoDB 

**Note:** If you need to run experiments on other databases supported by YCSB, you must create a new Bash script with configuration parameters and steps tailored to the chosen database.  

#### Configuring Experiments  

Before running an experiment, update the necessary parameters in the Bash scripts. These parameters define:  

- Database connection settings  
- Workload configuration  
- Output file paths  
- Experimental variables (e.g., value size extension, workload distributions)  

Modify the relevant sections in the script to match your experiment's requirements.

#### Database Related Configurations

Set the database connection settings, including the database name, user credentials, and JDBC connection URL. Adjust these based on the database you're using (e.g., MongoDB, MariaDB, etc.).

```bash
# Database names and configurations
DB_NAME="your_database_name"
BACKUP_DB_NAME="your_backup_database_name"
UNCHANGE_DB_NAME="your_unchanged_database_name"

# Database specific parameters

# For MariaDB on Linux (usually on port 3306)
DB_URL="jdbc:mysql://localhost:<port>/$DB_NAME"
DB_USERNAME="your_db_username"
DB_PWD="your_db_password"
BACKUP_URL="jdbc:mysql://localhost:<port>/$BACKUP_DB_NAME"
UNCHANGE_DB_URL="jdbc:mysql://localhost:<port>/$UNCHANGE_DB_NAME"

# There could be database specific parameters. e.g: JDBC properties
JDBC_PROPERTIES="jdbc-binding/conf/db.properties"

# For MongoDB on Linux
MONGOSHELL="/usr/bin/mongosh"
MONGODUMP="mongodump"
MONGORESTORE="mongorestore"

```

#### Workload and Output Configuration

Define the paths for the workload file, the output log, and the resulting data CSV files.

```bash
# Define the workload file and the log file
WORKLOAD_FILE="path/to/your/workload_file"
LOG_FILE="path/to/output/log_file"
OUTPUT_CSV="path/to/output/csv_file"

# Define input and output filenames for workload results
INPUT_FILE="path/to/input/csv_file"
OUTPUT_FILE="path/to/output/csv_file"
```

#### Key Size Gathering Configuration

We use the distribution of value sizes in the database as an input for running the workload. There must be a file to keep the histogram data. For the purpose of  analysing whether the value size distribution is preserved during the run phase, we record the value size of each key (in bytes) before and after the extend phase. Therefore, we configure the filenames for the key size logs and corresponding value size distribution files.

```bash
# Key size gathering settings
KEY_SIZE_LOG="path/to/key_size_log.csv"
KEY_SIZE_FILE_AFTER_EXTEND="path/to/value_size_distribution_after_extend_phase.csv"
KEY_SIZE_FILE_AFTER_RUN="path/to/value_size_distribution_after_run_phase.csv"
HISTOGRAM_FILE="histogram.txt"
```

#### Experiment Phase Parameters

The experiment typically has two phases: the **value extension phase** and the  **workload-run phase** . Set the following parameters to control the distribution of operations in each phase, including the read, write, update, scan, and insert proportions.

##### Value Extension Phase:

```bash
# Define the proportions for the value extension phase
extendproportion_extend="1"            # Set the proportion for value extension (0-1)
readproportion_extend="0"              # Proportion of read operations
updateproportion_extend="0"            # Proportion of update operations
scanproportion_extend="0"              # Proportion of scan operations
insertproportion_extend="0"            # Proportion of insert operations
readmodifywriteproportion_extend="0"   # Proportion of read-modify-write operations
requestdistribution_extend="uniform"   # Request distribution type
```

##### Workload-run Phase:

```bash
# Define the proportions for the post-extension phase (operations after extension phase)
extendproportion_postextend="0"              # Set the proportion for value extension
readproportion_postextend="1"                # Proportion of read operations
updateproportion_postextend="0"              # Proportion of update operations
scanproportion_postextend="0"                # Proportion of scan operations
insertproportion_postextend="0"              # Proportion of insert operations
readmodifywriteproportion_postextend="0"     # Proportion of read-modify-write operations
requestdistribution_postextend="uniform"     # Request distribution
```

#### Experiment Specific Parameters

Adjust other experiment-specific parameters like the original field length and the number of operations to be performed during the experiment.

```bash
# Experiment-specific parameters
fieldlengthoriginal="100"          # Original field length (in bytes)
extendoperationcount="10000"       # Number of operations for the extension phase
```

### How to Modify Parameters

1. **Open the Script** : Open the bash script corresponding to the workload you wish to run (e.g., `experiment_mongodb.sh`, `experiment_innodb.sh`, etc.).
2. **Start Database Instances** : Databases have their own ways of starting, restarting, and stopping procedures. For instance, we must initiate two instances of the database at two distinct ports for `MongoDB` to make primary and dump and load databases available. e.g: 
      ```bash
         sudo mongod --config /etc/mongod.conf &         # Start first instance on default 27017 port
         sudo mongod --config /etc/mongod_28018.conf &   # Start second instance on 28018
      ```
3. **Edit the Parameters** : Adjust the parameters in the sections above to match your experimental setup (database type, workload distribution, file paths, etc.).
4. **Save the Script** : After making the necessary changes, save the script and close the editor.
5. **Run the Experiment** : Execute the script using the following command:

```bash
   ./experiment_scripts/experiment_mongodb.sh
```

   (Replace `experiment_mongodb.sh` with the appropriate script for your database and workload type.)

1. **View Output**

   It is recommended to specify `OUTPUT_FILE`, `KEY_SIZE_FILE_AFTER_EXTEND`, and `KEY_SIZE_FILE_AFTER_RUN` parameter values such that outputs are saved at `../analysis/Data` directory.
   If so, the experiment results will be saved in the `../analysis/Data` directory, with CSV files containing the collected data for further analysis.

### Analysis

The output from the experiments will be stored in the `../analysis/Data` folder. You can refer to the `README.md` at `../analysis` directory for details on how to analyze the results, including steps for processing the CSV data and generating figures.

---

This setup provides an easy way to benchmark databases under varying conditions and helps with understanding how databases behave as value sizes increase over time. The scripts can be customized further to fit specific workloads or database configurations.
