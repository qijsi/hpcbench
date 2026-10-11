#!/bin/bash
# stream_comprehensive_test.sh
# Comprehensive STREAM memory bandwidth test script for continuous and strided access

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SYSTEM_INFO_FILE="system_info.txt"
RESULTS_DIR="stream_results_$(date +%Y%m%d_%H%M%S)"
STREAM_ORIGINAL="stream_original.c"
STREAM_STRIDE="stream_stride.c"
VERBOSE=${VERBOSE:-0}
REPEAT_RUNS=${REPEAT_RUNS:-3}
REPEAT_TOLERANCE_PCT=${REPEAT_TOLERANCE_PCT:-5}
AUTOMATED_STRIDES=${AUTOMATED_STRIDES:-"1 4"}

# Logging functions
log_info() {
    [ "$VERBOSE" -eq 1 ] && echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    [ "$VERBOSE" -eq 1 ] && echo -e "${BLUE}[DEBUG]${NC} $1" >&2
}

# Create results directory
create_results_dir() {
    mkdir -p "$RESULTS_DIR"
}

# Collect system information
collect_system_info() {
    {
        echo "=== System Information ==="
        echo "Date: $(date)"
        echo ""
        
        echo "=== CPU Information ==="
        lscpu | grep -E "Model name|Socket|Core|Thread|L1d|L1i|L2|L3|CPU MHz"
        echo ""
        
        echo "=== Memory Information ==="
        grep -E "MemTotal|MemFree|MemAvailable" /proc/meminfo
        echo ""
        
        echo "=== NUMA Information ==="
        if command -v numactl &> /dev/null; then
            numactl --hardware
            echo ""
            numactl --show
        else
            echo "numactl not installed"
        fi
        echo ""
        
        echo "=== Kernel Information ==="
        uname -a
        echo ""
    } > "$RESULTS_DIR/$SYSTEM_INFO_FILE"
    
    # Extract key parameters
    export CPU_MODEL=$(lscpu | grep "Model name" | sed 's/Model name:\s*//')
    export CORES=$(get_system_cpu_count)
    export TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    export AVAIL_MEM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    local l3_cache_bytes
    l3_cache_bytes=$(lscpu -B 2>/dev/null | awk '/^L3 cache:/ {print $3; exit}')
    if [[ "$l3_cache_bytes" =~ ^[0-9]+$ ]]; then
        export L3_SIZE_KB=$((l3_cache_bytes / 1024))
    else
        local cache_value cache_unit
        cache_value=$(lscpu | grep "L3 cache" | awk '{print $2}')
        cache_unit=$(lscpu | grep "L3 cache" | awk '{print $3}')
        case "$cache_unit" in
            K|KiB) export L3_SIZE_KB=$cache_value ;;
            M|MiB) export L3_SIZE_KB=$((cache_value * 1024)) ;;
            G|GiB) export L3_SIZE_KB=$((cache_value * 1024 * 1024)) ;;
            *) export L3_SIZE_KB=0 ;;
        esac
    fi
    [[ "$L3_SIZE_KB" =~ ^[0-9]+$ ]] || export L3_SIZE_KB=0
    
    # NUMA node count
    if command -v numactl &> /dev/null; then
        export NUMA_NODES=$(numactl --hardware | grep "available:" | awk '{print $2}')
    else
        export NUMA_NODES=1
    fi
    [[ "$NUMA_NODES" =~ ^[0-9]+$ ]] || export NUMA_NODES=1
    [ "$NUMA_NODES" -lt 1 ] && export NUMA_NODES=1
    export LLC_SIZE_KB=$((L3_SIZE_KB / NUMA_NODES))
    [ "$LLC_SIZE_KB" -lt 256 ] && export LLC_SIZE_KB=256
}

# Show system information in a cleaner format
show_system_summary() {
    echo "=== System Hardware Information ==="
    echo "CPU Model: $CPU_MODEL"
    echo "Physical Cores: $CORES"
    
    if [ -f "/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq" ]; then
        max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)
        max_freq_ghz=$(echo "scale=2; $max_freq / 1000000" | bc)
        echo "CPU Max Frequency: ${max_freq_ghz} GHz"
    fi
    
    # Memory Information
    echo ""
    echo "Memory Configuration:"
    echo "Total Memory: $(echo "scale=1; $TOTAL_MEM_KB / 1024 / 1024" | bc) GB"
    echo "Available Memory: $(echo "scale=1; $AVAIL_MEM_KB / 1024 / 1024" | bc) GB"
    
    if command -v dmidecode &> /dev/null && [ $(id -u) -eq 0 ]; then
        mem_type=$(dmidecode -t memory | grep -m1 "Type:" | awk '{print $2}')
        mem_speed=$(dmidecode -t memory | grep -m1 "Speed:" | awk '{print $2}')
        echo "Memory Type: $mem_type"
        echo "Memory Speed: $mem_speed MT/s"
    fi
    
    # Cache Information
    echo ""
    echo "Cache Configuration:"
    echo "L3 Cache Size: $((L3_SIZE_KB / 1024)) MB"
    echo "Cache Line Size: $CACHE_LINE_SIZE bytes"
    
    # NUMA Information
    if [ $NUMA_NODES -gt 1 ]; then
        echo ""
        echo "NUMA Configuration:"
        echo "Number of NUMA Nodes: $NUMA_NODES"
        if command -v numactl &> /dev/null; then
            local n cpus
            for ((n=0; n<NUMA_NODES; n++)); do
                cpus=$(get_numa_node_cpu_count "$n")
                echo "  Node $n CPUs: $cpus"
            done
            echo "NUMA Node Distances:"
            numactl --hardware | grep -A$NUMA_NODES "distances:" | tail -n +2
            echo ""
            numactl --show
        fi
    fi
    
    echo ""
    echo "=== Test Configuration ==="
    echo "Cache Test Size: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((CACHE_TEST_SIZE * 8 * 3)))"
    echo "Small Test Size: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((SMALL_TEST_SIZE * 8 * 3)))"
    echo "Standard Test Size: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((STANDARD_TEST_SIZE * 8 * 3)))"
    echo "Large Test Size: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((LARGE_TEST_SIZE * 8 * 3)))"
    
    if [ $NUMA_NODES -gt 1 ]; then
        echo "NUMA Total Test Size: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((NUMA_TEST_SIZE * 8 * 3)))"
        echo "NUMA Per Node Size: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((NUMA_PER_NODE_SIZE * 8 * 3)))"
    fi
    
    echo ""
    echo "Current System Load: $(uptime | awk -F'load average:' '{print $2}')"
    echo "Current Memory Usage: $(free -h | grep Mem | awk '{print $3 "/" $2}')"
    echo ""
}

# Create stream source code
create_stream_source() {
    # Download or create standard STREAM
    if [ ! -f "$STREAM_ORIGINAL" ]; then
        if command -v wget &> /dev/null; then
            wget -q https://www.cs.virginia.edu/stream/FTP/Code/stream.c -O "$STREAM_ORIGINAL"
        else
            log_warn "Cannot download stream.c, will create basic version"
            create_basic_stream
        fi
    fi
}

