<!--
Copyright (c) 2010 Yahoo! Inc., 2012 - 2016 YCSB contributors.
All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License"); you
may not use this file except in compliance with the License. You
may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
implied. See the License for the specific language governing
permissions and limitations under the License. See accompanying
LICENSE file.
-->
# YCSB-IVS: Benchmarking Databases with Varying Value Sizes  

YCSB-IVS introduces a novel benchmarking technique to evaluate database performance as value sizes vary over time. This enhancement builds on the original YCSB framework, enabling experiments with dynamic value size growth and providing new insights into database behavior under evolving workloads.  

## Overview  

Our benchmarking approach evaluates three widely-used databases:  
- **MongoDB**  
- **MariaDB + InnoDB**  
- **MariaDB + RocksDB**
- **PostgreSQL**

### Key Features  
- Analysis of database performance under dynamic value size variations.  
- Comparison of latency, throughput, and scalability across different database systems.  
- Comprehensive scripts and figures for replicating our analysis.  

## Analysis Data  

All output files generated during experiments are stored in the `./analysis/Data` directory. These files are prepared for analysis and visualization.  

To understand the analysis process and view results, refer to the [README.md](./analysis/README.md) within the `./analysis` directory. This document provides step-by-step details on our analysis methodology and generates outputs included in our publication.  

## Analysis Workflow  

The R Jupyter notebook located in the **`./analysis/Scripts`** folder includes:  
- Step-by-step explanations of our analysis process.  
- Intermediate results and final output figures.  

## How to Use This Repository  

1. **Clone the repository and build with Maven**

2. **Explore the data**:  
   Navigate to the `./analysis/Data` directory to view raw data files.  

3. **Run the analysis**:  
   Run the Python script `./analysis_scripts/experiment-analysis.py` to reproduce the analysis and figures.  

4. **View results**:  
   Output figures are stored in the `./analysis/Figures` directory.  

---  

YCSB-IVS expands the capabilities of the original YCSB framework to simulate realistic scenarios of value size growth, offering a powerful tool for evaluating database scalability and performance.
