#!/bin/bash

# autoomb.sh
# Comprehensive OSU Micro-Benchmarks testing script for InfiniBand with Enhanced Collective Testing

# ====== Configuration Parameters ======
# Node Configuration
NODE1="e07r4n07"
NODE2="e07r4n08"
ALL_NODES="$NODE1,$NODE2"

# OSU Path and Test Configuration
#OSU_PATH="/root/osu/libexec/osu-micro-benchmarks/mpi"
OSU_PATH="/home/qi/hpcbench/hpc_network_test/OMB/c/mpi"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="osu_results_${TIMESTAMP}"

# Module Configuration (from osu_collective_test.sh)
USE_MODULES=true  # Set to false to disable module loading
MODULE_PURGE_CMD="module purge"
MODULE_LOAD_CMDS=(
    #"module load compiler/dtk/25.04"
#"module load mpi/openmpi/5.0.3/gcc-8.5.0/shca_ucx-1.15.0"
    "module load mpi/openmpi/openmpi-4.1.5-gcc9.3.0"
    #"module load mpi/ucx/1.18.0/dtk-25.04/shca"
)

# Hostfile Configuration
HOSTFILE_PATH="hostfile"
USE_HOSTFILE=true  # Set to false to use --host instead

# Slurm launcher: auto = use Slurm plm when inside a multi-node job (recommended)
USE_SLURM_LAUNCHER=auto   # auto | yes | no
MIN_SLURM_NODES=2
USE_SLURM_LAUNCHER_ACTIVE=false
MPI_LAUNCH_MODE="mpirun"  # srun | mpirun_slurm | mpirun_ssh
SLURM_MPI_PARAMS=""
SRUN_MPI_TYPE="${SRUN_MPI_TYPE:-pmix}"
export SLURM_MPI_TYPE=pmix

# MPI Configuration
MCA_PARAMS="--mca btl ^tcp --mca pml ucx --mca osc ucx"
UCX_PARAMS="-x UCX_NET_DEVICES=shca_0:1 -x UCX_TLS=rc,mm,rocm -x UCX_MEMTYPE_CACHE=no"
HIP_PARAMS="-x HIP_VISIBLE_DEVICES=0,1,2,3,4,5,6,7"
TEST_PARAMS="-x TEST_SYSTEM_PARAMS=0"
DEBUG_PARAMS="--mca btl_base_verbose 30 --display-map --report-bindings"
MAPPING_PARAMS="--map-by node:OVERSUBSCRIBE --bind-to none"
ENV_PARAMS=""
COMMON_PARAMS="--allow-run-as-root $MCA_PARAMS $UCX_PARAMS $HIP_PARAMS $TEST_PARAMS"

# Test Configuration
PROCS_PER_NODE=(1 2 4 8 16)  # Process counts per node
MESSAGE_SIZES=(1 1024 65536 1048576 4194304 16777216)  # Message sizes in bytes
TEST_ITERATIONS=1000  # Number of iterations for each test
WARMUP_ITERATIONS=100  # Number of warmup iterations


# Color Configuration for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Logging Configuration
LOG_LEVEL=2  # 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG
LOG_FILE="$RESULT_DIR/test.log"

# Test Timeouts (in seconds)
P2P_TIMEOUT=300
COLLECTIVE_TIMEOUT=600
ONE_SIDED_TIMEOUT=300
STARTUP_TIMEOUT=60

# Create result directory
mkdir -p $RESULT_DIR

# ====== Module Management Functions ======
load_modules() {
    if [ "$USE_MODULES" = true ]; then
        log "INFO" "Loading required modules..."
        
        # Execute module purge
        if command -v module >/dev/null 2>&1; then
            eval "$MODULE_PURGE_CMD" 2>/dev/null || log "WARN" "Module purge failed or not available"
            
            # Load each module
            for module_cmd in "${MODULE_LOAD_CMDS[@]}"; do
                log "DEBUG" "Executing: $module_cmd"
                eval "$module_cmd" 2>/dev/null || log "WARN" "Failed to load: $module_cmd"
            done
            
            log "SUCCESS" "Modules loaded successfully"
            refresh_mpi_env_params
        else
            log "WARN" "Module command not available, skipping module loading"
        fi
    else
        log "INFO" "Module loading disabled"
        refresh_mpi_env_params
    fi
}

# Build mpirun -x flags so all ranks inherit module-provided library paths
refresh_mpi_env_params() {
    ENV_PARAMS=""
    local var
    for var in PATH LD_LIBRARY_PATH LIBRARY_PATH MODULEPATH \
               UCX_NET_DEVICES UCX_TLS UCX_MEMTYPE_CACHE HIP_VISIBLE_DEVICES TEST_SYSTEM_PARAMS; do
        if [ -n "${!var:-}" ]; then
            ENV_PARAMS="$ENV_PARAMS -x $var"
        fi
    done
    COMMON_PARAMS="--allow-run-as-root $ENV_PARAMS $SLURM_MPI_PARAMS $MCA_PARAMS $UCX_PARAMS $HIP_PARAMS $TEST_PARAMS"
    log "DEBUG" "MPI env params:$ENV_PARAMS"
    log "DEBUG" "Slurm MPI params:$SLURM_MPI_PARAMS"
}

# Export UCX/HIP variables into the current shell (needed for Slurm/srun paths)
export_runtime_env() {
    export UCX_NET_DEVICES=${UCX_NET_DEVICES:-shca_0:1}
    export UCX_TLS=${UCX_TLS:-rc,mm,rocm}
    export UCX_MEMTYPE_CACHE=${UCX_MEMTYPE_CACHE:-no}
    export HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7}
    export TEST_SYSTEM_PARAMS=${TEST_SYSTEM_PARAMS:-0}
    # OpenMPI MCA via environment (required when using srun launcher)
    export OMPI_MCA_btl='^tcp'
    export OMPI_MCA_pml='ucx'
    export OMPI_MCA_osc='ucx'
}

ompi_has_slurm_plm() {
    command -v ompi_info >/dev/null 2>&1 || return 1
    ompi_info 2>/dev/null | grep -q 'MCA plm: slurm'
}

select_mpi_launch_mode() {
    if [ "$USE_SLURM_LAUNCHER_ACTIVE" != true ]; then
        MPI_LAUNCH_MODE="mpirun_ssh"
        SLURM_MPI_PARAMS=""
        return
    fi

    # srun is the most reliable launcher inside a Slurm allocation
    if command -v srun >/dev/null 2>&1 && [ -n "${SLURM_JOB_ID:-}" ]; then
        MPI_LAUNCH_MODE="srun"
        SLURM_MPI_PARAMS=""
        log "INFO" "MPI launcher: srun (inside Slurm job $SLURM_JOB_ID)"
        return
    fi

    if ompi_has_slurm_plm; then
        MPI_LAUNCH_MODE="mpirun_slurm"
        SLURM_MPI_PARAMS="--mca plm slurm --mca ras slurm"
        log "INFO" "MPI launcher: mpirun with Slurm PLM"
        return
    fi

    MPI_LAUNCH_MODE="mpirun_ssh"
    SLURM_MPI_PARAMS=""
    log "WARN" "Falling back to mpirun SSH/hostfile launcher"
}

is_login_node() {
    local host_short
    host_short=$(hostname -s 2>/dev/null || hostname)
    [[ "$host_short" == *login* ]]
}