# Create stride stream source with dynamic allocation
create_stride_stream() {
    cat > "$STREAM_STRIDE" << 'EOF'
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <float.h>
#include <limits.h>
#include <sys/time.h>
#include <omp.h>

#ifndef STREAM_ARRAY_SIZE
#define STREAM_ARRAY_SIZE 10000000
#endif

#ifndef STRIDE
#define STRIDE 1
#endif

#ifndef NTIMES
#define NTIMES 10
#endif

#ifndef OFFSET
#define OFFSET 0
#endif

#define STREAM_TYPE double
#define MIN(x,y) ((x)<(y)?(x):(y))
#define MAX(x,y) ((x)>(y)?(x):(y))

static STREAM_TYPE *a, *b, *c;

static double avgtime[4] = {0}, maxtime[4] = {0},
              mintime[4] = {FLT_MAX,FLT_MAX,FLT_MAX,FLT_MAX};

static char *label[4] = {"Copy:      ", "Scale:     ", "Add:       ", "Triad:     "};

double mysecond();

int main()
{
    int         k;
    double      scalar, t, times[4][NTIMES];
    
    /* --- SETUP --- */
    printf("-------------------------------------------------------------\n");
    printf("STREAM version with Stride = %d\n", STRIDE);
    printf("Array size = %d (elements)\n", STREAM_ARRAY_SIZE);
    printf("Memory per array = %.1f MiB (= %.1f GiB).\n", 
        sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE / 1024.0/1024.0,
        sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE / 1024.0/1024.0/1024.0);
    printf("Each kernel will be executed %d times.\n", NTIMES);
    printf("Number of threads: %d\n", omp_get_max_threads());
    
    /* Allocate memory dynamically */
    a = (STREAM_TYPE*)malloc((STREAM_ARRAY_SIZE+OFFSET) * sizeof(STREAM_TYPE));
    b = (STREAM_TYPE*)malloc((STREAM_ARRAY_SIZE+OFFSET) * sizeof(STREAM_TYPE));
    c = (STREAM_TYPE*)malloc((STREAM_ARRAY_SIZE+OFFSET) * sizeof(STREAM_TYPE));
    
    if (!a || !b || !c) {
        fprintf(stderr, "Memory allocation failed!\n");
        exit(1);
    }
    
    /* Initialize arrays */
    #pragma omp parallel for
    for (int j=0; j<STREAM_ARRAY_SIZE; j++) {
        a[j] = 1.0;
        b[j] = 2.0;
        c[j] = 0.0;
    }
    
    scalar = 3.0;

    /* --- MAIN LOOP --- */
    for (k=0; k<NTIMES; k++)
    {
        times[0][k] = mysecond();
#ifdef _OPENMP
#pragma omp parallel for
#endif
        for (int j=0; j<STREAM_ARRAY_SIZE; j += STRIDE)
            c[j] = a[j];
        times[0][k] = mysecond() - times[0][k];
        
        times[1][k] = mysecond();
#ifdef _OPENMP
#pragma omp parallel for
#endif
        for (int j=0; j<STREAM_ARRAY_SIZE; j += STRIDE)
            b[j] = scalar*c[j];
        times[1][k] = mysecond() - times[1][k];
        
        times[2][k] = mysecond();
#ifdef _OPENMP
#pragma omp parallel for
#endif
        for (int j=0; j<STREAM_ARRAY_SIZE; j += STRIDE)
            c[j] = a[j]+b[j];
        times[2][k] = mysecond() - times[2][k];
        
        times[3][k] = mysecond();
#ifdef _OPENMP
#pragma omp parallel for
#endif
        for (int j=0; j<STREAM_ARRAY_SIZE; j += STRIDE)
            a[j] = b[j]+scalar*c[j];
        times[3][k] = mysecond() - times[3][k];
    }

    /* --- SUMMARY --- */
    for (k=1; k<NTIMES; k++)
    {
        for (int j=0; j<4; j++)
        {
            avgtime[j] = avgtime[j] + times[j][k];
            mintime[j] = MIN(mintime[j], times[j][k]);
            maxtime[j] = MAX(maxtime[j], times[j][k]);
        }
    }
    
    /* Adjust for stride in bandwidth calculation */
    double bytes[4] = {
        2 * sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE,
        2 * sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE,
        3 * sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE,
        3 * sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE
    };
    
    printf("Function    Best Rate MB/s  Avg time     Min time     Max time\n");
    for (int j=0; j<4; j++) {
        avgtime[j] = avgtime[j]/(double)(NTIMES-1);
        
        /* For strided access, adjust the effective bandwidth */
        double effective_size = STREAM_ARRAY_SIZE / STRIDE;
        double effective_bytes = bytes[j] / STRIDE;
        
        printf("%s%12.1f  %11.6f  %11.6f  %11.6f\n", label[j],
               1.0E-06 * effective_bytes/mintime[j],
               avgtime[j],
               mintime[j],
               maxtime[j]);
    }
    printf("-------------------------------------------------------------\n");
    
    /* Free memory */
    free(a);
    free(b);
    free(c);
    
    return 0;
}

double mysecond()
{
    struct timeval tp;
    gettimeofday(&tp, NULL);
    return ( (double) tp.tv_sec + (double) tp.tv_usec * 1.e-6 );
}
EOF

    # Also create dynamic version of original STREAM
    cat > "$STREAM_ORIGINAL" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <float.h>
#include <limits.h>
#include <sys/time.h>
#include <omp.h>

#ifndef STREAM_ARRAY_SIZE
#define STREAM_ARRAY_SIZE 10000000
#endif

#ifndef NTIMES
#define NTIMES 10
#endif

#ifndef OFFSET
#define OFFSET 0
#endif

#define STREAM_TYPE double
#define MIN(x,y) ((x)<(y)?(x):(y))
#define MAX(x,y) ((x)>(y)?(x):(y))

static STREAM_TYPE *a, *b, *c;

static double avgtime[4] = {0}, maxtime[4] = {0},
              mintime[4] = {FLT_MAX,FLT_MAX,FLT_MAX,FLT_MAX};

static char *label[4] = {"Copy:      ", "Scale:     ", "Add:       ", "Triad:     "};

/* Bytes transferred for each operation */
static double bytes[4] = {
    2 * sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE, /* Copy:  2 transfers */
    2 * sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE, /* Scale: 2 transfers */
    3 * sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE, /* Add:   3 transfers */
    3 * sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE  /* Triad: 3 transfers */
};

double mysecond();

int main()
{
    int         k;
    double      scalar, t, times[4][NTIMES];
    
    /* --- SETUP --- */
    printf("-------------------------------------------------------------\n");
    printf("STREAM version $Revision: 1.0 $\n");
    printf("Array size = %d (elements)\n", STREAM_ARRAY_SIZE);
    printf("Memory per array = %.1f MiB (= %.1f GiB).\n", 
        sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE / 1024.0/1024.0,
        sizeof(STREAM_TYPE) * STREAM_ARRAY_SIZE / 1024.0/1024.0/1024.0);
    printf("Each kernel will be executed %d times.\n", NTIMES);
    printf("Number of threads: %d\n", omp_get_max_threads());
    
    /* Allocate memory dynamically */
    a = (STREAM_TYPE*)malloc((STREAM_ARRAY_SIZE+OFFSET) * sizeof(STREAM_TYPE));
    b = (STREAM_TYPE*)malloc((STREAM_ARRAY_SIZE+OFFSET) * sizeof(STREAM_TYPE));
    c = (STREAM_TYPE*)malloc((STREAM_ARRAY_SIZE+OFFSET) * sizeof(STREAM_TYPE));
    
    if (!a || !b || !c) {
        fprintf(stderr, "Memory allocation failed!\n");
        exit(1);
    }
    
    /* Initialize arrays */
    #pragma omp parallel for
    for (int j=0; j<STREAM_ARRAY_SIZE; j++) {
        a[j] = 1.0;
        b[j] = 2.0;
        c[j] = 0.0;
    }
    
    scalar = 3.0;

    /* --- MAIN LOOP --- */
    for (k=0; k<NTIMES; k++)
    {
        times[0][k] = mysecond();
#pragma omp parallel for
        for (int j=0; j<STREAM_ARRAY_SIZE; j++)
            c[j] = a[j];
        times[0][k] = mysecond() - times[0][k];
        
        times[1][k] = mysecond();
#pragma omp parallel for
        for (int j=0; j<STREAM_ARRAY_SIZE; j++)
            b[j] = scalar*c[j];
        times[1][k] = mysecond() - times[1][k];
        
        times[2][k] = mysecond();
#pragma omp parallel for
        for (int j=0; j<STREAM_ARRAY_SIZE; j++)
            c[j] = a[j]+b[j];
        times[2][k] = mysecond() - times[2][k];
        
        times[3][k] = mysecond();
#pragma omp parallel for
        for (int j=0; j<STREAM_ARRAY_SIZE; j++)
            a[j] = b[j]+scalar*c[j];
        times[3][k] = mysecond() - times[3][k];
    }

    /* --- SUMMARY --- */
    for (k=1; k<NTIMES; k++)
    {
        for (int j=0; j<4; j++)
        {
            avgtime[j] = avgtime[j] + times[j][k];
            mintime[j] = MIN(mintime[j], times[j][k]);
            maxtime[j] = MAX(maxtime[j], times[j][k]);
        }
    }
    
    printf("Function    Best Rate MB/s  Avg time     Min time     Max time\n");
    for (int j=0; j<4; j++) {
        avgtime[j] = avgtime[j]/(double)(NTIMES-1);
        
        printf("%s%12.1f  %11.6f  %11.6f  %11.6f\n", label[j],
               1.0E-06 * bytes[j]/mintime[j],
               avgtime[j],
               mintime[j],
               maxtime[j]);
    }
    printf("-------------------------------------------------------------\n");
    
    /* Free memory */
    free(a);
    free(b);
    free(c);
    
    return 0;
}

double mysecond()
{
    struct timeval tp;
    gettimeofday(&tp, NULL);
    return ( (double) tp.tv_sec + (double) tp.tv_usec * 1.e-6 );
}
EOF
}

# Compile STREAM
compile_stream() {
    local array_size=$1
    local stride=$2
    local output_name=$3
    local compile_log="/tmp/stream_compile_$$.log"
    
    # Add error checking for array size
    if [ "$array_size" -gt 2147483647 ]; then
        log_warn "Array size too large ($array_size), reducing to maximum safe value"
        array_size=2147483647
    fi
    
    if [ "$stride" -eq 1 ]; then
        log_debug "Compiling continuous access version: $output_name (size: $array_size)"
        gcc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=$array_size "$STREAM_ORIGINAL" -o "$output_name" 2>"$compile_log"
    else
        log_debug "Compiling stride access version: $output_name (size: $array_size, stride: $stride)"
        gcc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=$array_size -DSTRIDE=$stride "$STREAM_STRIDE" -o "$output_name" 2>"$compile_log"
    fi
    
    if [ $? -eq 0 ]; then
        log_debug "Compilation successful: $output_name"
        rm -f "$compile_log"
        return 0
    else
        log_error "Compilation failed: $output_name"
        echo "Compilation error information:"
        cat "$compile_log"
        rm -f "$compile_log"
        return 1
    fi
}

# Show progress bar
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local progress=$((current * width / total))
    local percentage=$((current * 100 / total))
    
    printf "\r["
    for ((i=0; i<width; i++)); do
        if [ $i -lt $progress ]; then
            printf "="
        elif [ $i -eq $progress ]; then
            printf ">"
        else
            printf " "
        fi
    done
    printf "] %3d%%" $percentage
}

# Run single test
run_single_test() {
    local test_name=$1
    local executable=$2
    local threads=$3
    local output_file=$4
    local stride=${5:-1}
    
    # Show test information
    echo -e "\n${BLUE}Running Test: ${test_name}${NC}"
    echo "├─ Threads: $threads"
    echo "├─ Stride: $stride"
    echo "└─ Output: $(basename "$output_file")"
    
    # Set environment variables
    export OMP_NUM_THREADS=$threads
    
    # If NUMA system, set NUMA strategy
    if [ $NUMA_NODES -gt 1 ]; then
        if command -v numactl &> /dev/null; then
            # For stride=1 test, use interleave strategy
            if [ $stride -eq 1 ]; then
                numactl --interleave=all ./"$executable" > "$output_file" 2>&1
            else
                # For other strides, use local priority strategy
                numactl --localalloc ./"$executable" > "$output_file" 2>&1
            fi
        else
            ./"$executable" > "$output_file" 2>&1
        fi
    else
        ./"$executable" > "$output_file" 2>&1
    fi
    
    # Check test results
    if grep -q "Triad:" "$output_file"; then
        local copy=$(grep "Copy:" "$output_file" | awk '{print $2}')
        local scale=$(grep "Scale:" "$output_file" | awk '{print $2}')
        local add=$(grep "Add:" "$output_file" | awk '{print $2}')
        local triad=$(grep "Triad:" "$output_file" | awk '{print $2}')
        
        # Show result summary
        echo -e "\n${GREEN}Test Results:${NC}"
        printf "%-15s %12s %12s %12s %12s\n" "Operation" "Copy" "Scale" "Add" "Triad"
        printf "%-15s %12.1f %12.1f %12.1f %12.1f\n" "Bandwidth MB/s" $copy $scale $add $triad
        
        # Calculate theoretical bandwidth based on memory configuration
        local theoretical_bw
        local single_channel_bw
        
        # Try to get memory speed from dmidecode
        if command -v dmidecode &> /dev/null && [ $(id -u) -eq 0 ]; then
            local mem_speed=$(dmidecode -t memory | grep -m1 "Speed:" | awk '{print $2}')
            if [ -n "$mem_speed" ] && [ "$mem_speed" != "Unknown" ]; then
                # DDR theoretical bandwidth = memory_speed * 8 (bytes) * 2 (DDR)
                single_channel_bw=$((mem_speed * 8 * 2))
                log_debug "Using detected memory speed: ${mem_speed} MT/s"
            else
                # Default to DDR5-6400 if speed cannot be detected
                single_channel_bw=102400  # 6400 MT/s * 8 * 2
                log_debug "Using default DDR5-6400 speed"
            fi
        else
            single_channel_bw=102400  # Default to DDR5-6400
            log_debug "Using default DDR5-6400 speed (no dmidecode access)"
        fi
        
        # Adjust theoretical bandwidth based on NUMA configuration
        if [ $NUMA_NODES -gt 1 ]; then
            # Each NUMA node typically has its own memory channels
            theoretical_bw=$((single_channel_bw * NUMA_NODES))
            log_debug "Adjusted bandwidth for $NUMA_NODES NUMA nodes: $theoretical_bw MB/s"
        else
            theoretical_bw=$single_channel_bw
        fi
        
        # Calculate efficiency percentage
        local triad_efficiency=$(echo "scale=2; $triad * 100 / $theoretical_bw" | bc)
        echo -e "\nTheoretical Peak Bandwidth: ${theoretical_bw} MB/s (${NUMA_NODES} NUMA node(s))"
        echo -e "Bandwidth Efficiency: ${YELLOW}${triad_efficiency}%${NC} of theoretical maximum"
        
        return 0
    else
        log_error "Test failed: $test_name"
        echo -e "${RED}Last few lines of output:${NC}"
        tail -n 5 "$output_file"
        return 1
    fi
}

# Function to generate text-based summary report
generate_text_summary() {
    local suite_dir=$1
    local csv_file="$suite_dir/results.csv"
    local summary_file="$suite_dir/text_summary.txt"
    
    {
        echo "============================================"
        echo "       Memory Performance Summary Report     "
        echo "============================================"
        echo "Generated: $(date)"
        echo ""
        
        echo "1. Thread Scaling Performance (Stride=1)"
        echo "--------------------------------------------"
        echo "Threads  Copy      Scale     Add       Triad"
        awk -F',' 'NR>1 && $1==1 {
            printf "%-8s %-9.1f %-9.1f %-9.1f %-9.1f\n", 
                $2, $3, $4, $5, $6
        }' "$csv_file" | sort -n -k1
        
        echo ""
        echo "2. Memory Access Pattern Performance (MB/s)"
        echo "--------------------------------------------"
        
        # Get unique thread counts
        thread_counts=$(awk -F',' 'NR>1 {print $2}' "$csv_file" | sort -n | uniq)
        
        # For each thread count
        for threads in $thread_counts; do
            echo ""
            echo "Thread Count: $threads"
            echo "Stride   Copy      Scale     Add       Triad"
            echo "--------------------------------------------"
            
            # Create a temporary file for sorting
            local temp_file=$(mktemp)
            
            # First, extract and save all results for this thread count
            awk -F',' -v threads="$threads" '
            NR>1 && $2==threads {
                printf "%d %-9.1f %-9.1f %-9.1f %-9.1f\n",
                    $1, $3, $4, $5, $6
            }' "$csv_file" > "$temp_file"
            
            # Sort numerically by stride and format output
            sort -n "$temp_file" | while read stride copy scale add triad; do
                printf "%-8d %-9.1f %-9.1f %-9.1f %-9.1f\n" \
                    "$stride" "$copy" "$scale" "$add" "$triad"
            done
            
            # Clean up temporary file
            rm -f "$temp_file"
        done
        
        # If this is a NUMA system, add NUMA information
        if [ $NUMA_NODES -gt 1 ]; then
            echo ""
            echo "3. NUMA Configuration"
            echo "--------------------------------------------"
            echo "Number of NUMA Nodes: $NUMA_NODES"
            echo ""
            echo "NUMA Distance Matrix:"
            numactl --hardware | grep -A$NUMA_NODES "distances:" | tail -n +2
            echo ""
            numactl --show
        fi
        
    } > "$summary_file"
    
    echo -e "${GREEN}Text summary generated: $summary_file${NC}"
    cat "$summary_file"
}

