#!/usr/bin/env bash
# Gauss-Seidel benchmark script
# Runs the MPI Gauss-Seidel program with varying matrix dimensions and node counts.
# Outputs CSV-formatted performance data to stdout.

set -euo pipefail

PROG="${1:-./gauss_seidel}"
MAX_ITERS="${2:-5000}"
TOL="${3:-1e-8}"

# Node counts to test
NODE_COUNTS=(1)
#NODE_COUNTS=(1 2 4)
# Matrix dimensions to test
DIMS=(128 256 512 1024 2048)

echo "nodes,n,max_iters,tol,time_ms,iterations,final_residual,error"

for nodes in "${NODE_COUNTS[@]}"; do
    for n in "${DIMS[@]}"; do
        # Run and capture output
        output=$(mpirun -np "${nodes}" "${PROG}" "${n}" "${MAX_ITERS}" "${TOL}" 2>/dev/null || true)

        # Extract metrics from output
        time_ms=$(echo "${output}" | grep -oE 'time = [0-9]+\.[0-9]+' | awk '{print $3}' || echo "")
        iterations=$(echo "${output}" | grep -oE 'Done in [0-9]+' | awk '{print $3}' || echo "")
        final_res=$(echo "${output}" | grep -oE 'final \|\|r\|\| = [0-9.e+-]+' | awk '{print $4}' || echo "")
        error=$(echo "${output}" | grep -oE '\|\|x - x\*\|\|_2 = [0-9.e+-]+' | awk '{print $4}' || echo "")

        if [[ -n "${time_ms}" ]]; then
            echo "${nodes},${n},${MAX_ITERS},${TOL},${time_ms},${iterations},${final_res},${error}"
        else
            echo "${nodes},${n},${MAX_ITERS},${TOL},NA,NA,NA,NA"
        fi
    done
done
