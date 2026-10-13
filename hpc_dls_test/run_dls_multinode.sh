#!/usr/bin/env bash
set -euo pipefail

PROGRAM="${1:-./gauss_seidel}"
MAX_ITERS="${2:-5000}"
TOL="${3:-1e-8}"
read -r -a DIMS <<< "${DLS_DIMS:-128 256 512 1024 2048}"
RUN_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="dls_${RUN_TIMESTAMP}"
LOG_FILE="dls_${RUN_TIMESTAMP}.log"

exec > >(tee -a "$LOG_FILE") 2>&1
printf 'Log file: %s\n' "$LOG_FILE"

: "${SLURM_JOB_ID:?Run this script from a Slurm allocation}"
[[ -x "$PROGRAM" ]] || { printf 'Program is not executable: %s\n' "$PROGRAM" >&2; exit 1; }
(( ${#DIMS[@]} > 0 )) || { printf 'No matrix dimensions specified\n' >&2; exit 1; }

allocation=$(squeue -h -j "$SLURM_JOB_ID" -o '%N')
[[ -n "$allocation" ]] || { printf 'No nodes found for Slurm job %s\n' "$SLURM_JOB_ID" >&2; exit 1; }
mapfile -t HOSTS < <(scontrol show hostnames "$allocation")
(( ${#HOSTS[@]} >= 2 )) || { printf 'At least two allocated nodes are required\n' >&2; exit 1; }
HOSTLIST=$(IFS=,; printf '%s' "${HOSTS[*]}")
NODE_COUNT=${#HOSTS[@]}

mkdir "$RESULT_DIR"
printf 'Results directory: %s\n' "$RESULT_DIR"
{
    printf 'program=%s\n' "$PROGRAM"
    printf 'slurm_job_id=%s\n' "$SLURM_JOB_ID"
    printf 'hosts=%s\n' "$HOSTLIST"
    printf 'nodes=%s\n' "$NODE_COUNT"
    printf 'max_iters=%s\n' "$MAX_ITERS"
    printf 'tolerance=%s\n' "$TOL"
    printf 'dimensions=%s\n' "${DIMS[*]}"
} > "$RESULT_DIR/run_info.txt"

printf 'MPI hosts: %s\n' "$HOSTLIST" >&2
printf 'nodes,n,max_iters,tol,time_ms,iterations,final_residual,error\n' | tee "$RESULT_DIR/summary.csv"

done_re='Done in ([0-9]+) iterations, time = ([0-9]+([.][0-9]+)?) ms'
residual_re='final \|\|r\|\| = ([0-9.eE+-]+)'
error_re='\|\|x - x\*\|\|_2 = ([0-9.eE+-]+)'

for n in "${DIMS[@]}"; do
    if output=$(srun --jobid "$SLURM_JOB_ID" --mpi=pmix_v4 \
        --nodes "$NODE_COUNT" --ntasks "$NODE_COUNT" --ntasks-per-node=1 \
        --nodelist "$HOSTLIST" \
        bash -lc 'set -euo pipefail
            module add compiler/dtk/26.04
            module add mpi/openmpi/5.0.3/gcc-8.5.0/shca
            exec "$@"' bash "$PROGRAM" "$n" "$MAX_ITERS" "$TOL" 2>&1); then
        :
    else
        status=$?
        printf '%s\n' "$output" > "$RESULT_DIR/n_${n}.log"
        printf 'Run failed for n=%s on %s (exit %s):\n%s\n' "$n" "$HOSTLIST" "$status" "$output" >&2
        exit "$status"
    fi
    printf '%s\n' "$output"
    printf '%s\n' "$output" > "$RESULT_DIR/n_${n}.log"

    if [[ $output =~ $done_re ]]; then
        iterations=${BASH_REMATCH[1]}
        time_ms=${BASH_REMATCH[2]}
    else
        printf 'Missing timing for n=%s:\n%s\n' "$n" "$output" >&2
        exit 1
    fi
    if [[ $output =~ $residual_re ]]; then
        final_residual=${BASH_REMATCH[1]}
    else
        printf 'Missing residual for n=%s:\n%s\n' "$n" "$output" >&2
        exit 1
    fi
    if [[ $output =~ $error_re ]]; then
        error=${BASH_REMATCH[1]}
    else
        printf 'Missing solution error for n=%s:\n%s\n' "$n" "$output" >&2
        exit 1
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$NODE_COUNT" "$n" "$MAX_ITERS" "$TOL" \
        "$time_ms" "$iterations" "$final_residual" "$error" \
        | tee -a "$RESULT_DIR/summary.csv"
done