# Run complete test suite
run_test_suite() {
    local array_size=$1
    local size_name=$2
    local strides=$3
    local thread_counts=$4
    
    log_info "Starting test suite: $size_name (Array size: $array_size)"
    
    local suite_dir="$RESULTS_DIR/${size_name}_results"
    mkdir -p "$suite_dir"
    
    # CSV results file
    local csv_file="$suite_dir/results.csv"
    echo "Stride,Threads,Copy_MB/s,Scale_MB/s,Add_MB/s,Triad_MB/s" > "$csv_file"
    
    # Debug: Show test parameters
    log_debug "Test Parameters:"
    log_debug "Array size: $array_size"
    log_debug "Strides to test: $strides"
    log_debug "Thread counts to test: $thread_counts"
    
    # Run all combinations of stride and thread counts
    for threads in $thread_counts; do
        log_debug "Testing with thread count: $threads"
        for stride in $strides; do
            log_debug "Running test: stride=$stride, threads=$threads"
            
            local test_name="array${array_size}_stride${stride}_threads${threads}"
            local executable="stream_${test_name}"
            local output_file="$suite_dir/${test_name}.txt"
            
            # Compile
            compile_stream $array_size $stride "$executable"
            if [ $? -eq 0 ]; then
                # Run test
                run_single_test "$test_name" "$executable" $threads "$output_file" $stride
                
                # Extract and save results
                if [ -f "$output_file" ]; then
                    copy=$(grep "Copy:" "$output_file" | awk '{print $2}')
                    scale=$(grep "Scale:" "$output_file" | awk '{print $2}')
                    add=$(grep "Add:" "$output_file" | awk '{print $2}')
                    triad=$(grep "Triad:" "$output_file" | awk '{print $2}')
                    
                    # Debug: Show results being written
                    log_debug "Writing results to CSV: $stride,$threads,$copy,$scale,$add,$triad"
                    echo "$stride,$threads,$copy,$scale,$add,$triad" >> "$csv_file"
                else
                    log_error "Output file not found: $output_file"
                fi
                
                rm -f "$executable"
            fi
        done
    done
    
    # Debug: Show final CSV contents
    log_debug "Final CSV contents:"
    cat "$csv_file"
    
    # Generate text-based summary
    generate_text_summary "$suite_dir"
    
    echo -e "\n${GREEN}Test suite completed: $size_name${NC}"
}

# Top-level menu (Chinese)
show_main_menu() {
    echo ""
    echo "=========================================="
    echo "       内存性能测试"
    echo "=========================================="
    echo "1. 自动化内存性能测试"
    echo "   - 自动采集系统内存/Cache/NUMA 信息"
    echo "   - 自动设置数据大小并运行四种运算"
    echo "   - 先单 NUMA 节点，再跨 NUMA 节点"
    echo ""
    echo "2. 手动内存性能测试"
    echo "   - 手动指定数据大小、线程数"
    echo "   - 选择单 NUMA 或跨 NUMA 测试"
    echo ""
    echo "3. 退出"
    echo "=========================================="
    echo -n "请选择 (1-3): "
}

# Count CPUs listed in sysfs cpulist format (e.g. "0-15" or "0-7,16-23")
count_cpulist() {
    local list=$1
    local count=0 part start end
    IFS=',' read -ra parts <<< "$list"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            start=${part%-*}
            end=${part#*-}
            count=$((count + end - start + 1))
        elif [ -n "$part" ]; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

get_numa_node_ids() {
    local node_ids

    node_ids=$(numactl --all --show 2>/dev/null |
        awk "/^(cpubind|membind):/ {for (i=2; i<=NF; i++) if (\$i ~ /^[0-9]+\$/) print \$i}" |
        sort -nu)

    if [ -z "$node_ids" ]; then
        node_ids=$(find /sys/devices/system/node -maxdepth 1 -type d -name "node[0-9]*" 2>/dev/null |
            sed "s/.*node//" | sort -nu)
    fi

    if [ -z "$node_ids" ]; then
        node_ids=$(numactl --hardware 2>/dev/null |
            sed -n "s/^node \([0-9][0-9]*\) .*/\1/p" |
            sort -nu)
    fi

    echo "$node_ids"
}

is_numa_cpu_node() {
    command -v numactl &> /dev/null &&
        numactl --all --cpunodebind="$1" true > /dev/null 2>&1
}

is_numa_mem_node() {
    command -v numactl &> /dev/null &&
        numactl --all --cpunodebind="${2:-$1}" --membind="$1" true > /dev/null 2>&1
}

# Total logical CPUs on the system (prefer lscpu over nproc to avoid cgroup limits)
get_system_cpu_count() {
    local cpus

    cpus=$(lscpu 2>/dev/null | awk '/^CPU\(s\):/ {print $2; exit}')
    if [ -n "$cpus" ] && [ "$cpus" -gt 0 ] 2>/dev/null; then
        echo "$cpus"
        return
    fi

    cpus=$(nproc 2>/dev/null)
    if [ -n "$cpus" ] && [ "$cpus" -gt 0 ] 2>/dev/null; then
        echo "$cpus"
        return
    fi

    echo 1
}

# CPUs bound to a NUMA node (from sysfs, independent of cgroup CPU limit)
get_numa_node_cpu_count() {
    local node_id=${1:-0}
    local cpulist_file="/sys/devices/system/node/node${node_id}/cpulist"

    if [ -f "$cpulist_file" ]; then
        count_cpulist "$(tr -d '[:space:]' < "$cpulist_file")"
        return
    fi

    if command -v numactl &> /dev/null; then
        numactl --hardware 2>/dev/null | awk -v n="$node_id" '
            $1 == "node" && $2 == (n ":") {
                count = 0
                for (i = 4; i <= NF; i++) {
                    if ($i ~ /^[0-9]+-[0-9]+$/) {
                        split($i, r, "-")
                        count += r[2] - r[1] + 1
                    } else if ($i ~ /^[0-9]+$/) {
                        count++
                    }
                }
                print count
                exit
            }'
        return
    fi

  # Fallback: even split across NUMA nodes
    local per=$((CORES / NUMA_NODES))
    [ "$per" -lt 1 ] && per=1
    echo "$per"
}

# Read actual OpenMP thread count from STREAM output
extract_stream_threads() {
    local output_file=$1
    local threads

    threads=$(grep -E "Number of threads:" "$output_file" 2>/dev/null | tail -1 | awk '{print $NF}')
    if [ -n "$threads" ] && [ "$threads" -gt 0 ] 2>/dev/null; then
        echo "$threads"
        return
    fi

    echo ""
}

# Get free memory (KB) for a NUMA node, fallback to system available memory
get_numa_node_free_kb() {
    local node_id=${1:-0}
    local free_kb=""

    if [ -f "/sys/devices/system/node/node${node_id}/meminfo" ]; then
        free_kb=$(awk '/MemFree:/ {print $4}' "/sys/devices/system/node/node${node_id}/meminfo")
    fi

    if [ -z "$free_kb" ] || [ "$free_kb" -le 0 ]; then
        free_kb=$AVAIL_MEM_KB
    fi
    echo "$free_kb"
}

# Compute safe STREAM array size (elements) from available memory
# STREAM uses 3 double arrays; keep a conservative margin to avoid OOM kill
compute_safe_array_size() {
    local mode=${1:-global}
    local node_id=${2:-0}
    local mem_kb limit_kb array_size max_elements=268435456
    local usage_pct=35

    case "$mode" in
        intra)
            mem_kb=$(get_numa_node_free_kb "$node_id")
            usage_pct=35
            ;;
        cross)
            mem_kb=$(get_numa_node_free_kb "$node_id")
            usage_pct=25
            ;;
        *)
            mem_kb=${AVAIL_MEM_KB:-$TOTAL_MEM_KB}
            usage_pct=40
            ;;
    esac

    limit_kb=$((mem_kb * usage_pct / 100))
    array_size=$((limit_kb * 1024 / (3 * 8)))

    if [ -n "${SMALL_TEST_SIZE:-}" ] && [ "$array_size" -lt "$SMALL_TEST_SIZE" ]; then
        array_size=$SMALL_TEST_SIZE
    fi

    if [ "$array_size" -gt "$max_elements" ]; then
        array_size=$max_elements
    fi

    if [ "$array_size" -le 0 ]; then
        array_size=${STANDARD_TEST_SIZE:-$((64 * 1024 * 1024 / (3 * 8)))}
    fi

    echo "$array_size"
}

# Minimum array size so working set (3 double arrays) exceeds LLC by MEMORY_BW_L3_FACTOR
compute_dram_min_array_size() {
    local factor=${MEMORY_BW_L3_FACTOR:-8}
    local llc_size_kb=${LLC_SIZE_KB:-$L3_SIZE_KB}
    local llc_bytes=$((llc_size_kb * 1024))
    echo $((factor * llc_bytes / (3 * 8)))
}

# Array size for DRAM bandwidth test: at least 8x L3 working set, capped by free memory
compute_memory_bw_array_size() {
    local mode=${1:-intra}
    local node_id=${2:-0}
    local dram_min safe_max target

    dram_min=$(compute_dram_min_array_size)
    safe_max=$(compute_safe_array_size "$mode" "$node_id")

    target=$dram_min
    if [ -n "${STANDARD_TEST_SIZE:-}" ] && [ "$target" -lt "$STANDARD_TEST_SIZE" ]; then
        target=$STANDARD_TEST_SIZE
    fi

    if [ "$target" -gt "$safe_max" ]; then
        log_warn "可用内存不足，数据块从 $(format_array_footprint "$target") 降至 $(format_array_footprint "$safe_max")"
        target=$safe_max
    fi

    if [ -n "${SMALL_TEST_SIZE:-}" ] && [ "$target" -lt "$SMALL_TEST_SIZE" ]; then
        target=$SMALL_TEST_SIZE
    fi

    echo "$target"
}

# Format STREAM array footprint (3 x double arrays)
format_array_footprint() {
    local elements=$1
    if command -v numfmt &> /dev/null; then
        numfmt --to=iec-i --suffix=B --format="%.2f" $((elements * 8 * 3))
    else
        echo "$(echo "scale=2; $elements * 8 * 3 / 1024 / 1024 / 1024" | bc) GB"
    fi
}