# Prefer Slurm plm inside a multi-node allocation; block login-node SSH launches
detect_slurm_launcher() {
    local mode=${USE_SLURM_LAUNCHER:-auto}
    USE_SLURM_LAUNCHER_ACTIVE=false
    SLURM_MPI_PARAMS=""

    case "$mode" in
        false|no|0)
            if is_login_node; then
                log "ERROR" "Login node detected ($(hostname)). Cross-node MPI requires a Slurm allocation."
                log "ERROR" "Run: salloc -N 2 -n 2 -t 02:00:00 -p <partition>"
                return 1
            fi
            return 0
            ;;
        true|yes|1)
            if [ -z "${SLURM_JOB_ID:-}" ] || [ "${SLURM_NNODES:-0}" -lt "$MIN_SLURM_NODES" ]; then
                log "ERROR" "Slurm launcher enabled but no multi-node job is active."
                log "ERROR" "SLURM_JOB_ID=${SLURM_JOB_ID:-unset} SLURM_NNODES=${SLURM_NNODES:-unset}"
                log "ERROR" "Run: salloc -N 2 -n 2 -t 02:00:00 -p <partition>"
                return 1
            fi
            USE_SLURM_LAUNCHER_ACTIVE=true
            ;;
        auto|*)
            if [ -n "${SLURM_JOB_ID:-}" ] && [ "${SLURM_NNODES:-0}" -ge "$MIN_SLURM_NODES" ]; then
                USE_SLURM_LAUNCHER_ACTIVE=true
                log "INFO" "Slurm job active: JOB_ID=$SLURM_JOB_ID NODES=$SLURM_NNODES NODELIST=$SLURM_NODELIST"
            elif is_login_node; then
                log "ERROR" "Cannot launch cross-node MPI from login node ($(hostname))."
                log "ERROR" "Slurm blocks SSH to compute nodes without an active job (pam_slurm_adopt)."
                log "ERROR" "Allocate nodes first: salloc -N 2 -n 2 -t 02:00:00 -p <partition>"
                return 1
            else
                log "ERROR" "On compute node $(hostname) but no ${MIN_SLURM_NODES}-node Slurm job is active."
                log "ERROR" "SLURM_JOB_ID=${SLURM_JOB_ID:-unset} SLURM_NNODES=${SLURM_NNODES:-unset} SLURM_NODELIST=${SLURM_NODELIST:-unset}"
                log "ERROR" "Being on a compute node is not enough: mpirun --hostfile launches via SSH and needs a multi-node allocation."
                log "ERROR" "Do NOT ssh to one compute node manually. From login node run:"
                log "ERROR" "  salloc -N 2 -n 2 -t 02:00:00 -p <partition>"
                log "ERROR" "Then run network_test.sh inside that shell."
                return 1
            fi
            ;;
    esac

    if [ "$USE_SLURM_LAUNCHER_ACTIVE" = true ]; then
        select_mpi_launch_mode
    else
        MPI_LAUNCH_MODE="mpirun_ssh"
        SLURM_MPI_PARAMS=""
    fi
    export_runtime_env
    refresh_mpi_env_params
    return 0
}

# Verify shared libraries required by OSU binaries are reachable
verify_osu_library_deps() {
    local test_path=$1
    local missing

    if ! command -v ldd >/dev/null 2>&1; then
        return 0
    fi

    missing=$(ldd "$test_path" 2>/dev/null | awk '/not found/ {print $1}' | tr '\n' ' ')
    if [ -n "$missing" ]; then
        log "ERROR" "Missing shared libraries for $test_path: $missing"
        log "ERROR" "Current LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
        log "ERROR" "Ensure DTK/HIP modules are loaded and passed via mpirun -x LD_LIBRARY_PATH"
        return 1
    fi

    local mpi_dir="" lib_path lib_dir
    while IFS= read -r lib_path; do
        [ -n "$lib_path" ] || continue
        lib_dir=$(dirname "$lib_path")
        if [ -z "$mpi_dir" ]; then
            mpi_dir="$lib_dir"
        elif [ "$lib_dir" != "$mpi_dir" ]; then
            log "ERROR" "Mixed OpenMPI runtime libraries detected for $test_path:"
            log "ERROR" "  first: $mpi_dir"
            log "ERROR" "  next:  $lib_dir"
            log "ERROR" "Purge modules and load only one OpenMPI module on all nodes"
            return 1
        fi
    done < <(ldd "$test_path" 2>/dev/null | awk '/libmpi\.so|libopen-rte\.so|libopen-pal\.so/ {print $3}')
    return 0
}

# ====== Hostfile Management Functions ======
create_hostfile() {
    if [ "$USE_SLURM_LAUNCHER_ACTIVE" = true ]; then
        log "INFO" "Recording Slurm allocated nodes..."
        if command -v scontrol >/dev/null 2>&1 && [ -n "${SLURM_NODELIST:-}" ]; then
            scontrol show hostnames "$SLURM_NODELIST" > "$HOSTFILE_PATH"
            NODE1=$(sed -n '1p' "$HOSTFILE_PATH")
            NODE2=$(sed -n '2p' "$HOSTFILE_PATH")
            log "INFO" "Allocated nodes: $(tr '\n' ' ' < "$HOSTFILE_PATH")"
        fi
        return
    fi

    if [ "$USE_HOSTFILE" = true ]; then
        log "INFO" "Creating hostfile..."
        cat > "$HOSTFILE_PATH" << EOF
$NODE1
$NODE2
EOF
        log "SUCCESS" "Hostfile created: $HOSTFILE_PATH"
    fi
}

get_host_params() {
    local total_procs=$1
    if [ "$USE_SLURM_LAUNCHER_ACTIVE" = true ]; then
        local nnodes=${SLURM_NNODES:-2}
        local ppr=$((total_procs / nnodes))
        [ "$ppr" -lt 1 ] && ppr=1
        echo "--map-by ppr:${ppr}:node --bind-to none"
        return
    fi
    if [ "$USE_HOSTFILE" = true ] && [ -f "$HOSTFILE_PATH" ]; then
        echo "--hostfile $HOSTFILE_PATH $MAPPING_PARAMS"
    else
        local ppn=$((total_procs / 2))
        [ "$ppn" -lt 1 ] && ppn=1
        echo "--host $NODE1,$NODE2:$ppn $MAPPING_PARAMS"
    fi
}

# ====== Logging Functions ======
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        ERROR)   [[ $LOG_LEVEL -ge 0 ]] && echo -e "${RED}[ERROR] [$timestamp] $message${NC}" | tee -a $LOG_FILE ;;
        WARN)    [[ $LOG_LEVEL -ge 1 ]] && echo -e "${YELLOW}[WARN]  [$timestamp] $message${NC}" | tee -a $LOG_FILE ;;
        INFO)    [[ $LOG_LEVEL -ge 2 ]] && echo -e "[INFO]  [$timestamp] $message" | tee -a $LOG_FILE ;;
        DEBUG)   [[ $LOG_LEVEL -ge 3 ]] && echo -e "[DEBUG] [$timestamp] $message" | tee -a $LOG_FILE ;;
        SUCCESS) echo -e "${GREEN}[✓] [$timestamp] $message${NC}" | tee -a $LOG_FILE ;;
        FAILURE) echo -e "${RED}[✗] [$timestamp] $message${NC}" | tee -a $LOG_FILE ;;
    esac
}

# ====== Helper Functions ======
check_executable() {
    local exec_path=$1
    if [ ! -f "$exec_path" ]; then
        log "ERROR" "Executable not found: $exec_path"
        return 1
    elif [ ! -x "$exec_path" ]; then
        log "ERROR" "Executable not executable: $exec_path"
        return 1
    fi
    return 0
}

check_node_connectivity() {
    local node=$1
    if ! ping -c 1 -W 2 $node >/dev/null 2>&1; then
        log "ERROR" "Cannot ping node $node"
        return 1
    fi
    return 0
}

get_srun_params() {
    local nprocs=$1
    local nodes=${SLURM_NNODES:-2}
    [ "$nodes" -lt 1 ] && nodes=1
    [ "$nodes" -gt "$nprocs" ] && nodes=$nprocs
    local ppn=$(( (nprocs + nodes - 1) / nodes ))
    [ "$ppn" -lt 1 ] && ppn=1
    echo "--mpi=${SRUN_MPI_TYPE} -N ${nodes} -n ${nprocs} --ntasks-per-node=${ppn} --export=ALL"
}

build_mpi_launch_command() {
    local np=$1
    local extra_params=$2
    local test_path=$3
    local app_params=$4

    case "$MPI_LAUNCH_MODE" in
        srun)
            echo "srun $(get_srun_params "$np") $test_path $app_params"
            ;;
        *)
            echo "mpirun $COMMON_PARAMS -np $np $extra_params $test_path $app_params"
            ;;
    esac
}

get_process_distribution() {
    local total_procs=$1
    if [ "$MPI_LAUNCH_MODE" = "srun" ]; then
        echo ""
        return
    fi
    echo "$(get_host_params $total_procs)"
}

format_size() {
    local size=$1
    if [ $size -ge 1048576 ]; then
        echo "$((size / 1048576))MB"
    elif [ $size -ge 1024 ]; then
        echo "$((size / 1024))KB"
    else
        echo "${size}B"
    fi
}

