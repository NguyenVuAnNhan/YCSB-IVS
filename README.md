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

YCSB-IVS introduces a novel benchmarking technique to evaluate database performance as value sizes vary over time. These enhancements build on the original YCSB framework, enabling experiments with dynamic value size growth and providing new insights into database behavior under evolving workloads.  

## Overview  

YCSB-IVS has been used to evaluate many widely-used databases:  
- **MongoDB**  
- **MariaDB + InnoDB**  
- **MariaDB + RocksDB**
- **PostgreSQL**

### Key Features  
- Analysis of database performance under dynamic value size variations.  
- Comparison of latency, throughput, and scalability across different database systems.  
- Comprehensive scripts and figures for replicating our analysis.  

## Getting started

Refer to [ycsb-ec2-bundle/README.md](ycsb-ec2-bundle/README.md) and [ycsb-ec2-bundle/experiment_scripts/README.md](ycsb-ec2-bundle/experiment_scripts/README.md) for details of how to build the code and run the experiments, respectively.

For details on running YCSB (the core tool behind YCSB-IVS), refer to the installation and build guide:  
[Official YCSB README](https://github.com/brianfrankcooper/YCSB/blob/master/README.md)  

The rest of this document outlines the additions made on top of the original YCSB version as of **18 Oct 2026**, specifically for YCSB-IVS experiments.

## Repository Structure (under `ycsb-ec2-bundle`) 

| Directory                  | Description                                                                        |
|----------------------------|------------------------------------------------------------------------------------|
| **`./experiment_scripts`** | Bash scripts for running workload experiments.                                     |
| **`./analysis/Data`**      | Output data files relevant for analysis that are generated from our experiments by running bash scripts in `./experiment_scripts`. Refer to `./analysis/README.md`. |
| **`./analysis/Scripts`**   | Analysis scripts written in R (Jupyter notebooks).                                 |
| **`./analysis/Figures`**   | Generated output figures and visualizations referenced in our paper.               |  

## Experimental Scripts 

The `./experiment_scripts` directory contains all the necessary bash scripts for running workload experiments and saving the results as CSV files.  

#### Examples:  
- **MongoDB Workload**:  
  Run `./experiment_scripts/experiment.sh mongodb` to execute the benchmarking workloads in MongoDB with varying value sizes.  
- **MongoDB Baseline**:  
  Run `./experiment_scripts/experiment.sh mongodb --mode baseline` for baseline executions with fixed value sizes — the same load/extend/measure phases without the reference and comparison databases. 

Please refer to the general instructions on configuring experiments in the README file at `./experiment_scripts/README.md`. 

## Analysis Data  

All output files generated during experiments are stored in the `./analysis/Data` directory. These files are prepared for analysis and visualization.  

To understand the analysis process and view results, refer to the [README.md](./analysis/README.md) within the `./analysis` directory.