# Run STREAM four operations (Copy/Scale/Add/Triad) with optional NUMA binding
run_four_ops_bound() {
    local array_size=$1
    local threads=$2
    local suite_name=$3
    local bind_mode=$4
    local cpu_node=${5:-0}
    local mem_node=${6:-0}
    local stride=${7:-1}
    local run_id=${8:-1}

    if [ "$bind_mode" != "none" ]; then
        if ! is_numa_cpu_node "$cpu_node"; then
            log_error "CPU NUMA 节点不可用: $cpu_node"
            return 1
        fi
        if ! is_numa_mem_node "$mem_node"; then
            log_error "内存 NUMA 节点不可用: $mem_node"
            return 1
        fi
    fi

    if [ -z "$threads" ] || [ "$threads" -lt 1 ] 2>/dev/null; then
        case "$bind_mode" in
            intra|cross) threads=$(get_numa_node_cpu_count "$cpu_node") ;;
            *) threads=$(get_system_cpu_count) ;;
        esac
    fi
    [ "$threads" -lt 1 ] && threads=1

    local suite_dir="$RESULTS_DIR/${suite_name}_results"
    mkdir -p "$suite_dir"
    local csv_file="$suite_dir/results.csv"
    if [ ! -f "$csv_file" ]; then
        echo "Stride,Threads,Copy_MB/s,Scale_MB/s,Add_MB/s,Triad_MB/s,Mode" > "$csv_file"
    fi

    local test_name="${suite_name}_array${array_size}_stride${stride}_threads${threads}"
    local executable="stream_${test_name}_run${run_id}"
    local output_file="$suite_dir/${test_name}_run${run_id}.txt"
    local used_array_size=$array_size

    log_info "运行测试: $suite_name (数据大小=${array_size} 元素, 线程=${threads}, 模式=${bind_mode})"

    compile_stream "$array_size" "$stride" "$executable"
    if [ $? -ne 0 ]; then
        log_error "编译失败，跳过测试: $suite_name"
        return 1
    fi

    export OMP_NUM_THREADS=$threads
    local run_exit=0
    case "$bind_mode" in
        intra)
            numactl --all --cpunodebind="$cpu_node" --membind="$mem_node" ./"$executable" > "$output_file" 2>&1
            run_exit=$?
            ;;
        cross)
            numactl --all --cpunodebind="$cpu_node" --membind="$mem_node" ./"$executable" > "$output_file" 2>&1
            run_exit=$?
            ;;
        *)
            ./"$executable" > "$output_file" 2>&1
            run_exit=$?
            ;;
    esac

    # OOM kill (SIGKILL=137): retry once with half array size
    if { [ "$run_exit" -eq 137 ] || grep -qi "killed" "$output_file" 2>/dev/null; } && \
       ! grep -q "Triad:" "$output_file" 2>/dev/null; then
        local retry_size=$((array_size / 2))
        if [ "$retry_size" -ge "${SMALL_TEST_SIZE:-1}" ]; then
            log_warn "内存不足，数据大小从 ${array_size} 降至 ${retry_size} 后重试"
            rm -f "$executable"
            local retry_name="${suite_name}_retry"
            local retry_exec="stream_${retry_name}"
            compile_stream "$retry_size" "$stride" "$retry_exec" || return 1
            used_array_size=$retry_size
            case "$bind_mode" in
                intra) numactl --all --cpunodebind="$cpu_node" --membind="$mem_node" ./"$retry_exec" > "$output_file" 2>&1 ;;
                cross) numactl --all --cpunodebind="$cpu_node" --membind="$mem_node" ./"$retry_exec" > "$output_file" 2>&1 ;;
                *) ./"$retry_exec" > "$output_file" 2>&1 ;;
            esac
            rm -f "$retry_exec"
        fi
    fi

    if grep -q "Triad:" "$output_file"; then
        local copy scale add triad actual_threads
        copy=$(grep "Copy:" "$output_file" | awk '{print $2}')
        scale=$(grep "Scale:" "$output_file" | awk '{print $2}')
        add=$(grep "Add:" "$output_file" | awk '{print $2}')
        triad=$(grep "Triad:" "$output_file" | awk '{print $2}')
        actual_threads=$(extract_stream_threads "$output_file")
        [ -z "$actual_threads" ] && actual_threads=$threads

        {
            echo "THREADS=$actual_threads"
            echo "ARRAY_SIZE=$used_array_size"
            echo "MODE=$bind_mode"
            echo "CPU_NODE=$cpu_node"
            echo "MEM_NODE=$mem_node"
            echo "STRIDE=$stride"
        } > "$suite_dir/test_meta.env"

        echo "$stride,$actual_threads,$copy,$scale,$add,$triad,$bind_mode" >> "$csv_file"

        echo ""
        echo "【${suite_name}】四种运算带宽 (MB/s):"
        printf "  %-10s %12s\n" "线程数" "$actual_threads"
        printf "  %-10s %12s\n" "Copy" "$copy"
        printf "  %-10s %12s\n" "Scale" "$scale"
        printf "  %-10s %12s\n" "Add" "$add"
        printf "  %-10s %12s\n" "Triad" "$triad"
        echo ""
    else
        log_error "测试失败: $suite_name"
        tail -n 5 "$output_file"
    fi

    rm -f "$executable"
    generate_text_summary "$suite_dir"
}

# Print consolidated memory performance report
print_memory_performance_report() {
    echo ""
    echo "=============================================="
    echo "           内存性能测试结果汇总"
    echo "=============================================="
    echo "结果目录: $RESULTS_DIR"
    echo ""

    local found=0
    while IFS= read -r csv_file; do
        found=1
        local suite_dir
        suite_dir=$(dirname "$csv_file")
        local meta_threads="" meta_array="" meta_mode=""
        if [ -f "$suite_dir/test_meta.env" ]; then
            # shellcheck disable=SC1090
            source "$suite_dir/test_meta.env"
            meta_threads=$THREADS
            meta_array=$ARRAY_SIZE
            meta_mode=$MODE
        fi

        echo "----------------------------------------------"
        echo "测试项: $(basename "$suite_dir")"
        echo "----------------------------------------------"
        if [ -n "$meta_threads" ]; then
            printf "  线程数:     %s\n" "$meta_threads"
            if [ -n "$meta_array" ]; then
                printf "  数据大小:   %s 元素 (约 %s)\n" "$meta_array" "$(format_array_footprint "$meta_array")"
            fi
            awk -F',' 'NR>1 && $1==1 {copy=$3; scale=$4; add=$5; triad=$6; mode=$7} END {
                if (copy != "") {
                    printf "  Copy:       %s MB/s\n", copy
                    printf "  Scale:      %s MB/s\n", scale
                    printf "  Add:        %s MB/s\n", add
                    printf "  Triad:      %s MB/s\n", triad
                }
            }' "$csv_file"
            if [ -n "$meta_mode" ]; then
                printf "  模式:       %s\n" "$meta_mode"
            fi
            echo ""
        else
            awk -F',' 'NR>1 && $1==1 {
                printf "  线程数:     %s\n", $2
                printf "  Copy:       %s MB/s\n", $3
                printf "  Scale:      %s MB/s\n", $4
                printf "  Add:        %s MB/s\n", $5
                printf "  Triad:      %s MB/s\n", $6
                if ($7 != "") printf "  模式:       %s\n", $7
                print ""
            }' "$csv_file"
        fi
        if [ -f "$suite_dir/text_summary.txt" ]; then
            echo "  详细报告: $suite_dir/text_summary.txt"
        fi
    done < <(find "$RESULTS_DIR" -name "results.csv" | sort)

    if [ $found -eq 0 ]; then
        log_warn "未找到测试结果文件"
    fi
    echo "=============================================="
}

# Compare repeated runs in every results.csv. Spread is (max-min)/mean.
write_repeatability_summary() {
    local results_dir=${1:-$RESULTS_DIR}
    local summary_file="$results_dir/repeatability_summary.txt"
    local status_file="$results_dir/repeatability_status.txt"
    local tolerance=${REPEAT_TOLERANCE_PCT:-5}
    local required_runs=${REPEAT_RUNS:-3}
    local overall_status=0
    local found=0
    local csv_file

    {
        echo "=============================================="
        echo "             Repeatability Summary"
        echo "=============================================="
        echo "Generated: $(date)"
        echo "Required runs: $required_runs"
        echo "Tolerance: max-min <= ${tolerance}% of mean for Copy/Scale/Add/Triad"
        echo ""
        while IFS= read -r csv_file; do
            found=1
            echo "Suite: $(basename "$(dirname "$csv_file")")"
            awk -F, -v tolerance="$tolerance" -v required="$required_runs" '
                NR>1 && NF>=7 && $1 != "" {
                    key = $1 SUBSEP $7
                    count[key]++
                    for (op=1; op<=4; op++)
                        value[key, count[key], op] = $(op+2)
                }
                END {
                    fail = 0
                    split("Copy Scale Add Triad", operation, " ")
                    for (key in count) {
                        split(key, parts, SUBSEP)
                        printf "  Stride=%s Mode=%s Runs=%d\n", parts[1], parts[2], count[key]
                        for (op=1; op<=4; op++) {
                            sum=0; minimum=""; maximum=""
                            for (run=1; run<=count[key]; run++) {
                                current=value[key, run, op] + 0
                                sum += current
                                if (minimum == "" || current < minimum) minimum=current
                                if (maximum == "" || current > maximum) maximum=current
                            }
                            mean=sum/count[key]
                            spread=(maximum-minimum)*100.0/mean
                            status=(count[key] >= required && spread <= tolerance) ? "PASS" : "FAIL"
                            if (status == "FAIL") fail=1
                            printf "    %-6s mean=%10.1f min=%10.1f max=%10.1f spread=%6.2f%% %s\n", operation[op], mean, minimum, maximum, spread, status
                        }
                    }
                    exit fail
                }' "$csv_file"
            [ $? -ne 0 ] && overall_status=1
            echo ""
        done < <(find "$results_dir" -name "results.csv" | sort)

        [ "$found" -eq 0 ] && overall_status=1
        [ "$found" -eq 0 ] && echo "No results.csv files found."
    } > "$summary_file"

    if [ "$overall_status" -eq 0 ]; then
        echo "PASS" > "$status_file"
    else
        echo "FAIL" > "$status_file"
    fi
    cat "$summary_file"
    return "$overall_status"
}