# ====== Performance Analysis Functions ======
get_test_info() {
    local test_type=$1
    local result_file=$2
    
    local test_info=""
    case $test_type in
        *"Multi-pair Latency"*)
            test_info="(2 processes, multiple pairs)"
            ;;
        *"Multi-byte Latency"*)
            test_info="(2 processes, multiple message sizes)"
            ;;
        *"Bi-directional Bandwidth"*)
            test_info="(2 processes, bidirectional communication)"
            ;;
        *"Bandwidth"*)
            test_info="(2 processes)"
            ;;
        *"Latency"*)
            test_info="(2 processes)"
            ;;
        *"Collective Bandwidth"*)
            local procs=$(grep "^# Number of processes:" "$result_file" | awk '{print $NF}')
            if [ -z "$procs" ]; then
                procs=$(grep "mpirun.*-np" "$result_file" | grep -o -E "\-np[[:space:]]+[0-9]+" | awk '{print $2}')
            fi
            test_info="($procs processes, collective bandwidth)"
            ;;
        *"Allreduce"*|*"Broadcast"*|*"Scatter"*|*"Gather"*|*"Alltoall"*|*"Allgather"*|*"Reduce"*)
            local procs=$(grep "^# Number of processes:" "$result_file" | awk '{print $NF}')
            if [ -z "$procs" ]; then
                procs=$(grep "mpirun.*-np" "$result_file" | grep -o -E "\-np[[:space:]]+[0-9]+" | awk '{print $2}')
            fi
            test_info="($procs processes)"
            ;;
    esac
    echo "$test_info"
}

format_table_header() {
    local test_type=$1
    local num_columns=$2
    
    case $test_type in
        *"Multi-pair Latency"*)
            echo -e "# Pairs      Latency(us)"
            echo -e "--------    ------------"
            ;;
        *"Multi-byte Latency"*)
            echo -e "Size(B)      Latency(us)      Bandwidth(MB/s)"
            echo -e "--------    ------------    ---------------"
            ;;
        *"Bi-directional Bandwidth"*|*"Bandwidth"*)
            echo -e "Size(B)      Bandwidth(MB/s)"
            echo -e "--------    ---------------"
            ;;
        *"Collective Bandwidth"*)
            echo -e "Size(B)      Bandwidth(MB/s)      Min(MB/s)      Max(MB/s)"
            echo -e "--------    ---------------    -------------    -------------"
            ;;
        *"Non-blocking"*|*"NBC"*)
            echo "# Size           Overall(us)       Compute(us)    Pure Comm.(us)        Overlap(%)"
            echo "--------    ---------------    -------------    --------------    ---------------"
            ;;
        *"Latency"*)
            if [[ $num_columns -eq 2 ]]; then
                echo -e "Size(B)      Latency(us)"
                echo -e "--------    ------------"
            elif [[ $num_columns -eq 4 ]]; then
                echo -e "Size(B)      Latency(us)      Min(us)      Max(us)"
                echo -e "--------    ------------    ---------    ---------"
            elif [[ $num_columns -eq 5 ]]; then
                echo -e "Size(B)     Overall(us)     Compute(us)  Pure Comm.(us) Overlap(%)"
                echo -e "--------    ------------    ---------    ---------    -----------"
            fi
            ;;
        *)
            if [[ $num_columns -eq 2 ]]; then
                echo -e "Size(B)      Latency(us)"
                echo -e "--------    ------------"
            elif [[ $num_columns -eq 4 ]]; then
                echo -e "Size(B)      Latency(us)      Min(us)      Max(us)"
                echo -e "--------    ------------    ---------    ---------"
            elif [[ $num_columns -eq 5 ]]; then
                echo -e "Size(B)     Overall(us)     Compute(us)  Pure Comm.(us) Overlap(%)"
                echo -e "--------    ------------    ---------    ---------    -----------"
            fi
            ;;
    esac
}

format_data_row() {
    local test_type=$1
    local row=$2
    
    case $test_type in
        *"Multi-byte Latency"*)
            # Size(B)      Latency(us)      Bandwidth(MB/s)
            printf "%-12s%-14.2f%-17.2f\n" $(echo "$row" | awk '{printf "%d %.2f %.2f", $1, $2, $3}')
            ;;
        *"Collective Bandwidth"*)
            # Size(B)      Bandwidth(MB/s)      Min(MB/s)      Max(MB/s)
            local num_fields=$(echo "$row" | awk '{print NF}')
            if [ $num_fields -ge 4 ]; then
                printf "%-12s%-17.2f%-15.2f%-15.2f\n" $(echo "$row" | awk '{printf "%d %.2f %.2f %.2f", $1, $2, $3, $4}')
            elif [ $num_fields -eq 2 ]; then
                printf "%-12s%-17.2f\n" $(echo "$row" | awk '{printf "%d %.2f", $1, $2}')
            fi
            ;;
        *"Non-blocking"*|*"NBC"*)
            # Size           Overall(us)       Compute(us)    Pure Comm.(us)        Overlap(%)
            local size=$(echo "$row" | awk '{print $1}')
            local overall=$(echo "$row" | awk '{printf "%.2f", $2}')
            local compute=$(echo "$row" | awk '{printf "%.2f", $3}')
            local pure_comm=$(echo "$row" | awk '{printf "%.2f", $4}')
            local overlap=$(echo "$row" | awk '{printf "%.2f", $5}')
            printf "%-8d%20.2f%17.2f%17.2f%17.2f\n" "$size" "$overall" "$compute" "$pure_comm" "$overlap"
            ;;
        *)
            local num_fields=$(echo "$row" | awk '{print NF}')
            if [ $num_fields -eq 2 ]; then
                # Size(B)      Latency(us)
                printf "%-12s%-14.2f\n" $(echo "$row" | awk '{printf "%d %.2f", $1, $2}')
            elif [ $num_fields -eq 4 ]; then
                # Size(B)      Latency(us)    Min(us)    Max(us)
                printf "%-12s%-14.2f%-12.2f%-12.2f\n" $(echo "$row" | awk '{printf "%d %.2f %.2f %.2f", $1, $2, $3, $4}')
            elif [ $num_fields -eq 5 ]; then
                # Size(B)      Latency(us)    Min(us)    Max(us)    Iterations
                printf "%-12s%-14.2f%-12.2f%-12.2f%-12d\n" $(echo "$row" | awk '{printf "%d %.2f %.2f %.2f %d", $1, $2, $3, $4, $5}')
            fi
            ;;
    esac
}

# Detect non-monotonic latency values that may indicate protocol switches.
detect_latency_anomalies() {
    local result_file=$1
    local anomalies
    local status

    anomalies=$(awk '
        /^[[:space:]]*[0-9]+([[:space:]]|$)/ {
            if (NF < 2 || $1 + 0 <= 0 || $2 + 0 <= 0) {
                printf "Malformed latency row: %s\n", $0
                found = 1
                next
            }

            size = $1 + 0
            latency = $2 + 0

            if (count > 0) {
                if (size <= prev_size) {
                    printf "Unexpected size order: %d follows %d\n", size, prev_size
                    found = 1
                }

                if (latency < prev_latency) {
                    delta_percent = (prev_latency - latency) * 100.0 / prev_latency
                    label = ""
                    if ((prev_size == 131072 && size == 262144) || (prev_size == 262144 && size == 524288)) {
                        label = " (common protocol-switch range)"
                    }
                    printf "Non-monotonic latency: %d B=%.3f us -> %d B=%.3f us (%.2f%% lower)%s\n", prev_size, prev_latency, size, latency, delta_percent, label
                    found = 1
                }
            }

            prev_size = size
            prev_latency = latency
            count++
        }
        END {
            if (count == 0) {
                exit 2
            }
            exit found ? 0 : 1
        }
    ' "$result_file")
    status=$?

    if [ "$status" -eq 0 ]; then
        printf "%s\n" "$anomalies"
    fi

    return "$status"
}


calculate_statistics() {
    local test_type=$1
    local result_file=$2
    local stats=""
    
    case $test_type in
        *"Latency"*)
            local avg_latency=$(awk '/^[0-9]/ {sum+=$2; count++} END {if(count>0) printf "%.2f", sum/count}' "$result_file")
            stats="Average Latency: ${avg_latency:-N/A} us"
            
            if grep -q "^[0-9].*[0-9].*[0-9]" "$result_file"; then
                local min_latency=$(awk '/^[0-9]/ {if(min=="" || $3<min) min=$3} END {printf "%.2f", min}' "$result_file")
                local max_latency=$(awk '/^[0-9]/ {if($4>max) max=$4} END {printf "%.2f", max}' "$result_file")
                stats+=$'\n'"Minimum Latency: ${min_latency:-N/A} us"
                stats+=$'\n'"Maximum Latency: ${max_latency:-N/A} us"
            fi
            ;;
            
        *"Multi-byte Latency"*)
            local avg_latency=$(awk '/^[0-9]/ {sum+=$2; count++} END {if(count>0) printf "%.2f", sum/count}' "$result_file")
            local avg_bw=$(awk '/^[0-9]/ {sum+=$3; count++} END {if(count>0) printf "%.2f", sum/count}' "$result_file")
            local peak_bw=$(awk '/^[0-9]/ {if($3>max) max=$3} END {printf "%.2f", max}' "$result_file")
            
            stats="Average Latency: ${avg_latency:-N/A} us"
            stats+=$'\n'"Average Bandwidth: ${avg_bw:-N/A} MB/s"
            stats+=$'\n'"Peak Bandwidth: ${peak_bw:-N/A} MB/s"
            ;;
            
        *"Bandwidth"*|*"Bi-directional Bandwidth"*)
            local avg_bw=$(awk '/^[0-9]/ {sum+=$2; count++} END {if(count>0) printf "%.2f", sum/count}' "$result_file")
            local peak_bw=$(awk '/^[0-9]/ {if($2>max) max=$2} END {printf "%.2f", max}' "$result_file")
            local min_bw=$(awk '/^[0-9]/ {if(min=="" || $2<min) min=$2} END {printf "%.2f", min}' "$result_file")
            
            stats="Average Bandwidth: ${avg_bw:-N/A} MB/s"
            stats+=$'\n'"Peak Bandwidth: ${peak_bw:-N/A} MB/s"
            stats+=$'\n'"Minimum Bandwidth: ${min_bw:-N/A} MB/s"
            ;;
            
        *"Non-blocking"*)
            local avg_overall=$(awk '/^[0-9]/ {sum+=$2; count++} END {if(count>0) printf "%.2f", sum/count}' "$result_file")
            local avg_compute=$(awk '/^[0-9]/ {sum+=$3; count++} END {if(count>0) printf "%.2f", sum/count}' "$result_file")
            local avg_comm=$(awk '/^[0-9]/ {sum+=$4; count++} END {if(count>0) printf "%.2f", sum/count}' "$result_file")
            local avg_overlap=$(awk '/^[0-9]/ {sum+=$5; count++} END {if(count>0) printf "%.2f", sum/count}' "$result_file")
            
            stats="Average Overall Time: ${avg_overall:-N/A} us"
            stats+=$'\n'"Average Compute Time: ${avg_compute:-N/A} us"
            stats+=$'\n'"Average Communication Time: ${avg_comm:-N/A} us"
            stats+=$'\n'"Average Overlap: ${avg_overlap:-N/A}%"
            ;;
    esac
    
    echo "$stats"
}

