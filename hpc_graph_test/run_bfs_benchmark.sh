#!/bin/bash
#SBATCH -J bfs_benchmark
#SBATCH -p gpu_partition_name    # 替换为实际的GPU分区名
#SBATCH --gres=gpu:1             # 申请1个GPU
#SBATCH -N 1                     # 1个节点
#SBATCH -n 4                     # 4个MPI进程
#SBATCH -t 01:00:00              # 运行时间

module purge
module load compiler/dtk/26.04
module load compiler/gcc/9.3.0
module load mpi/openmpi/openmpi-4.1.5-gcc9.3.0

# 运行BFS
mpirun ./bfs 1000 5 0