# Automated memory performance test
automated_memory_test() {
    echo ""
    echo "=========================================="
    echo "       自动化内存性能测试"
    echo "=========================================="

    get_numa_info

    echo ""
    echo ">>> 第一步: 系统硬件信息"
    show_system_summary

    local intra_size intra_threads inter_size inter_threads
    local cross_cpu="" cross_mem=1
    local remote_nodes=""
    local strides="${AUTOMATED_STRIDES:-1 4}"
    local stride failed_tests=0
    local -a numa_node_ids=()
    local node_id
    read -ra numa_node_ids <<< "$(get_numa_node_ids)"

    if [ "$NUMA_NODES" -gt 1 ] && command -v numactl &> /dev/null; then
        for node_id in "${numa_node_ids[@]}"; do
            if is_numa_cpu_node "$node_id"; then
                cross_cpu=$node_id
                break
            fi
        done

        if [ -z "$cross_cpu" ]; then
            log_error "未找到当前进程可绑定的 CPU NUMA 节点"
            return 1
        fi

        intra_size=$(compute_memory_bw_array_size intra "$cross_cpu")
        intra_threads=$(get_numa_node_cpu_count "$cross_cpu")
        for node_id in "${numa_node_ids[@]}"; do
            [ "$node_id" -eq "$cross_cpu" ] && continue
            if is_numa_mem_node "$node_id" "$cross_cpu"; then
                remote_nodes="$remote_nodes $node_id"
            else
                log_warn "跳过不可用的内存 NUMA 节点: $node_id"
            fi
        done
        inter_threads=$(get_numa_node_cpu_count "$cross_cpu")

        if [ -z "$remote_nodes" ]; then
            log_warn "NUMA 预检未选中远端节点，改用 numactl --all --show 的 membind 列表"
            for node_id in "${numa_node_ids[@]}"; do
                [ "$node_id" -eq "$cross_cpu" ] && continue
                remote_nodes="$remote_nodes $node_id"
            done
        fi

        if [ -z "$remote_nodes" ]; then
            log_error "硬件报告 ${NUMA_NODES} 个 NUMA 节点，但没有可用的远端内存节点"
            return 1
        fi
    else
        intra_size=$(compute_memory_bw_array_size global)
        intra_threads=$(get_system_cpu_count)
        inter_size=""
        inter_threads=""
    fi

    local dram_min l3_ratio
    dram_min=$(compute_dram_min_array_size)
    l3_ratio=$(echo "scale=1; $intra_size * 8 * 3 / ($LLC_SIZE_KB * 1024)" | bc 2>/dev/null || echo "N/A")

    echo ">>> 第二步: 自动测试参数"
    echo "  说明: 内存带宽测试工作集 >= max(8×每节点LLC, 标准512MiB)，由可用内存上限约束"
    echo "  L3 Cache:   $((L3_SIZE_KB / 1024)) MB (全部节点)"
    echo "  每节点 LLC: $((LLC_SIZE_KB / 1024)) MB | 推荐最小数据块: $(format_array_footprint "$dram_min") (8×每节点LLC)"
    echo "  Strides:    $strides"
    echo "  Runs:       $REPEAT_RUNS (容差: ${REPEAT_TOLERANCE_PCT}%)"
    echo "  [单 NUMA 节点]"
    echo "    数据大小:   $intra_size 元素 (约 $(format_array_footprint $intra_size), 约为 L3 的 ${l3_ratio} 倍)"
    echo "    可用内存:   节点${cross_cpu:-0}约 $(echo "scale=1; $(get_numa_node_free_kb "${cross_cpu:-0}") / 1024 / 1024" | bc) GB"
    echo "    线程数:     $intra_threads (节点${cross_cpu:-0}全部逻辑CPU，测本地内存峰值带宽)"
    echo "    NUMA 节点:  ${cross_cpu:-0} (CPU+内存绑定)"
    for cross_mem in $remote_nodes; do
        inter_size=$(compute_memory_bw_array_size cross "$cross_mem")
        echo "  [跨 NUMA 节点: ${cross_cpu} -> ${cross_mem}]"
        echo "    数据大小:   $inter_size 元素 (约 $(format_array_footprint $inter_size))"
        echo "    线程数:     $inter_threads (CPU节点${cross_cpu}全部逻辑CPU，测远端内存带宽)"
        echo "    绑定方式:   CPU@节点${cross_cpu} + 内存@节点${cross_mem}"
    done
    echo "    运算类型:   Copy / Scale / Add / Triad (stride=${strides})"
    echo ""

    echo ">>> 第三步: 单 NUMA 节点性能测试"
    for stride in $strides; do
        echo "  Stride $stride"
        for run_id in $(seq 1 "$REPEAT_RUNS"); do
            if [ "$NUMA_NODES" -gt 1 ] && command -v numactl &> /dev/null; then
                if ! run_four_ops_bound "$intra_size" "$intra_threads" "auto_intra_numa${cross_cpu:-0}" "intra" "${cross_cpu:-0}" "${cross_cpu:-0}" "$stride" "$run_id"; then
                    failed_tests=$((failed_tests + 1))
                fi
            else
                if ! run_four_ops_bound "$intra_size" "$intra_threads" "auto_intra" "none" 0 0 "$stride" "$run_id"; then
                    failed_tests=$((failed_tests + 1))
                fi
            fi
        done
    done

    if [ "$NUMA_NODES" -gt 1 ] && command -v numactl &> /dev/null; then
        for cross_mem in $remote_nodes; do
            inter_size=$(compute_memory_bw_array_size cross "$cross_mem")
            for stride in $strides; do
                echo ">>> 第四步: 跨 NUMA 节点性能测试 (${cross_cpu} -> ${cross_mem}, stride ${stride})"
                for run_id in $(seq 1 "$REPEAT_RUNS"); do
                    if ! run_four_ops_bound "$inter_size" "$inter_threads" "auto_inter_numa${cross_cpu}_to_${cross_mem}" "cross" "$cross_cpu" "$cross_mem" "$stride" "$run_id"; then
                        failed_tests=$((failed_tests + 1))
                    fi
                done
            done
        done
    fi

    echo ">>> 第五步: 输出重复性和性能汇总"
    if ! write_repeatability_summary "$RESULTS_DIR"; then
        failed_tests=$((failed_tests + 1))
    fi
    print_memory_performance_report

    if [ "$failed_tests" -ne 0 ]; then
        log_error "自动化测试完成，但有 ${failed_tests} 个测试项未通过"
        return 1
    fi
    log_info "自动化内存性能测试完成"
}

# Manual memory performance test
manual_memory_test() {
    echo ""
    echo "=========================================="
    echo "       手动内存性能测试"
    echo "=========================================="

    get_numa_info
    show_system_summary

    echo "参考数据大小 (元素个数):"
    echo "  Cache:    $CACHE_TEST_SIZE  (约 $(format_array_footprint $CACHE_TEST_SIZE))"
    echo "  Small:    $SMALL_TEST_SIZE  (约 $(format_array_footprint $SMALL_TEST_SIZE))"
    echo "  Standard: $STANDARD_TEST_SIZE  (约 $(format_array_footprint $STANDARD_TEST_SIZE))"
    echo "  Large:    $LARGE_TEST_SIZE  (约 $(format_array_footprint $LARGE_TEST_SIZE))"
    if [ "$NUMA_NODES" -gt 1 ]; then
        echo "  单NUMA:   ${ARRAY_SIZE_PER_NUMA:-$NUMA_PER_NODE_SIZE}  (约 $(format_array_footprint ${ARRAY_SIZE_PER_NUMA:-$NUMA_PER_NODE_SIZE}))"
        echo "  跨NUMA:   ${NUMA_TEST_SIZE:-$STANDARD_TEST_SIZE}  (约 $(format_array_footprint ${NUMA_TEST_SIZE:-$STANDARD_TEST_SIZE}))"
    fi
    echo ""

    read -p "请输入数据大小 (数组元素个数): " custom_size
    if ! [[ "$custom_size" =~ ^[0-9]+$ ]] || [ "$custom_size" -le 0 ]; then
        log_error "无效的数据大小"
        return 1
    fi

    read -p "请输入线程数 (1-$CORES): " custom_threads
    if ! [[ "$custom_threads" =~ ^[0-9]+$ ]] || [ "$custom_threads" -le 0 ] || [ "$custom_threads" -gt "$CORES" ]; then
        log_error "无效的线程数"
        return 1
    fi

    echo ""
    echo "请选择 NUMA 测试模式:"
    echo "1. 单 NUMA 节点 (CPU 与内存在同一节点)"
    echo "2. 跨 NUMA 节点 (CPU 与内存分布在不同节点)"
    read -p "请选择 (1-2): " numa_choice

    case $numa_choice in
        1)
            local node_id=0
            if [ "$NUMA_NODES" -gt 1 ]; then
                read -p "NUMA 节点编号 (0-$((NUMA_NODES - 1)), 默认 0): " node_id
                node_id=${node_id:-0}
            fi
            if [ "$NUMA_NODES" -gt 1 ] && command -v numactl &> /dev/null; then
                run_four_ops_bound "$custom_size" "$custom_threads" "manual_intra_numa${node_id}" "intra" "$node_id" "$node_id"
            else
                run_four_ops_bound "$custom_size" "$custom_threads" "manual_intra" "none"
            fi
            ;;
        2)
            if [ "$NUMA_NODES" -le 1 ] || ! command -v numactl &> /dev/null; then
                log_error "当前系统不支持跨 NUMA 测试"
                return 1
            fi
            local src_node=0 dst_node=1
            read -p "CPU 所在 NUMA 节点 (默认 0): " src_node
            src_node=${src_node:-0}
            read -p "内存所在 NUMA 节点 (默认 1): " dst_node
            dst_node=${dst_node:-1}
            run_four_ops_bound "$custom_size" "$custom_threads" "manual_inter_numa${src_node}_to_${dst_node}" "cross" "$src_node" "$dst_node"
            ;;
        *)
            log_error "无效选项"
            return 1
            ;;
    esac

    print_memory_performance_report
    log_info "手动内存性能测试完成"
}

# Legacy detailed menu (kept for reference, not used in main flow)
show_menu() {
    echo "=== Memory Bandwidth Test Options ==="
    echo "1. Standard Test (Recommended)"
    echo "   - Tests with different thread counts"
    echo "   - Multiple array sizes"
    echo "   - Various stride values"
    echo ""
    echo "2. Stride Comparison Test"
    echo "   - Focus on memory access patterns"
    echo "   - Tests different stride values"
    echo ""
    echo "3. Thread Scaling Test"
    echo "   - Focus on thread scaling"
    echo "   - Tests performance vs thread count"
    echo ""
    echo "4. NUMA-Specific Test"
    echo "   - For NUMA systems only"
    echo "   - Tests inter/intra node bandwidth"
    echo ""
    echo "5. Custom Test"
    echo "   - Define your own parameters"
    echo ""
    echo "6. View Previous Results"
    echo "7. Exit"
    echo "==============================="
    echo -n "Please select an option (1-7): "
}

# Function to display system information
display_system_info() {
    echo -e "\n${BLUE}System Information Summary${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    echo -e "${GREEN}CPU Information:${NC}"
    echo "Model: $CPU_MODEL"
    echo "Total Cores: $CORES"
    echo "L3 Cache: $((L3_SIZE_KB / 1024)) MB"
    echo "NUMA Nodes: $NUMA_NODES"
    
    echo -e "\n${GREEN}Memory Information:${NC}"
    echo "Total Memory: $(echo "scale=2; $TOTAL_MEM_KB / 1024 / 1024" | bc) GB"
    echo "Available Memory: $(echo "scale=2; $AVAIL_MEM_KB / 1024 / 1024" | bc) GB"
    
    # Display memory type and speed if available
    if command -v dmidecode &> /dev/null && [ $(id -u) -eq 0 ]; then
        echo -e "\n${GREEN}Memory Configuration:${NC}"
        dmidecode -t memory | grep -E "Type:|Speed:" | grep -v "Unknown" | sort | uniq
    fi
    echo -e "${YELLOW}----------------------------------------${NC}\n"
}

# Function to get NUMA information
get_numa_info() {
    if [ $NUMA_NODES -gt 1 ] && command -v numactl &> /dev/null; then
        export CORES_PER_NUMA=$(get_numa_node_cpu_count 0)
        [ "$CORES_PER_NUMA" -lt 1 ] && export CORES_PER_NUMA=1
        log_debug "Cores per NUMA node: $CORES_PER_NUMA"
        
        # Get memory per NUMA node (in KB) and free memory on node 0
        export MEM_PER_NUMA=$((TOTAL_MEM_KB / NUMA_NODES))
        local node0_free_kb
        node0_free_kb=$(get_numa_node_free_kb 0)
        log_debug "Memory per NUMA node: $((MEM_PER_NUMA / 1024 / 1024)) GB"
        log_debug "NUMA node 0 free memory: $((node0_free_kb / 1024 / 1024)) GB"

        export ARRAY_SIZE_PER_NUMA=$(compute_memory_bw_array_size intra 0)
        log_debug "Memory bandwidth array size per NUMA: $ARRAY_SIZE_PER_NUMA elements"
    else
        export CORES_PER_NUMA=$(get_system_cpu_count)
    fi
}

# Function to run intra-NUMA tests
run_intra_numa_test() {
    # Only test NUMA node 0
    local node_id=0
    local size_name=$2
    local array_size=$3
    local strides=$4
    
    log_info "Running intra-NUMA test on node $node_id"
    
    # Generate thread counts as powers of 2 up to CORES_PER_NUMA
    local thread_counts="1"
    local current_threads=2
    while [ $current_threads -le $CORES_PER_NUMA ]; do
        thread_counts="$thread_counts $current_threads"
        current_threads=$((current_threads * 2))
    done
    
    # Add CORES_PER_NUMA if not already included
    if ! echo $thread_counts | grep -w "$CORES_PER_NUMA" > /dev/null; then
        thread_counts="$thread_counts $CORES_PER_NUMA"
    fi
    
    local suite_dir="$RESULTS_DIR/numa${node_id}_${size_name}_results"
    mkdir -p "$suite_dir"
    
    # Run tests with numactl binding
    for stride in $strides; do
        for threads in $thread_counts; do
            local test_name="numa${node_id}_array${array_size}_stride${stride}_threads${threads}"
            local executable="stream_${test_name}"
            local output_file="$suite_dir/${test_name}.txt"
            
            # Compile with appropriate size
            compile_stream $array_size $stride "$executable"
            
            if [ $? -eq 0 ]; then
                # Run with NUMA binding
                export OMP_NUM_THREADS=$threads
                numactl --all --cpunodebind=$node_id --membind=$node_id ./"$executable" > "$output_file" 2>&1
                
                # Process results
                if [ -f "$output_file" ]; then
                    local copy=$(grep "Copy:" "$output_file" | awk '{print $2}')
                    local scale=$(grep "Scale:" "$output_file" | awk '{print $2}')
                    local add=$(grep "Add:" "$output_file" | awk '{print $2}')
                    local triad=$(grep "Triad:" "$output_file" | awk '{print $2}')
                    echo "$stride,$threads,$copy,$scale,$add,$triad,numa$node_id" >> "$suite_dir/results.csv"
                fi
            fi
            
            rm -f "$executable"
        done
    done
    
    generate_text_summary "$suite_dir"
}