analyze_performance() {
    local result_file=$1
    local test_type=$2
    
    local executable=${3:-unknown}
    local launch_command=${4:-N/A}
    local anomaly_status
    # Get test info
    local test_info=$(get_test_info "$test_type" "$result_file")
    
    echo -e "\n${YELLOW}Performance Analysis for $test_type $test_info:${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
    
    # Display raw test results
    echo -e "${GREEN}Raw Test Results:${NC}"
    
    # Get number of columns from data
    local num_columns=$(awk '/^[0-9]/ {print NF; exit}' "$result_file")
    
    # Display table header
    format_table_header "$test_type" "$num_columns"
    
    # Display data rows
    while read -r line; do
        if [[ $line =~ ^[0-9] ]]; then
            format_data_row "$test_type" "$line"
        fi
    done < "$result_file"
    
    # Display statistical analysis
    echo -e "\n${GREEN}Statistical Analysis:${NC}"
    calculate_statistics "$test_type" "$result_file" | while read -r stat; do
        echo "$stat"
    done
    

    # Detect protocol-switch-like non-monotonic latency patterns.
    if [[ "$test_type" == *Latency* ]]; then
        echo -e "\n${GREEN}Latency Anomaly Check:${NC}"
        detect_latency_anomalies "$result_file"
        anomaly_status=$?
        if [ "$anomaly_status" -eq 0 ]; then
            log "WARN" "Non-monotonic latency detected for $test_name"
            log "WARN" "Executable: $executable"
            log "WARN" "Launch command: $launch_command"
            log "WARN" "Config: SRUN_MPI_TYPE=${SRUN_MPI_TYPE:-unset}, SLURM_MPI_TYPE=${SLURM_MPI_TYPE:-unset}, UCX_TLS=${UCX_TLS:-unset}, UCX_NET_DEVICES=${UCX_NET_DEVICES:-unset}, TEST_SYSTEM_PARAMS=${TEST_SYSTEM_PARAMS:-unset}"
            echo -e "${YELLOW}Review the executable/command/config above; rerun the affected size range to rule out application or parameter issues.${NC}"
        elif [ "$anomaly_status" -eq 1 ]; then
            echo -e "${GREEN}No non-monotonic latency anomalies detected.${NC}"
        else
            echo -e "${RED}No numeric latency rows found; result format is invalid.${NC}"
            log "ERROR" "No numeric latency rows found in $result_file"
        fi
    fi

    echo -e "${BLUE}----------------------------------------${NC}"
}

# ====== Menu and User Interaction Functions ======
show_main_menu() {
    echo -e "${BLUE}========== HPC Communication Benchmarks ==========${NC}"
    echo -e "${GREEN}1)${NC} Point-to-Point Communication Tests"
    echo -e "${GREEN}2)${NC} Collective Communication Tests"
    echo -e "${GREEN}3)${NC} One-Sided Communication Tests"
    echo -e "${GREEN}4)${NC} Non-Blocking Collective Tests"
    echo -e "${GREEN}5)${NC} Run All Tests"
    echo -e "${GREEN}6)${NC} Show System Information"
    echo -e "${GREEN}7)${NC} Exit"
    echo -e "${BLUE}=================================================${NC}"
}

show_collective_menu() {
    echo -e "${BLUE}========== Select Collective Communication Type ==========${NC}"
    echo -e "${GREEN}1)${NC} Allreduce"
    echo -e "${GREEN}2)${NC} Alltoall" 
    echo -e "${GREEN}3)${NC} Allgather"
    echo -e "${GREEN}4)${NC} Broadcast"
    echo -e "${GREEN}5)${NC} Reduce"
    echo -e "${GREEN}6)${NC} Scatter"
    echo -e "${GREEN}7)${NC} Gather (Standard OSU only)"
    echo -e "${GREEN}8)${NC} Run All Standard OSU Tests"
    echo -e "${GREEN}9)${NC} Back to Main Menu"
    echo -e "${BLUE}=========================================================${NC}"
}

show_collective_test_mode_menu() {
    local collective_type=$1
    echo -e "${BLUE}========== $collective_type Test Mode ==========${NC}"
    echo -e "${GREEN}1)${NC} Latency Test (Standard OSU)"
    echo -e "${GREEN}2)${NC} Bandwidth Test (osu_collective_bandwidth_fixed)"
    echo -e "${GREEN}3)${NC} Both Tests"
    echo -e "${GREEN}4)${NC} Back to Previous Menu"
    echo -e "${BLUE}===============================================${NC}"
}

show_process_count_menu() {
    local max_procs=$(($(nproc) * 2))  # Total max processes across two nodes
    local current_count=2  # Start from 2 processes for collective tests
    
    echo -e "${BLUE}========== Select Process Count ==========${NC}"
    local option=1
    while [ $current_count -le $max_procs ]; do
        echo -e "${GREEN}$option)${NC} $current_count processes ($(($current_count/2)) per node)"
        current_count=$((current_count * 2))
        option=$((option + 1))
    done
    echo -e "${GREEN}$option)${NC} All process counts"
    echo -e "${GREEN}$((option + 1)))${NC} Back to Previous Menu"
    echo -e "${BLUE}======================================${NC}"
    
    # Return the number of options via global variable
    MENU_MAX_OPTION=$((option + 1))
}

show_test_type_menu() {
    local test_name=$1
    echo -e "${BLUE}========== $test_name Test Type ==========${NC}"
    echo -e "${GREEN}1)${NC} Blocking Communication"
    echo -e "${GREEN}2)${NC} Non-blocking Communication"
    echo -e "${GREEN}3)${NC} Both Communication Types"
    echo -e "${GREEN}4)${NC} Back to Previous Menu"
    echo -e "${BLUE}======================================${NC}"
}

show_p2p_menu() {
    echo -e "${BLUE}========== Point-to-Point Communication Tests ==========${NC}"
    echo -e "${GREEN}1)${NC} Latency Test"
    echo -e "${GREEN}2)${NC} Bandwidth Test"
    echo -e "${GREEN}3)${NC} Run All Available P2P Tests"
    echo -e "${GREEN}4)${NC} Back to Main Menu"
    echo -e "${BLUE}=================================================${NC}"
}

