#!/bin/bash
#SBATCH -J bfs_benchmark
#SBATCH -p hx1hdnormal    # 替换为实际的GPU分区名
#SBATCH --gres=dcu:1             # 申请1个GPU
#SBATCH -N 2                     # 1个节点
#SBATCH -n 4                     # 4个MPI进程
#SBATCH -t 01:00:00              # 运行时间

LOG_FILE="bfs_result_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
printf 'Log file: %s\n' "$LOG_FILE"

module purge
module load compiler/dtk/26.04
module load compiler/gcc/9.3.0
module load mpi/openmpi/openmpi-4.1.5-gcc9.3.0

# 运行BFS
mpirun ./bfs 1000 5 0