# Function to run inter-NUMA tests
run_inter_numa_test() {
    local size_name=$1
    local array_size=$2
    local strides=$3
    
    log_info "Running inter-NUMA test with selected node pairs"
    
    # Only test single thread and max threads
    local thread_counts="1 $CORES"
    
    local suite_dir="$RESULTS_DIR/inter_numa_${size_name}_results"
    mkdir -p "$suite_dir"
    
    # Test node pairs with different distances
    local node_pairs=""
    case $NUMA_NODES in
        2) node_pairs="0,1" ;;
        4) node_pairs="0,1 0,2 0,3" ;;  # Adjacent, 1-hop, 2-hop
        8) node_pairs="0,1 0,2 0,4" ;;  # Adjacent, 1-hop, 2-hop
        *) 
            # For other configurations, just test adjacent nodes
            node_pairs="0,1"
            ;;
    esac
    
    # Run tests for each node pair
    for pair in $node_pairs; do
        local src_node=${pair%,*}
        local dst_node=${pair#*,}
        
        for stride in $strides; do
            for threads in $thread_counts; do
                local test_name="numa${src_node}_to_numa${dst_node}_array${array_size}_stride${stride}_threads${threads}"
                local executable="stream_${test_name}"
                local output_file="$suite_dir/${test_name}.txt"
                
                # Compile with appropriate size
                compile_stream $array_size $stride "$executable"
                
                if [ $? -eq 0 ]; then
                    # Run with NUMA binding
                    export OMP_NUM_THREADS=$threads
                    numactl --all --membind=$dst_node --cpunodebind=$src_node ./"$executable" > "$output_file" 2>&1
                    
                    # Process results
                    if [ -f "$output_file" ]; then
                        local copy=$(grep "Copy:" "$output_file" | awk '{print $2}')
                        local scale=$(grep "Scale:" "$output_file" | awk '{print $2}')
                        local add=$(grep "Add:" "$output_file" | awk '{print $2}')
                        local triad=$(grep "Triad:" "$output_file" | awk '{print $2}')
                        echo "$stride,$threads,$copy,$scale,$add,$triad,numa${src_node}_to_numa${dst_node}" >> "$suite_dir/results.csv"
                    fi
                fi
                
                rm -f "$executable"
            done
        done
    done
    
    generate_text_summary "$suite_dir"
}

# Standard test function
standard_test() {
    log_info "Test Plan for Standard Test:"
    echo -e "\n${BLUE}=== Standard Test Plan ===${NC}"
    echo "1. Array Sizes to Test:"
    echo "   - Cache-resident: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((CACHE_TEST_SIZE * 8 * 3)))"
    echo "   - Small: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((SMALL_TEST_SIZE * 8 * 3)))"
    echo "   - Standard: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((STANDARD_TEST_SIZE * 8 * 3)))"
    echo "   - Large: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((LARGE_TEST_SIZE * 8 * 3)))"
    
    echo -e "\n2. Thread Configurations:"
    echo "   - Starting from 1 thread"
    echo "   - Powers of 2 (1,2,4,8,...)"
    echo "   - Up to maximum cores ($CORES)"
    
    echo -e "\n3. Stride Values to Test:"
    echo "   - 1 (continuous access)"
    echo "   - 8, 16, 32, 64, 128, 256, 512 (strided access)"
    
    if [ $NUMA_NODES -gt 1 ]; then
        echo -e "\n4. NUMA-specific Tests:"
        echo "   - Intra-node tests on each NUMA node"
        echo "   - Inter-node bandwidth tests"
        echo "   - Memory placement strategies"
    fi
    
    echo -e "\n${YELLOW}Estimated test duration: $(( (CORES/4 + 1) * 8 * 4 / 60 + 1)) minutes${NC}"
    echo -e "\nPress Enter to start the tests, or Ctrl+C to cancel..."
    read
    
    local strides="1 8 16 32 64 128 256 512"
    
    if [ $NUMA_NODES -gt 1 ] && command -v numactl &> /dev/null; then
        # Get NUMA-specific information
        get_numa_info
        
        # Run intra-NUMA tests for each node
        for ((node=0; node<NUMA_NODES; node++)); do
            run_intra_numa_test $node "standard" $ARRAY_SIZE_PER_NUMA "$strides"
        done
        
        # Run inter-NUMA tests
        run_inter_numa_test "standard" $STANDARD_TEST_SIZE "$strides"
        
        log_info "NUMA-aware tests completed"
    else
        # Non-NUMA system or numactl not available
        local thread_counts="1"
        local current_threads=2
        while [ $current_threads -le $CORES ]; do
            thread_counts="$thread_counts $current_threads"
            current_threads=$((current_threads * 2))
        done
        if ! echo $thread_counts | grep -w "$CORES" > /dev/null; then
            thread_counts="$thread_counts $CORES"
        fi
        
        run_test_suite $STANDARD_TEST_SIZE "standard" "$strides" "$thread_counts"
    fi
    
    log_info "Standard test completed"
}

# Stride comparison test function
stride_test() {
    log_info "Starting stride comparison test..."
    
    # Calculate L3 cache size in bytes
    local l3_size_bytes=$((L3_SIZE_KB * 1024))
    
    echo "Select array size:"
    echo "1. Small ($SMALL_TEST_SIZE elements)"
    echo "   Total memory: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((SMALL_TEST_SIZE * 8 * 3)))"
    echo "   Per array: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((SMALL_TEST_SIZE * 8)))"
    echo "   L3 Cache ratio: $(echo "scale=0; (${SMALL_TEST_SIZE} * 8 * 3 + ${l3_size_bytes} - 1) / ${l3_size_bytes}" | bc)x L3 cache size"
    echo "   (8x L3: Good for testing cache effects and memory subsystem transitions)"
    echo ""
    echo "2. Standard ($STANDARD_TEST_SIZE elements)"
    echo "   Total memory: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((STANDARD_TEST_SIZE * 8 * 3)))"
    echo "   Per array: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((STANDARD_TEST_SIZE * 8)))"
    echo "   L3 Cache ratio: $(echo "scale=0; (${STANDARD_TEST_SIZE} * 8 * 3 + ${l3_size_bytes} - 1) / ${l3_size_bytes}" | bc)x L3 cache size"
    echo "   (32x L3: Large enough to minimize cache effects, focus on memory bandwidth)"
    echo ""
    echo "3. Large ($LARGE_TEST_SIZE elements)"
    echo "   Total memory: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((LARGE_TEST_SIZE * 8 * 3)))"
    echo "   Per array: $(numfmt --to=iec-i --suffix=B --format="%.2f" $((LARGE_TEST_SIZE * 8)))"
    echo "   L3 Cache ratio: $(echo "scale=0; (${LARGE_TEST_SIZE} * 8 * 3 + ${l3_size_bytes} - 1) / ${l3_size_bytes}" | bc)x L3 cache size"
    echo "   (Maximum size: Tests full system memory bandwidth and NUMA effects)"
    echo ""
    read -p "Choose (1-3): " size_choice
    
    case $size_choice in
        1) array_size=$SMALL_TEST_SIZE; size_name="small" ;;
        2) array_size=$STANDARD_TEST_SIZE; size_name="standard" ;;
        3) array_size=$LARGE_TEST_SIZE; size_name="large" ;;
        *) array_size=$STANDARD_TEST_SIZE; size_name="standard" ;;
    esac
    
    local strides="1 2 4 8 16 32 64 128 256 512"
    
    echo "Select thread count:"
    echo "1. Single thread"
    echo "2. All threads ($CORES)"
    echo "3. Custom"
    read -p "Choose (1-3): " thread_choice
    
    case $thread_choice in
        1) thread_counts="1" ;;
        2) thread_counts="$CORES" ;;
        3) 
            read -p "Enter thread count: " custom_threads
            thread_counts="$custom_threads" ;;
        *) thread_counts="1" ;;
    esac
    
    run_test_suite $array_size "$size_name" "$strides" "$thread_counts"
    
    log_info "Stride comparison test completed"
}

# Thread scaling test function
thread_test() {
    log_info "Starting thread scaling test..."
    
    # Show thread configuration options
    echo "Thread Count Configuration:"
    echo "1. Power of 2 sequence up to max cores"
    echo "2. Linear sequence (1,2,3,4,...,max_cores)"
    echo "3. Custom thread counts"
    echo -n "Choose thread count configuration (1-4): "
    read thread_config
    
    local thread_counts=""
    case $thread_config in
        1)  # Power of 2 sequence
            thread_counts="1"
            local current=2
            while [ $current -le $CORES ]; do
                thread_counts="$thread_counts $current"
                current=$((current * 2))
            done
            ;;
        2)  # Linear sequence
            echo -n "Enter step size (e.g., 4 for 1,5,9,...): "
            read step_size
            thread_counts="1"
            local current=$((1 + step_size))
            while [ $current -le $CORES ]; do
                thread_counts="$thread_counts $current"
                current=$((current + step_size))
            done
            ;;
        3)  # Custom thread counts
            echo "Enter thread counts separated by spaces (e.g., '1 4 8 16 32'): "
            read -r custom_threads
            thread_counts="$custom_threads"
            ;;
        *)  
            log_error "Invalid choice. Using default sequence."
            thread_counts="1 2 4 8 16 32 64"
            ;;
    esac
    
    # Add max cores if not already included
    if ! echo $thread_counts | grep -w "$CORES" > /dev/null; then
        thread_counts="$thread_counts $CORES"
    fi
    
    # Show selected configuration
    echo -e "\nSelected thread counts: $thread_counts"
    echo -n "Continue with these thread counts? (y/n): "
    read confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Test cancelled. Please try again."
        return
    fi
    
    # Configure stride values
    echo -e "\nStride Configuration:"
    echo "1. Default strides (1,8,16,32,64,128,256,512)"
    echo "2. Custom strides"
    echo -n "Choose stride configuration (1-2): "
    read stride_config
    
    local strides=""
    case $stride_config in
        2)  
            echo "Enter stride values separated by spaces (e.g., '1 4 8 16 32'): "
            read -r custom_strides
            strides="$custom_strides"
            ;;
        *)  
            strides="1 8 16 32 64 128 256 512"
            ;;
    esac
    
    # Show test configuration summary
    echo -e "\nTest Configuration Summary:"
    echo "Thread counts: $thread_counts"
    echo "Stride values: $strides"
    echo -n "Press Enter to start the test or Ctrl+C to cancel..."
    read
    
    # Run the test suite
    run_test_suite $STANDARD_TEST_SIZE "thread_scaling" "$strides" "$thread_counts"
    
    log_info "Thread scaling test completed"
}