get_user_choice() {
    local prompt=$1
    local min=$2
    local max=$3
    local choice
    
    while true; do
        read -p "$prompt" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge "$min" ] && [ "$choice" -le "$max" ]; then
            echo "$choice"
            return 0
        else
            echo -e "${RED}Invalid option. Please enter a number between $min and $max.${NC}"
        fi
    done
}

get_process_counts() {
    local max_procs=$(($(nproc) * 2))
    local counts=()
    local current_count=2
    
    while [ $current_count -le $max_procs ]; do
        counts+=($current_count)
        current_count=$((current_count * 2))
    done
    echo "${counts[@]}"
}

show_system_info() {
    echo -e "${BLUE}========== System Information ==========${NC}"
    echo "Hostname: $(hostname)"
    echo "Date: $(date)"
    echo -e "\n${GREEN}MPI Information:${NC}"
    mpirun --allow-run-as-root --version
    echo -e "\n${GREEN}UCX Information:${NC}"
    ucx_info -v
    echo -e "\n${GREEN}Hardware Information:${NC}"
    echo "CPU Cores: $(nproc)"
    echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
    if command -v lspci >/dev/null 2>&1; then
        echo -e "\n${GREEN}Network Devices:${NC}"
        lspci | grep -i infiniband
    fi
    echo -e "${BLUE}======================================${NC}"
}

confirm_action() {
    local prompt=$1
    local response
    
    while true; do
        read -p "$prompt [y/n]: " response
        case $response in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            * ) echo "Please answer yes (y) or no (n)." ;;
        esac
    done
}

pause() {
    echo -e "\nPress Enter to continue..."
    read
}

# ====== Test Execution Functions ======
run_test() {
    local test_name=$1
    local test_path=$2
    local np=$3
    local output_file=$4
    local extra_params=$5
    local timeout=${6:-300}  # Default timeout of 300 seconds
    local app_params=$7      # New parameter for application-specific arguments

    # Refresh module environment before each test (PATH/LD_LIBRARY_PATH for mpirun -x)
    load_modules
    export_runtime_env
    refresh_mpi_env_params
    
    # Verify test executable
    if ! check_executable "$test_path"; then
        log "FAILURE" "Test $test_name failed - executable verification failed"
        return 1
    fi

    if ! verify_osu_library_deps "$test_path"; then
        log "FAILURE" "Test $test_name failed - shared library verification failed"
        return 1
    fi
    
    # Create test directory if needed
    local test_dir=$(dirname "$output_file")
    mkdir -p "$test_dir"
    
    # Construct launch command (srun inside Slurm job, or mpirun otherwise)
    local full_command
    full_command=$(build_mpi_launch_command "$np" "$extra_params" "$test_path" "$app_params")
    
    # Print detailed command information
    echo -e "\n${BLUE}========== Test Command Details ==========${NC}"
    echo -e "${GREEN}Test Name:${NC} $test_name"
    echo -e "${GREEN}Launcher:${NC} $MPI_LAUNCH_MODE"
    echo -e "${GREEN}Executable:${NC} $test_path"
    echo -e "${GREEN}Process Count:${NC} $np"
    echo -e "${GREEN}Output File:${NC} $output_file"
    echo -e "${GREEN}Timeout:${NC} ${timeout}s"
    echo -e "${GREEN}Full Command:${NC} $full_command"
    echo -e "${BLUE}========================================${NC}\n"
    
    # Log test start
    log "INFO" "Starting $test_name with $np processes..."
    log "DEBUG" "Command: $full_command"
    
    # Run the test with timeout
    timeout ${timeout}s $full_command > "$output_file" 2>&1
    local exit_code=$?
    
    # Handle different exit codes
    case $exit_code in
        0)
            log "SUCCESS" "$test_name completed successfully"
            analyze_performance "$output_file" "$test_name" "$test_path" "$full_command"
            return 0
            ;;
        124)  # timeout exit code
            log "FAILURE" "$test_name failed - timeout after ${timeout}s"
            ;;
        *)
            log "FAILURE" "$test_name failed with exit code $exit_code"
            ;;
    esac
    
    # Log error details on failure
    log "ERROR" "Error details for $test_name:"
    tail -n 20 "$output_file" | while read -r line; do
        log "ERROR" "  $line"
    done
    
    return $exit_code
}

# ====== Enhanced Collective Test Functions ======
run_collective_latency_test() {
    local collective_type=$1
    local total_procs=$2
    local is_blocking=$3
    
    # Check minimum process count
    if [ "$total_procs" -lt 2 ]; then
        log "ERROR" "$collective_type latency test requires at least two processes"
        return 1
    fi
    
    local base_path="$OSU_PATH/collective/blocking"
    if [ "$is_blocking" = false ]; then
        base_path="$OSU_PATH/collective/non_blocking"
    fi
    local output_dir="$RESULT_DIR/collective/${collective_type,,}_latency"
    mkdir -p "$output_dir"
    
    # Determine executable name based on test parameters
    local exec_name=""
    if [ "$is_blocking" = true ]; then
        # Convert collective type to executable name
        case $collective_type in
            "Broadcast") exec_name="osu_bcast" ;;
            *) exec_name="osu_${collective_type,,}" ;;
        esac
    else
        # For non-blocking tests
        case $collective_type in
            "Broadcast") exec_name="osu_ibcast" ;;
            *) exec_name="osu_i${collective_type,,}" ;;
        esac
    fi

    local executable="$base_path/$exec_name"
    
    # Check if executable exists
    if [ ! -f "$executable" ]; then
        log "ERROR" "Test executable not found: $executable"
        return 1
    fi
    
    # Generate output file name
    local comm_type=$([ "$is_blocking" = true ] && echo "blocking" || echo "non_blocking")
    local output_file="$output_dir/latency_${comm_type}_${total_procs}p.txt"
    
    # Get process distribution
    local proc_dist=$(get_process_distribution $total_procs)
    
    # Print test configuration
    echo -e "\n${BLUE}========== Collective Latency Test Configuration ==========${NC}"
    echo -e "${GREEN}Collective Type:${NC} $collective_type"
    echo -e "${GREEN}Test Type:${NC} Latency"
    echo -e "${GREEN}Communication:${NC} $([ "$is_blocking" = true ] && echo "Blocking" || echo "Non-blocking")"
    echo -e "${GREEN}Total Processes:${NC} $total_procs"
    echo -e "${GREEN}Executable:${NC} $executable"
    echo -e "${GREEN}Process Distribution:${NC} $proc_dist"
    echo -e "${BLUE}==========================================================${NC}\n"
    
    # Run the test
    log "INFO" "Running $collective_type latency test with $total_procs processes..."
    run_test "$collective_type Latency" "$executable" "$total_procs" "$output_file" "$proc_dist" "$COLLECTIVE_TIMEOUT"
}

run_collective_bandwidth_test() {
    local collective_type=$1
    local total_procs=$2
    local max_size=${3:-$COLLECTIVE_BW_MAX_SIZE}
    local iterations=${4:-$COLLECTIVE_BW_ITERATIONS}
    local warmup=${5:-$COLLECTIVE_BW_WARMUP}
    
    # Check if collective type is supported by bandwidth test
    if [[ ! ${COLLECTIVE_TYPE_MAP[$collective_type]+_} ]]; then
        log "ERROR" "Collective type '$collective_type' is not supported by bandwidth test"
        return 1
    fi
    
    # Get the type number for the collective operation
    local type_num=${COLLECTIVE_TYPE_MAP[$collective_type]}
    
    # Check if osu_collective_bandwidth_fixed exists
    local executable="$OSU_PATH/collective/osu_collective_bandwidth_fixed"
    if [ ! -f "$executable" ]; then
        executable="osu_collective_bandwidth_fixed"  # Try system PATH
        if ! command -v "$executable" >/dev/null 2>&1; then
            log "ERROR" "osu_collective_bandwidth_fixed not found in $OSU_PATH/collective/ or system PATH"
            return 1
        fi
    fi
    
    local output_dir="$RESULT_DIR/collective/${collective_type,,}_bandwidth"
    mkdir -p "$output_dir"
    local output_file="$output_dir/bandwidth_${total_procs}p.txt"
    
    # Get process distribution
    local proc_dist=$(get_process_distribution $total_procs)
    
    # Print test configuration
    echo -e "\n${BLUE}========== Collective Bandwidth Test Configuration ==========${NC}"
    echo -e "${GREEN}Collective Type:${NC} $collective_type (type=$type_num)"
    echo -e "${GREEN}Test Type:${NC} Bandwidth"
    echo -e "${GREEN}Executable:${NC} $executable"
    echo -e "${GREEN}Total Processes:${NC} $total_procs"
    echo -e "${GREEN}Max Message Size:${NC} $(format_size $max_size)"
    echo -e "${GREEN}Iterations:${NC} $iterations"
    echo -e "${GREEN}Warmup Iterations:${NC} $warmup"
    echo -e "${GREEN}Process Distribution:${NC} $proc_dist"
    echo -e "${BLUE}============================================================${NC}\n"
    
    # Construct app parameters
    local app_params="-t $type_num -m $max_size -i $iterations -w $warmup"
    
    # Run the test
    log "INFO" "Running $collective_type bandwidth test with $total_procs processes..."
    run_test "$collective_type Collective Bandwidth" "$executable" "$total_procs" "$output_file" "$proc_dist" "$COLLECTIVE_BW_TIMEOUT" "$app_params"
}

run_collective_test() {
    local test_name=$1
    local test_type=$2
    local total_procs=$3
    local ppn=$4
    local is_blocking=$5
    
    # Check minimum process count
    if [ "$total_procs" -lt 2 ]; then
        log "ERROR" "$test_name test requires at least two processes"
        return 1
    fi
    
    local base_path="$OSU_PATH/collective/blocking"
    if [ "$is_blocking" = false ]; then
        base_path="$OSU_PATH/collective/non_blocking"
    fi
    local output_dir="$RESULT_DIR/collective/${test_name,,}"
    mkdir -p "$output_dir"
    
    # Determine executable name based on test parameters
    local exec_name=""
    if [ "$is_blocking" = true ]; then
        case $test_type in
            "latency")
                # Convert broadcast to bcast in executable name
                if [ "$test_name" == "Broadcast" ]; then
                    exec_name="osu_bcast"
                else
                    exec_name="osu_${test_name,,}"
                fi
                ;;
            "bandwidth")
                # Convert broadcast to bcast in executable name for bandwidth test
                if [ "$test_name" == "Broadcast" ]; then
                    exec_name="osu_bcast_bw"
                else
                    exec_name="osu_${test_name,,}_bw"
                fi
                ;;
        esac
    else
        # For non-blocking tests
        if [ "$test_name" == "Broadcast" ]; then
            exec_name="osu_ibcast"  # Non-blocking broadcast only has latency test
        else
            case $test_type in
                "latency")
                    exec_name="osu_i${test_name,,}"
                    ;;
                "bandwidth")
                    exec_name="osu_i${test_name,,}_bw"
                    ;;
            esac
        fi
    fi

    local executable="$base_path/$exec_name"
    
    # Check if executable exists
    if [ ! -f "$executable" ]; then
        log "ERROR" "Test executable not found: $executable"
        return 1
    fi
    
    # Generate output file name
    local comm_type=$([ "$is_blocking" = true ] && echo "blocking" || echo "non_blocking")
    local output_file="$output_dir/${test_type}_${comm_type}_${total_procs}p.txt"
    
    # Get process distribution
    local proc_dist=$(get_process_distribution $total_procs)
    
    # Print test configuration
    echo -e "\n${BLUE}========== Test Configuration ==========${NC}"
    echo -e "${GREEN}Test Name:${NC} $test_name"
    echo -e "${GREEN}Test Type:${NC} $test_type"
    echo -e "${GREEN}Communication:${NC} $([ "$is_blocking" = true ] && echo "Blocking" || echo "Non-blocking")"
    echo -e "${GREEN}Total Processes:${NC} $total_procs"
    echo -e "${GREEN}Processes per Node:${NC} $ppn"
    echo -e "${GREEN}Executable:${NC} $executable"
    echo -e "${GREEN}Process Distribution:${NC} $proc_dist"
    echo -e "${BLUE}======================================${NC}\n"
    
    # Determine timeout based on test type
    local timeout_val=$COLLECTIVE_TIMEOUT
    if [ "$test_type" == "bandwidth" ]; then
        timeout_val=$COLLECTIVE_BW_TIMEOUT
    fi
    
    # Run the test
    log "INFO" "Running $test_name $test_type test with $total_procs processes ($ppn per node)..."
    run_test "$test_name $test_type" "$executable" "$total_procs" "$output_file" "$proc_dist" "$timeout_val"
}

run_p2p_test_suite() {
    local test_name=$1
    local executable=$2
    local output_dir=$3
    local timeout=${4:-$P2P_TIMEOUT}
    
    log "INFO" "Running $test_name test suite..."
    mkdir -p "$output_dir"
    
    # Run basic test with 2 processes
    run_test "$test_name (2 processes)" "$executable" 2 \
        "$output_dir/${test_name,,}_2p.txt" \
        "$(get_process_distribution 2)" $timeout
    
    # Run tests with different message sizes if supported
    if [[ $test_name =~ ^(Latency|Bandwidth)$ ]]; then
        #for size in "${MESSAGE_SIZES[@]}"; do
        local size_str=$(format_size $size)
        # Move -m parameter after the executable path
        run_test "$test_name ($size_str)" "$executable" 2 \
            "$output_dir/${test_name,,}_${size}B.txt" \
            "$(get_process_distribution 2)" $timeout
        #done
    fi
}

run_one_sided_test_suite() {
    local test_name=$1
    local executable=$2
    local output_dir=$3
    local timeout=${4:-$ONE_SIDED_TIMEOUT}
    
    log "INFO" "Running $test_name test suite..."
    mkdir -p "$output_dir"
    
    # Run basic test
    run_test "$test_name" "$executable" 2 \
        "$output_dir/${test_name,,}.txt" \
        "$(get_process_distribution 2)" $timeout
    
    # Run tests with different message sizes
    for size in "${MESSAGE_SIZES[@]}"; do
        local size_str=$(format_size $size)
        run_test "$test_name ($size_str)" "$executable" 2 \
            "$output_dir/${test_name,,}_${size}B.txt" \
            "$(get_process_distribution 2) -m $size" $timeout
    done
}

# ====== 1. 点对点通信测试 ======
run_p2p_tests() {
    local output_dir="$1"
    local timeout="$2"

    while true; do
        show_p2p_menu
        local choice=$(get_user_choice "Select P2P test (1-4): " 1 4)
        
        case $choice in
            1)
                run_single_p2p_test "Latency" "$output_dir" "$timeout"
                ;;
            2)
                run_single_p2p_test "Bandwidth" "$output_dir" "$timeout"
                ;;
            3)
                run_all_p2p_tests "$output_dir" "$timeout"
                ;;
            4)
                return
                ;;
        esac
    done
}

run_single_p2p_test() {
    local test_name="$1"
    local output_dir="$2"
    local timeout="$3"
    
    if [ "$test_name" == "Latency" ]; then
        local executable="$OSU_PATH/pt2pt/standard/osu_latency"
    elif [ "$test_name" == "Bandwidth" ]; then
        local executable="$OSU_PATH/pt2pt/standard/osu_bw"
    fi

    # Check if executable exists
    if [ ! -f "$executable" ] || [ ! -x "$executable" ]; then
        echo -e "${RED}Error: Test executable not found or not executable: $executable${NC}"
        return 1
    fi

    # Show test configuration
    echo -e "\n${BLUE}Running $test_name Test${NC}"
    echo -e "Executable: $executable"
    echo -e "Output file: $output_dir/${test_name,,}.txt\n"

    # Run the test
    if [[ $test_name =~ ^(Latency|Bandwidth)$ ]]; then
        echo -e "${YELLOW}Select message size for testing:${NC}"
        echo -e "${GREEN}1)${NC} Test All Sizes (1B to 4MB)"
        echo -e "${GREEN}2)${NC} Custom Size"
        echo -e "${GREEN}3)${NC} Back"
        
        local size_choice=$(get_user_choice "Select message size option (1-3): " 1 3)
        case $size_choice in
            1) 
                # Run test with default sizes (without -m parameter)
                run_test "$test_name (All Sizes)" "$executable" 2 \
                    "$output_dir/${test_name,,}_all.txt" \
                    "$(get_process_distribution 2)" $timeout
                ;;
            2)
                echo -e "\nEnter message size in bytes (e.g., 1024 for 1KB):"
                read -r custom_size
                if [[ "$custom_size" =~ ^[0-9]+$ ]]; then
                    local size_str=$(format_size $custom_size)
                    run_test "$test_name ($size_str)" "$executable" 2 \
                        "$output_dir/${test_name,,}_${custom_size}B.txt" \
                        "$(get_process_distribution 2)" $timeout "-m $custom_size"
                else
                    echo -e "${RED}Invalid size. Please enter a positive number.${NC}"
                    return 1
                fi
                ;;
            3) 
                return
                ;;
        esac
    else
        run_test "$test_name" "$executable" 2 \
            "$output_dir/${test_name,,}.txt" \
            "$(get_process_distribution 2)" $timeout
    fi
}