# Custom test function
custom_test() {
    log_info "Custom Test Configuration"
    
    # Get array size
    echo -e "\n${BLUE}=== Custom Test Configuration ===${NC}"
    echo "1. Array Size Configuration"
    echo "   Available Memory: $(echo "scale=1; $AVAIL_MEM_KB / 1024 / 1024" | bc) GB"
    echo "   Current test sizes (elements):"
    echo "   - Cache: $CACHE_TEST_SIZE"
    echo "   - Small: $SMALL_TEST_SIZE"
    echo "   - Standard: $STANDARD_TEST_SIZE"
    echo "   - Large: $LARGE_TEST_SIZE"
    read -p "Enter array size (number of elements): " custom_size
    
    # Get stride values
    echo -e "\n2. Stride Configuration"
    echo "   Common stride values: 1,8,16,32,64,128,256,512"
    echo "   - 1: continuous memory access"
    echo "   - >1: strided access (larger values test cache behavior)"
    read -p "Enter stride values (space-separated): " custom_strides
    
    # Get thread counts
    echo -e "\n3. Thread Configuration"
    echo "   System has $CORES cores available"
    echo "   Common patterns:"
    echo "   - Powers of 2: 1 2 4 8 16 ..."
    echo "   - Linear: 1 2 3 4 ..."
    echo "   - Custom sequence for specific testing"
    read -p "Enter thread counts (space-separated): " custom_threads
    
    # Show test plan
    echo -e "\n${BLUE}=== Test Plan ===${NC}"
    echo "Array Size: $custom_size elements ($(numfmt --to=iec-i --suffix=B --format="%.2f" $((custom_size * 8 * 3))))"
    echo "Stride Values: $custom_strides"
    echo "Thread Counts: $custom_threads"
    
    # Calculate estimated duration
    local num_strides=$(echo $custom_strides | wc -w)
    local num_threads=$(echo $custom_threads | wc -w)
    local estimated_minutes=$(( (num_threads * num_strides) / 30 + 1))
    echo -e "\n${YELLOW}Estimated test duration: $estimated_minutes minutes${NC}"
    
    echo -e "\nPress Enter to start the tests, or Ctrl+C to cancel..."
    read
    
    run_test_suite $custom_size "custom" "$custom_strides" "$custom_threads"
    
    log_info "Custom test completed"
}

# View results function
view_results() {
    echo "Available result directories:"
    ls -d stream_results_* 2>/dev/null | sort
    
    read -p "Enter directory name to view (or Enter to return): " dir_name
    if [ -n "$dir_name" ] && [ -d "$dir_name" ]; then
        echo ""
        echo "=== System Information ==="
        head -20 "$dir_name/system_info.txt" 2>/dev/null
        
        echo ""
        echo "=== Test Results ==="
        find "$dir_name" -name "results.csv" -exec echo "File: {}" \; -exec head -10 {} \; 2>/dev/null
        
        echo ""
        echo "=== Generated Reports ==="
        find "$dir_name" -name "text_summary.txt" -exec cat {} \; 2>/dev/null
    fi
}

# Run NUMA-specific tests
run_numa_tests() {
    local array_size=$1
    local output_dir="$RESULTS_DIR/numa_tests"
    mkdir -p "$output_dir"
    
    log_info "Running NUMA-specific memory bandwidth tests..."
    
    # CSV for NUMA results
    local csv_file="$output_dir/numa_results.csv"
    echo "Test_Type,Node_Config,Threads,Memory_Placement,Copy_MB/s,Scale_MB/s,Add_MB/s,Triad_MB/s" > "$csv_file"
    
    # Get NUMA topology
    local numa_distances=$(numactl --hardware | grep -A$NUMA_NODES "distances:" | tail -n +2)
    
    # Calculate cores per NUMA node
    local cores_per_numa=$((CORES / NUMA_NODES))
    log_info "Cores per NUMA node: $cores_per_numa"
    
    # Compile NUMA-aware STREAM
    gcc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=$array_size stream_original.c -o stream_numa
    
    # 1. Intra-NUMA tests (only node 0)
    log_info "Running intra-NUMA tests on node 0..."
    local intra_thread_counts="1 $((cores_per_numa/2)) $cores_per_numa"
    
    for threads in $intra_thread_counts; do
        local output_file="$output_dir/intra_node_${threads}t.txt"
        log_info "Running intra-NUMA test with $threads threads"
        
        # Bind both memory and CPU to node 0
        export OMP_NUM_THREADS=$threads
        numactl --all --membind=0 --cpunodebind=0 ./stream_numa > "$output_file" 2>&1
        
        if [ -f "$output_file" ]; then
            local copy=$(grep "Copy:" "$output_file" | awk '{print $2}')
            local scale=$(grep "Scale:" "$output_file" | awk '{print $2}')
            local add=$(grep "Add:" "$output_file" | awk '{print $2}')
            local triad=$(grep "Triad:" "$output_file" | awk '{print $2}')
            echo "intra_node,node0,$threads,local,$copy,$scale,$add,$triad" >> "$csv_file"
        fi
    done
    
    # 2. Inter-NUMA tests
    if [ $NUMA_NODES -gt 1 ]; then
        log_info "Running inter-NUMA tests..."
        
        # Thread configurations for inter-NUMA tests
        local inter_thread_counts="1 $cores_per_numa $((2 * cores_per_numa))"
        
        # Test different node pairs based on distance
        local node_pairs=(
            "0,1:adjacent"  # Adjacent nodes
            "0,2:1hop"      # 1-hop distance (if available)
            "0,3:2hop"      # 2-hop distance (if available)
        )
        
        for pair in "${node_pairs[@]}"; do
            local nodes=${pair%:*}
            local distance_type=${pair#*:}
            local node1=${nodes%,*}
            local node2=${nodes#*,}
            
            # Skip if nodes don't exist
            if [ $node2 -ge $NUMA_NODES ]; then
                continue
            fi
            
            for threads in $inter_thread_counts; do
                local output_file="$output_dir/inter_node_${distance_type}_${threads}t.txt"
                log_info "Running inter-NUMA test ($distance_type) with $threads threads"
                
                # For inter-NUMA tests:
                # 1. Place memory on node2 (remote node)
                # 2. Run threads on node1 (local node)
                # This ensures memory access is always cross-NUMA
                export OMP_NUM_THREADS=$threads
                numactl --all --membind=$node2 --cpunodebind=$node1 ./stream_numa > "$output_file" 2>&1
                
                if [ -f "$output_file" ]; then
                    local copy=$(grep "Copy:" "$output_file" | awk '{print $2}')
                    local scale=$(grep "Scale:" "$output_file" | awk '{print $2}')
                    local add=$(grep "Add:" "$output_file" | awk '{print $2}')
                    local triad=$(grep "Triad:" "$output_file" | awk '{print $2}')
                    echo "inter_node_${distance_type},node${node1}-${node2},$threads,remote,$copy,$scale,$add,$triad" >> "$csv_file"
                fi
                
                # For comparison, also test with memory interleaved across both nodes
                if [ $threads -gt 1 ]; then
                    local output_file="$output_dir/inter_node_${distance_type}_${threads}t_interleaved.txt"
                    log_info "Running inter-NUMA test ($distance_type) with $threads threads (interleaved memory)"
                    
                    numactl --interleave=$node1,$node2 --cpunodebind=$node1,$node2 ./stream_numa > "$output_file" 2>&1
                    
                    if [ -f "$output_file" ]; then
                        local copy=$(grep "Copy:" "$output_file" | awk '{print $2}')
                        local scale=$(grep "Scale:" "$output_file" | awk '{print $2}')
                        local add=$(grep "Add:" "$output_file" | awk '{print $2}')
                        local triad=$(grep "Triad:" "$output_file" | awk '{print $2}')
                        echo "inter_node_${distance_type},node${node1}-${node2},$threads,interleaved,$copy,$scale,$add,$triad" >> "$csv_file"
                    fi
                fi
            done
        done
    fi
    
    # Clean up
    rm -f stream_numa
    
    # Generate summary
    generate_numa_summary "$output_dir"
}

# Generate NUMA test summary
generate_numa_summary() {
    local numa_dir=$1
    local summary_file="$numa_dir/numa_summary.txt"
    local cores_per_numa=$((CORES / NUMA_NODES))
    
    {
        echo "=== NUMA Memory Bandwidth Test Summary ==="
        echo "Date: $(date)"
        echo "Total Cores: $CORES"
        echo "NUMA Nodes: $NUMA_NODES"
        echo "Cores per NUMA node: $cores_per_numa"
        echo ""
        
        echo "1. Intra-Node Performance (Node 0)"
        echo "----------------------------------------"
        awk -F',' '$1=="intra_node" {
            printf "Threads: %s\n", $3
            printf "Copy:  %9.1f MB/s\n", $5
            printf "Scale: %9.1f MB/s\n", $6
            printf "Add:   %9.1f MB/s\n", $7
            printf "Triad: %9.1f MB/s\n\n", $8
        }' "$numa_dir/numa_results.csv"
        
        if [ $NUMA_NODES -gt 1 ]; then
            echo "2. Inter-Node Performance"
            echo "----------------------------------------"
            
            echo "a) Adjacent Nodes (0-1)"
            echo "Remote Memory Access:"
            awk -F',' '$1=="inter_node_adjacent" && $4=="remote" {
                printf "Threads: %s\n", $3
                printf "Copy:  %9.1f MB/s\n", $5
                printf "Scale: %9.1f MB/s\n", $6
                printf "Add:   %9.1f MB/s\n", $7
                printf "Triad: %9.1f MB/s\n\n", $8
            }' "$numa_dir/numa_results.csv"
            
            echo "Interleaved Memory Access:"
            awk -F',' '$1=="inter_node_adjacent" && $4=="interleaved" {
                printf "Threads: %s\n", $3
                printf "Copy:  %9.1f MB/s\n", $5
                printf "Scale: %9.1f MB/s\n", $6
                printf "Add:   %9.1f MB/s\n", $7
                printf "Triad: %9.1f MB/s\n\n", $8
            }' "$numa_dir/numa_results.csv"
            
            if [ $NUMA_NODES -gt 2 ]; then
                echo "b) 1-Hop Distance (0-2)"
                echo "Remote Memory Access:"
                awk -F',' '$1=="inter_node_1hop" && $4=="remote" {
                    printf "Threads: %s\n", $3
                    printf "Copy:  %9.1f MB/s\n", $5
                    printf "Scale: %9.1f MB/s\n", $6
                    printf "Add:   %9.1f MB/s\n", $7
                    printf "Triad: %9.1f MB/s\n\n", $8
                }' "$numa_dir/numa_results.csv"
                
                echo "Interleaved Memory Access:"
                awk -F',' '$1=="inter_node_1hop" && $4=="interleaved" {
                    printf "Threads: %s\n", $3
                    printf "Copy:  %9.1f MB/s\n", $5
                    printf "Scale: %9.1f MB/s\n", $6
                    printf "Add:   %9.1f MB/s\n", $7
                    printf "Triad: %9.1f MB/s\n\n", $8
                }' "$numa_dir/numa_results.csv"
            fi
            
            if [ $NUMA_NODES -gt 3 ]; then
                echo "c) 2-Hop Distance (0-3)"
                echo "Remote Memory Access:"
                awk -F',' '$1=="inter_node_2hop" && $4=="remote" {
                    printf "Threads: %s\n", $3
                    printf "Copy:  %9.1f MB/s\n", $5
                    printf "Scale: %9.1f MB/s\n", $6
                    printf "Add:   %9.1f MB/s\n", $7
                    printf "Triad: %9.1f MB/s\n\n", $8
                }' "$numa_dir/numa_results.csv"
                
                echo "Interleaved Memory Access:"
                awk -F',' '$1=="inter_node_2hop" && $4=="interleaved" {
                    printf "Threads: %s\n", $3
                    printf "Copy:  %9.1f MB/s\n", $5
                    printf "Scale: %9.1f MB/s\n", $6
                    printf "Add:   %9.1f MB/s\n", $7
                    printf "Triad: %9.1f MB/s\n\n", $8
                }' "$numa_dir/numa_results.csv"
            fi
            
            # Add performance comparison
            echo "3. Performance Comparison"
            echo "----------------------------------------"
            echo "Best Performance Configurations:"
            awk -F',' 'BEGIN {
                printf "%-20s %-15s %-15s %-15s\n", "Test Type", "Threads", "Memory Mode", "Triad MB/s"
            }
            {
                if($8 > max[$1]) {
                    max[$1] = $8
                    config[$1] = sprintf("%-20s %-15s %-15s %-15.1f", $1, $3, $4, $8)
                }
            }
            END {
                for(test in config) {
                    print config[test]
                }
            }' "$numa_dir/numa_results.csv"
        fi
        
    } > "$summary_file"
    
    echo -e "${GREEN}NUMA test summary generated: $summary_file${NC}"
    cat "$summary_file"
}