run_all_p2p_tests() {
    local output_dir="$1"
    local timeout="$2"

    local test_names=("Latency" "Bandwidth")
    
    for test_name in "${test_names[@]}"; do
        run_single_p2p_test "$test_name" "$output_dir" "$timeout"
    done
}

# ====== 2. 增强的集合通信测试 ======
run_collective_tests() {
    while true; do
        show_collective_menu
        local coll_choice=$(get_user_choice "Select collective operation (1-9): " 1 9)
        
        if [ "$coll_choice" == "9" ]; then
            return
        fi
        
        local collective_type=""
        case $coll_choice in
            1) collective_type="Allreduce" ;;
            2) collective_type="Alltoall" ;;
            3) collective_type="Allgather" ;;
            4) collective_type="Broadcast" ;;
            5) collective_type="Reduce" ;;
            6) collective_type="Scatter" ;;
            7) collective_type="Gather" ;;
            8) 
                # Run all standard OSU tests
                run_all_standard_collective_tests
                continue
                ;;
            *) 
                echo -e "${RED}Invalid option. Please select 1-9.${NC}"
                continue
                ;;
        esac
        
        # Show test mode menu for the selected collective type
        while true; do
            show_collective_test_mode_menu "$collective_type"
            local mode_choice=$(get_user_choice "Select test mode (1-4): " 1 4)
            
            if [ "$mode_choice" == "4" ]; then
                break
            fi
            
            # Show process count menu
            while true; do
                show_process_count_menu
                local proc_choice=$(get_user_choice "Select process count (1-$MENU_MAX_OPTION): " 1 $MENU_MAX_OPTION)
                
                if [ "$proc_choice" == "$MENU_MAX_OPTION" ]; then
                    break
                fi
                
                local selected_counts=()
                if [ "$proc_choice" == "$((MENU_MAX_OPTION - 1))" ]; then
                    # Generate array of powers of 2 starting from 2
                    local count=2
                    while [ $count -le $(($(nproc) * 2)) ]; do
                        selected_counts+=($count)
                        count=$((count * 2))
                    done
                elif [ "$proc_choice" -ge 1 ] && [ "$proc_choice" -lt $((MENU_MAX_OPTION - 1)) ]; then
                    # Calculate process count as power of 2
                    selected_counts=($(( 2 ** proc_choice )))
                else
                    echo -e "${RED}Invalid option.${NC}"
                    continue
                fi
                
                # Run selected tests based on mode choice
                for total_procs in "${selected_counts[@]}"; do
                    log "INFO" "=== $collective_type Tests with $total_procs processes ==="
                    
                    case $mode_choice in
                        1) # Latency Test only
                            run_collective_latency_test "$collective_type" $total_procs true
                            ;;
                        2) # Bandwidth Test only
                            if [[ ${COLLECTIVE_TYPE_MAP[$collective_type]+_} ]]; then
                                run_collective_bandwidth_test "$collective_type" $total_procs
                            else
                                echo -e "${YELLOW}Bandwidth test not supported for $collective_type${NC}"
                            fi
                            ;;
                        3) # Both tests
                            run_collective_latency_test "$collective_type" $total_procs true
                            if [[ ${COLLECTIVE_TYPE_MAP[$collective_type]+_} ]]; then
                                run_collective_bandwidth_test "$collective_type" $total_procs
                            else
                                echo -e "${YELLOW}Bandwidth test not supported for $collective_type${NC}"
                            fi
                            ;;
                        *)
                            echo -e "${RED}Invalid option.${NC}"
                            continue
                            ;;
                    esac
                done
                
                pause
            done
        done
    done
}

run_all_standard_collective_tests() {
    local collective_types=("Allreduce" "Alltoall" "Allgather" "Broadcast" "Reduce" "Scatter" "Gather")
    
    # Show process count menu
    show_process_count_menu
    local proc_choice=$(get_user_choice "Select process count for all tests (1-$MENU_MAX_OPTION): " 1 $MENU_MAX_OPTION)
    
    if [ "$proc_choice" == "$MENU_MAX_OPTION" ]; then
        return
    fi
    
    local selected_counts=()
    if [ "$proc_choice" == "$((MENU_MAX_OPTION - 1))" ]; then
        # Generate array of powers of 2 starting from 2
        local count=2
        while [ $count -le $(($(nproc) * 2)) ]; do
            selected_counts+=($count)
            count=$((count * 2))
        done
    elif [ "$proc_choice" -ge 1 ] && [ "$proc_choice" -lt $((MENU_MAX_OPTION - 1)) ]; then
        # Calculate process count as power of 2
        selected_counts=($(( 2 ** proc_choice )))
    else
        echo -e "${RED}Invalid option.${NC}"
        return
    fi
    
    # Run all tests
    for total_procs in "${selected_counts[@]}"; do
        local ppn=$((total_procs / 2))
        log "INFO" "=== Running All Collective Tests with $total_procs processes ==="
        
        for collective_type in "${collective_types[@]}"; do
            # Run latency test (blocking)
            run_collective_latency_test "$collective_type" $total_procs true
            
            # Run non-blocking latency test
            run_collective_latency_test "$collective_type" $total_procs false
            
            # Run bandwidth test (if supported by osu_collective_bandwidth_fixed)
            if [[ ${COLLECTIVE_TYPE_MAP[$collective_type]+_} ]]; then
                run_collective_bandwidth_test "$collective_type" $total_procs
            fi
        done
    done
    
    pause
}

# ====== 3. 单向通信测试（如果支持）======
run_one_sided_tests() {
    log "INFO" "==================== One-Sided Communication Tests ===================="
    
    local onesided_dir="$RESULT_DIR/one-sided"
    mkdir -p $onesided_dir
    
    # Put操作测试
    run_one_sided_test_suite "Put Latency" "$OSU_PATH/one-sided/osu_put_latency" $onesided_dir
    
    run_one_sided_test_suite "Put Bandwidth" "$OSU_PATH/one-sided/osu_put_bw" $onesided_dir
    
    # Get操作测试
    run_one_sided_test_suite "Get Latency" "$OSU_PATH/one-sided/osu_get_latency" $onesided_dir
    
    run_one_sided_test_suite "Get Bandwidth" "$OSU_PATH/one-sided/osu_get_bw" $onesided_dir
    
    # 原子操作测试
    run_one_sided_test_suite "CAS Latency" "$OSU_PATH/one-sided/osu_cas_latency" $onesided_dir
    
    run_one_sided_test_suite "Accumulate Latency" "$OSU_PATH/one-sided/osu_acc_latency" $onesided_dir
}

# ====== 5. 非阻塞集合通信测试 ======
run_nbc_tests() {
    log "INFO" "==================== Non-Blocking Collective Tests ===================="
    
    local total_procs=16
    local ppn=8
    local nbc_dir="$RESULT_DIR/nbc/ppn${ppn}"
    mkdir -p $nbc_dir

    log "INFO" "=== NBC Tests with $ppn processes per node ==="

    # 非阻塞Allreduce
    run_test "NBC Allreduce" "$OSU_PATH/collective/non_blocking/osu_iallreduce" $total_procs \
        "$nbc_dir/iallreduce.txt" "$(get_host_params 16)" "$COLLECTIVE_TIMEOUT"

    # 非阻塞Alltoall
    run_test "NBC Alltoall" "$OSU_PATH/collective/non_blocking/osu_ialltoall" $total_procs \
        "$nbc_dir/ialltoall.txt" "$(get_host_params 16)" "$COLLECTIVE_TIMEOUT"

    # 非阻塞Broadcast
    run_test "NBC Broadcast" "$OSU_PATH/collective/non_blocking/osu_ibcast" $total_procs \
        "$nbc_dir/ibcast.txt" "$(get_host_params 16)" "$COLLECTIVE_TIMEOUT"
}

# ====== Environment verification ======
verify_environment() {
    log "INFO" "Verifying environment setup..."
    
    # Load modules first
    load_modules

    if ! detect_slurm_launcher; then
        return 1
    fi
    
    # Create hostfile (reference only when using Slurm launcher)
    create_hostfile
    
    # Check if OSU benchmark directory exists
    if [ ! -d "$OSU_PATH" ]; then
        log "ERROR" "OSU benchmark directory not found at $OSU_PATH"
        return 1
    fi
    
    # Check node connectivity (skip SSH ping when Slurm manages nodes)
    if [ "$USE_SLURM_LAUNCHER_ACTIVE" = true ]; then
        log "INFO" "Using Slurm nodes: ${SLURM_NODELIST:-unknown}"
    else
        for node in $NODE1 $NODE2; do
            if ! ping -c 1 -W 2 $node >/dev/null 2>&1; then
                log "ERROR" "Cannot ping node $node"
                return 1
            fi
        done
    fi
    
    # Check MPI installation
    if ! command -v mpirun >/dev/null 2>&1; then
        log "ERROR" "mpirun not found"
        return 1
    fi
    
    # Check UCX installation
    if ! command -v ucx_info >/dev/null 2>&1; then
        log "WARN" "ucx_info not found, UCX may not be properly installed"
    fi
    
    # Verify specific test executables
    local test_files=(
        "collective/blocking/osu_allreduce"
        "collective/non_blocking/osu_iallreduce"
        "collective/blocking/osu_bcast"
        "collective/non_blocking/osu_ibcast"
        "pt2pt/standard/osu_latency"
        "pt2pt/standard/osu_bw"
    )
    
    for test_file in "${test_files[@]}"; do
        if [ ! -f "$OSU_PATH/$test_file" ]; then
            log "ERROR" "Test executable not found: $OSU_PATH/$test_file"
            return 1
        fi
        if ! verify_osu_library_deps "$OSU_PATH/$test_file"; then
            return 1
        fi
    done
    
    # Check file permissions
    if [ ! -x "$OSU_PATH/collective/blocking/osu_allreduce" ]; then
        log "ERROR" "Test executable not executable: $OSU_PATH/collective/blocking/osu_allreduce"
        return 1
    fi
    
    # Check for osu_collective_bandwidth_fixed
    if [ ! -f "$OSU_PATH/collective/osu_collective_bandwidth_fixed" ]; then
        if ! command -v "osu_collective_bandwidth_fixed" >/dev/null 2>&1; then
            log "WARN" "osu_collective_bandwidth_fixed not found, collective bandwidth tests will not be available"
        else
            log "INFO" "osu_collective_bandwidth_fixed found in system PATH"
        fi
    else
        log "INFO" "osu_collective_bandwidth_fixed found in OSU path"
    fi
    
    log "SUCCESS" "Environment verification completed successfully"
    return 0
}

# ====== Cleanup and Signal Handling ======
cleanup() {
    local exit_code=$1
    
    # Kill any running MPI processes
    if pgrep -f "mpirun" > /dev/null; then
        log "INFO" "Cleaning up running MPI processes..."
        pkill -9 -f "mpirun"
    fi
    
    # Kill any running test processes
    if pgrep -f "osu_" > /dev/null; then
        log "INFO" "Cleaning up running test processes..."
        pkill -9 -f "osu_"
    fi
    
    # Clean up hostfile if created
    if [ "$USE_HOSTFILE" = true ] && [ -f "$HOSTFILE_PATH" ]; then
        rm -f "$HOSTFILE_PATH"
        log "INFO" "Hostfile cleaned up"
    fi
    
    # Save system information if not already done
    if [ ! -f "$RESULT_DIR/system_info.txt" ]; then
        log "INFO" "Saving system information..."
        {
            echo "Test completed at: $(date)"
            echo "Hostname: $(hostname)"
            echo "Configuration:"
            echo "  USE_MODULES: $USE_MODULES"
            echo "  USE_HOSTFILE: $USE_HOSTFILE"
            echo "  NODE1: $NODE1"
            echo "  NODE2: $NODE2"
            echo "MPI Version:"
            mpirun --allow-run-as-root --version
            echo "UCX Info:"
            if command -v ucx_info >/dev/null 2>&1; then
                ucx_info -v
            else
                echo "UCX not available"
            fi
            echo "CPU Info:"
            lscpu
            echo "Memory Info:"
            free -h
            if command -v lspci >/dev/null 2>&1; then
                echo "Network Devices:"
                lspci | grep -i infiniband
            fi
        } > "$RESULT_DIR/system_info.txt"
    fi
    
    # Compress results if any tests were run
    if [ -d "$RESULT_DIR" ] && [ "$(ls -A $RESULT_DIR)" ]; then
        log "INFO" "Compressing test results..."
        local archive_name="osu_results_${TIMESTAMP}.tar.gz"
        tar -czf "$archive_name" "$RESULT_DIR" && \
            log "SUCCESS" "Results archived to $archive_name" || \
            log "ERROR" "Failed to archive results"
    fi
    
    log "INFO" "Cleanup completed"
    exit ${exit_code:-0}
}

# Set up signal handlers
trap 'log "INFO" "Received SIGINT"; cleanup 130' SIGINT
trap 'log "INFO" "Received SIGTERM"; cleanup 143' SIGTERM
trap 'log "ERROR" "Script error on line $LINENO"; cleanup 1' ERR

# ====== Main Function ======
main() {
    # Print banner
    echo -e "${BLUE}"
    cat << "EOF"
 HPC Communication Performance Benchmark
 Enhanced Collective Testing Suite
=====================================
EOF
    echo -e "${NC}"
    
    # Log script start
    log "INFO" "Starting Enhanced HPC Communication Performance Benchmark"
    log "INFO" "Nodes: $NODE1, $NODE2"
    log "INFO" "UCX Parameters: $UCX_PARAMS"
    log "INFO" "HIP Parameters: $HIP_PARAMS"
    log "INFO" "Module Loading: $USE_MODULES"
    log "INFO" "Hostfile Usage: $USE_HOSTFILE"
    log "INFO" "Result directory: $RESULT_DIR"
    log "INFO" "Supported collective types for bandwidth testing: ${!COLLECTIVE_TYPE_MAP[*]}"
    
    # Verify environment
    if ! verify_environment; then
        log "ERROR" "Environment verification failed. Please fix the issues and try again."
        cleanup 1
    fi
    
    # Save initial system information
    {
        echo "Test started at: $(date)"
        echo "Hostname: $(hostname)"
        echo "Slurm Job ID: ${SLURM_JOB_ID:-unset}"
        echo "Slurm Nodes: ${SLURM_NNODES:-unset}"
        echo "Slurm Node List: ${SLURM_NODELIST:-unset}"
        echo "MPI Launcher: $MPI_LAUNCH_MODE"
        echo "Configuration:"
        echo "  USE_MODULES: $USE_MODULES"
        echo "  USE_HOSTFILE: $USE_HOSTFILE"
        echo "  NODE1: $NODE1"
        echo "  NODE2: $NODE2"
        echo "  Collective Types Supported: ${!COLLECTIVE_TYPE_MAP[*]}"
        echo "MPI Version:"
        mpirun --allow-run-as-root --version
        echo "UCX Info:"
        if command -v ucx_info >/dev/null 2>&1; then
            ucx_info -v
        else
            echo "UCX not available"
        fi
        echo "CPU Info:"
        lscpu
        echo "Memory Info:"
        free -h
        if command -v lspci >/dev/null 2>&1; then
            echo "Network Devices:"
            lspci | grep -i infiniband
        fi
    } > "$RESULT_DIR/system_info.txt"
    
    # Main menu loop
    while true; do
        show_main_menu
        local choice=$(get_user_choice "Select tests to run (1-7): " 1 7)
        
        case $choice in
            1)
                log "INFO" "Running Point-to-Point Tests"
                run_p2p_tests "$RESULT_DIR/p2p" "$P2P_TIMEOUT"
                ;;
            2)
                log "INFO" "Running Enhanced Collective Communication Tests"
                run_collective_tests
                ;;
            3)
                log "INFO" "Running One-Sided Communication Tests"
                run_one_sided_tests
                ;;
            4)
                log "INFO" "Running Non-Blocking Collective Tests"
                run_nbc_tests
                ;;
            5)
                if confirm_action "This will run all tests and may take a long time. Continue?"; then
                    log "INFO" "Running All Tests"
                    run_p2p_tests "$RESULT_DIR/p2p" "$P2P_TIMEOUT"
                    run_collective_tests
                    run_one_sided_tests
                    run_nbc_tests
                    log "SUCCESS" "All tests completed"
                fi
                ;;
            6)
                show_system_info
                pause
                ;;
            7)
                log "INFO" "Testing completed"
                cleanup 0
                ;;
        esac
    done
}

# Start the script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