# Calculate array sizes for different test scenarios
calculate_array_sizes() {
    # Get cache line size (default to 64 bytes if not available)
    if [ -f "/sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size" ]; then
        export CACHE_LINE_SIZE=$(cat /sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size)
    else
        export CACHE_LINE_SIZE=64
    fi
    
    # Calculate array sizes based on available memory
    # Use 75% of available memory for large test
    local max_mem_kb=$((AVAIL_MEM_KB * 75 / 100))
    
    # Calculate maximum number of array elements
    # Each test uses 3 arrays of doubles (8 bytes each)
    local max_elements=$((max_mem_kb * 1024 / (3 * 8)))
    
    # Ensure we don't exceed the maximum array index limit (2^31-1)
    local max_safe_elements=2147483647  # 2^31-1
    if [ $max_elements -gt $max_safe_elements ]; then
        max_elements=$max_safe_elements
    fi
    
    # Calculate test sizes
    # Cache test: Based on L3 cache size (fits in LLC)
    export CACHE_TEST_SIZE=$((L3_SIZE_KB * 1024 / (3 * 8)))
    
    # STREAM DRAM bandwidth: working set should be at least 8x L3 cache
    export MEMORY_BW_L3_FACTOR=8
    
    # Small test: ~1GB total (3 arrays)
    export SMALL_TEST_SIZE=$((128 * 1024 * 1024 / (3 * 8)))
    
    # Standard test: ~4GB total (3 arrays)
    export STANDARD_TEST_SIZE=$((512 * 1024 * 1024 / (3 * 8)))
    
    # Large test: Use calculated maximum size
    export LARGE_TEST_SIZE=$max_elements
    
    # For NUMA systems, calculate NUMA-specific sizes
    if [ $NUMA_NODES -gt 1 ]; then
        # NUMA test size: Use standard test size
        export NUMA_TEST_SIZE=$STANDARD_TEST_SIZE
        
        # Per-node size: Divide by number of NUMA nodes
        export NUMA_PER_NODE_SIZE=$((STANDARD_TEST_SIZE / NUMA_NODES))
    fi
}

# Main function
main() {
    create_results_dir
    collect_system_info
    calculate_array_sizes
    create_stream_source
    create_stride_stream

    while true; do
        show_main_menu
        read -r choice
        echo ""

        case $choice in
            1) automated_memory_test ;;
            2) manual_memory_test ;;
            3|q|Q)
                echo "退出测试程序"
                exit 0
                ;;
            *)
                log_error "无效选项，请输入 1-3"
                ;;
        esac

        echo ""
        read -p "按 Enter 返回主菜单..."
        clear
    done
}

# Legacy main (detailed sub-menu) - disabled
legacy_main() {
    # Create results directory
    create_results_dir
    
    # Collect and display system information
    collect_system_info
    
    # Calculate array sizes
    calculate_array_sizes
    
    # Show system summary
    show_system_summary
    
    # Create STREAM source files
    create_stream_source
    create_stride_stream
    
    # Show menu and handle selection
    while true; do
        show_menu
        read choice
        echo ""
        
        case $choice in
            1) standard_test ;;
            2) stride_test ;;
            3) thread_test ;;
            4)
                if [ $NUMA_NODES -gt 1 ]; then
                    run_numa_tests $STANDARD_TEST_SIZE
                else
                    echo "NUMA testing not available on this system"
                fi
                ;;
            5) custom_test ;;
            6) view_results ;;
            7) 
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo "Invalid option. Please try again."
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
        clear
        show_system_summary
    done
}

# Execute main function
main

# Generate comprehensive final report
generate_final_report() {
    local report_file="$RESULTS_DIR/final_report.txt"
    
    {
        echo "=============================================="
        echo "     Memory Bandwidth Test Final Report"
        echo "=============================================="
        echo "Generated: $(date)"
        echo ""
        
        # System Configuration
        echo "1. System Configuration"
        echo "----------------------------------------------"
        echo "CPU: $CPU_MODEL"
        echo "Cores: $CORES"
        echo "Memory: $(echo "scale=1; $TOTAL_MEM_KB / 1024 / 1024" | bc) GB"
        if [ $NUMA_NODES -gt 1 ]; then
            echo "NUMA Nodes: $NUMA_NODES"
        fi
        echo ""
        
        # Standard Test Results
        echo "2. Standard Test Results"
        echo "----------------------------------------------"
        
        # Function to extract best results for each operation
        extract_best_results() {
            local size=$1
            local csv_file="$RESULTS_DIR/${size}_results/results.csv"
            
            echo "a) $size Test Results (Best MB/s)"
            echo "Threads  Copy      Scale     Add       Triad"
            awk -F',' 'NR>1 && $1==1 {
                printf "%-8s %-9.1f %-9.1f %-9.1f %-9.1f\n", 
                    $2, $3, $4, $5, $6
            }' "$csv_file" | sort -n -k1
            echo ""
            
            echo "b) Stride Impact (Single Thread, MB/s)"
            echo "Stride   Copy      Scale     Add       Triad"
            awk -F',' 'NR>1 && $2==1 {
                printf "%-8s %-9.1f %-9.1f %-9.1f %-9.1f\n", 
                    $1, $3, $4, $5, $6
            }' "$csv_file" | sort -n -k1
            echo ""
        }
        
        # Extract results for each test size
        for size in "cache" "small" "standard" "large"; do
            extract_best_results $size
        done
        
        # NUMA Test Results
        if [ $NUMA_NODES -gt 1 ]; then
            echo "3. NUMA-Specific Test Results"
            echo "----------------------------------------------"
            cat "$RESULTS_DIR/numa_tests/numa_summary.txt"
        fi
        
        # Performance Analysis
        echo ""
        echo "4. Performance Analysis"
        echo "----------------------------------------------"
        
        # Find best overall performance
        local best_triad=0
        local best_config=""
        
        for size in "cache" "small" "standard" "large"; do
            local csv_file="$RESULTS_DIR/${size}_results/results.csv"
            local current_best=$(awk -F',' 'NR>1 {if($6>max) max=$6} END{print max}' "$csv_file")
            if (( $(echo "$current_best > $best_triad" | bc -l) )); then
                best_triad=$current_best
                best_config=$(awk -F',' -v best=$current_best '$6==best {printf "%s test, %d threads, stride %d", ENVIRON["size"], $2, $1}' "$csv_file")
            fi
        done
        
        echo "Best Memory Bandwidth: $best_triad MB/s"
        echo "Configuration: $best_config"
        
        if [ $NUMA_NODES -gt 1 ]; then
            echo ""
            echo "NUMA Impact:"
            local numa_csv="$RESULTS_DIR/numa_tests/numa_results.csv"
            local intra_bw=$(awk -F',' '$1=="intra_node" {max=$7} END{print max}' "$numa_csv")
            local inter_bw=$(awk -F',' '$1~"inter_node" {if($7>max) max=$7} END{print max}' "$numa_csv")
            local numa_penalty=$(echo "scale=1; (1 - $inter_bw/$intra_bw) * 100" | bc)
            echo "Intra-node bandwidth: $intra_bw MB/s"
            echo "Inter-node bandwidth: $inter_bw MB/s"
            echo "NUMA penalty: ${numa_penalty}%"
        fi
        
    } > "$report_file"
    
    echo -e "${GREEN}Final report generated: $report_file${NC}"
    cat "$report_file"
}

# Function to display stride test results for all thread counts
display_stride_results() {
    local thread_count=$1
    local stride=$2
    local result_file=$3
    
    echo -e "\n${YELLOW}=== Stride Test Results (Threads: $thread_count, Stride: $stride) ===${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
    
    # Extract and format the results
    local copy_bw=$(grep "Copy:" "$result_file" | awk '{print $2}')
    local scale_bw=$(grep "Scale:" "$result_file" | awk '{print $2}')
    local add_bw=$(grep "Add:" "$result_file" | awk '{print $2}')
    local triad_bw=$(grep "Triad:" "$result_file" | awk '{print $2}')
    
    printf "%-15s %12s\n" "Operation" "Bandwidth (MB/s)"
    echo "----------------------------------------"
    printf "%-15s %12.2f\n" "Copy" "$copy_bw"
    printf "%-15s %12.2f\n" "Scale" "$scale_bw"
    printf "%-15s %12.2f\n" "Add" "$add_bw"
    printf "%-15s %12.2f\n" "Triad" "$triad_bw"
    
    echo -e "${BLUE}----------------------------------------${NC}"
}

# Function to calculate and display L3 cache ratios
display_cache_ratios() {
    local test_size=$1
    local l3_size=$2
    
    echo -e "\n${YELLOW}=== Memory Footprint Analysis ===${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
    
    # Calculate total memory footprint (3 arrays * 8 bytes per double * size)
    local footprint=$((test_size * 8 * 3))
    local l3_ratio=$(echo "scale=2; $footprint / $l3_size" | bc)
    
    echo "Test Size: $(numfmt --to=iec-i --suffix=B --format="%.2f" $footprint)"
    echo "L3 Cache Size: $(numfmt --to=iec-i --suffix=B --format="%.2f" $l3_size)"
    echo "Memory/L3 Ratio: ${l3_ratio}x"
    
    # Provide context about the ratio
    if (( $(echo "$l3_ratio < 1" | bc -l) )); then
        echo "Status: Working set fits in L3 cache"
    elif (( $(echo "$l3_ratio < 8" | bc -l) )); then
        echo "Status: Moderate cache pressure"
    else
        echo "Status: High memory pressure (memory bound)"
    fi
    
    echo -e "${BLUE}----------------------------------------${NC}"
}

# Function to display comprehensive test plan
display_test_plan() {
    echo -e "\n${YELLOW}=== STREAM Test Plan ===${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
    
    echo "1. Standard STREAM Tests:"
    echo "   - Array sizes: $CACHE_TEST_SIZE, $SMALL_TEST_SIZE, $STANDARD_TEST_SIZE, $LARGE_TEST_SIZE"
    echo "   - Thread counts: $DEFAULT_THREAD_SEQUENCE"
    echo "   - Operations: Copy, Scale, Add, Triad"
    
    echo -e "\n2. Stride Tests:"
    echo "   - Stride values: 1, 2, 4, 8, 16"
    echo "   - Array size: $STANDARD_TEST_SIZE"
    echo "   - Thread counts: $DEFAULT_THREAD_SEQUENCE"
    
    if [ $NUMA_NODES -gt 1 ]; then
        echo -e "\n3. NUMA-Aware Tests:"
        echo "   - Per-node size: $NUMA_PER_NODE_SIZE"
        echo "   - Total size: $NUMA_TEST_SIZE"
        echo "   - NUMA nodes: $NUMA_NODES"
    fi
    
    echo -e "\nEstimated total runtime: $(calculate_estimated_runtime) minutes"
    echo -e "${BLUE}----------------------------------------${NC}"
}

# Function to calculate estimated runtime
calculate_estimated_runtime() {
    local num_thread_configs=$(echo $DEFAULT_THREAD_SEQUENCE | wc -w)
    local num_sizes=4  # cache, small, standard, large
    local num_stride_tests=5  # 1, 2, 4, 8, 16
    local time_per_test=0.5  # estimated minutes per test
    
    local total_tests=$((num_thread_configs * (num_sizes + num_stride_tests)))
    if [ $NUMA_NODES -gt 1 ]; then
        total_tests=$((total_tests + num_thread_configs))  # Add NUMA tests
    fi
    
    echo "scale=1; $total_tests * $time_per_test" | bc
}

# Execute main function
main
