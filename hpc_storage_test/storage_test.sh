#!/bin/bash

#############################################
# IOR Automated Performance Testing Script
# Author: System Performance Evaluation
# Version: 1.0
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOR_DIR="${SCRIPT_DIR}/ior"
export PATH="${IOR_DIR}/bin:${PATH}"
export LD_LIBRARY_PATH="${IOR_DIR}/lib:${LD_LIBRARY_PATH}"
export PATH=/opt/hpc/software/mpi/ompi/5.0.3/gcc-8.5.0/shca/bin:$PATH
export LD_LIBRARY_PATH=/opt/hpc/software/mpi/ompi/5.0.3/gcc-8.5.0/shca/lib:$LD_LIBRARY_PATH

# Color definitions for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default parameter recommendations
DEFAULT_TRANSFER_SIZE="4m"
DEFAULT_BLOCK_SIZE="64m"
DEFAULT_SEGMENTS="8"
DEFAULT_NUM_PROCS="16"
DEFAULT_OUTPUT_DIR="./ior_results"
DEFAULT_TEST_FILE="testfile"
MPIRUN_FLAGS="${MPIRUN_FLAGS:-}"
PARALLEL_PROCS=(2 4 8 16 32 64 128)

# Thread scaling test configurations
MAX_CORES=$(nproc)
DEFAULT_THREAD_SEQUENCE="1"
current_threads=2
while [ $current_threads -le $MAX_CORES ]; do
    DEFAULT_THREAD_SEQUENCE="$DEFAULT_THREAD_SEQUENCE $current_threads"
    current_threads=$((current_threads * 2))
done
if ! echo $DEFAULT_THREAD_SEQUENCE | grep -w "$MAX_CORES" > /dev/null; then
    DEFAULT_THREAD_SEQUENCE="$DEFAULT_THREAD_SEQUENCE $MAX_CORES"
fi

# Timestamp for unique results
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Function to display menu
show_menu() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}     HPC Storage Performance Testing    ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}1)${NC} Custom Test (User-defined parameters)"
    echo -e "${GREEN}2)${NC} Full Benchmark Suite"
    echo -e "${GREEN}3)${NC} Serial Tests Only"
    echo -e "${GREEN}4)${NC} Parallel Scaling Tests (2-128 procs)"
    echo -e "${GREEN}5)${NC} Thread Scaling Tests"
    echo -e "${GREEN}6)${NC} Block Size Scaling Test"
    echo -e "${GREEN}7)${NC} View Recent Results"
    echo -e "${GREEN}8)${NC} Exit"
    echo -e "${BLUE}========================================${NC}"
}

# Function to confirm test parameters
confirm_parameters() {
    echo -e "${YELLOW}Test Parameters:${NC}"
    echo "  Transfer Size: $TRANSFER_SIZE"
    echo "  Block Size: $BLOCK_SIZE"
    echo "  Segments: $SEGMENTS"
    echo "  Parallel Processes: $NUM_PROCS"
    echo "  Output Directory: $OUTPUT_DIR"
    echo "  Test File Path: $TEST_FILE_PATH"
    echo ""
    read -p "Continue with these parameters? (y/n): " confirm
    if [[ $confirm != [yY] ]]; then
        return 1
    fi
    return 0
}

# Function to display test results
display_test_results() {
    local result_file=$1
    local test_name=$2
    
    echo -e "\n${YELLOW}=== Test Results: $test_name ===${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
    
    # Print the complete header information
    echo "access    bw(MiB/s)  IOPS       Latency(s)  block(KiB) xfer(KiB)  open(s)    wr/rd(s)   close(s)   total(s)   iter"
    echo "------    ---------  ----       ----------  ---------- ---------  --------   --------   --------   --------   ----"
    
    # Get write and read results (only the data lines)
    grep "^write" "$result_file" | head -n1
    grep "^read" "$result_file" | head -n1
    
    echo -e "${BLUE}----------------------------------------${NC}"
}

# Function to run serial write test
run_serial_write_read() {
    echo -e "${BLUE}Running Serial Write/Read Test...${NC}"
    test_name="serial_write_read_${TIMESTAMP}"
    output_file="${OUTPUT_DIR}/${test_name}.txt"
    
    # Run IOR test and capture all output
    ior -a POSIX -t ${TRANSFER_SIZE} -b ${BLOCK_SIZE} -s ${SEGMENTS} -F \
        -o ${TEST_FILE_PATH}_serial_w -w -r > ${output_file} 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Serial Write/Read Test Completed${NC}"
        display_test_results "$output_file" "Serial Write/Read"
    else
        echo -e "${RED}Serial Write/Read Test Failed${NC}"
        echo -e "Error details:"
        cat "$output_file"
    fi
}

# Function to run parallel shared file write test
run_parallel_shared_write_read() {
    echo -e "${BLUE}Running Parallel Shared File Write Test...${NC}"
    test_name="parallel_shared_write_read_${TIMESTAMP}"
    output_file="${OUTPUT_DIR}/${test_name}.txt"
    
    # N:1 shared-file mode requires xfer-size == block-size when segments > 1
    mpirun -np ${NUM_PROCS} ior -a POSIX -t ${BLOCK_SIZE} -b ${BLOCK_SIZE} \
        -s ${SEGMENTS} -o ${TEST_FILE_PATH}_parallel_shared_w -w -r > ${output_file} 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Parallel Shared Write/Read Test Completed${NC}"
        display_test_results "$output_file" "Parallel Shared Write/Read"
    else
        echo -e "${RED}Parallel Shared Write/Read Test Failed${NC}"
        echo -e "Error details:"
        cat "$output_file"
    fi
}

# Function to run parallel independent file write test
run_parallel_independent_write_read() {
    echo -e "${BLUE}Running Parallel Independent File Write Test...${NC}"
    test_name="parallel_independent_write_read_${TIMESTAMP}"
    output_file="${OUTPUT_DIR}/${test_name}.txt"
    
    # Run IOR test and capture all output
    mpirun -np ${NUM_PROCS} ior -a POSIX -t ${TRANSFER_SIZE} -b ${BLOCK_SIZE} \
        -s ${SEGMENTS} -F -o ${TEST_FILE_PATH}_parallel_independent_w -w -r > ${output_file} 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Parallel Independent Write/Read Test Completed${NC}"
        display_test_results "$output_file" "Parallel Independent Write/Read"
    else
        echo -e "${RED}Parallel Independent Write/Read Test Failed${NC}"
        echo -e "Error details:"
        cat "$output_file"
    fi
}

# Function to run all tests
run_all_tests() {
    echo -e "${YELLOW}Starting Full Benchmark Suite${NC}"
    run_serial_write_read
    run_parallel_shared_write_read
    run_parallel_independent_write_read
    echo -e "${GREEN}All tests completed!${NC}"
}

# Function to run serial tests only
run_serial_tests() {
    echo -e "${YELLOW}Starting Serial Tests${NC}"
    run_serial_write_read
    echo -e "${GREEN}Serial tests completed!${NC}"
}

# Function to run parallel tests only
run_parallel_tests() {
    local csv_file="${OUTPUT_DIR}/parallel_scaling_${TIMESTAMP}.csv"
    local procs mode

    echo -e "${YELLOW}Starting Parallel Scaling Tests${NC}"
    echo "Process sequence: ${PARALLEL_PROCS[*]}"
    echo "Each process reads and writes 512 MiB (64 MiB block x 8 segments)."
    echo "CSV summary: $csv_file"

    echo "Mode,Processes,Operation,Bandwidth_MiBs,IOPS,Latency_s,Status,OutputFile" > "$csv_file"

    for procs in "${PARALLEL_PROCS[@]}"; do
        for mode in shared independent; do
            local transfer_size
            local test_file="${TEST_FILE_PATH}_scaling_${mode}_${procs}p"
            local output_file="${OUTPUT_DIR}/parallel_scaling_${mode}_${procs}p_${TIMESTAMP}.txt"
            local ior_args

            if [[ "$mode" == "shared" ]]; then
                transfer_size="$BLOCK_SIZE"
                ior_args=(-a POSIX -t "$transfer_size" -b "$BLOCK_SIZE" -s "$SEGMENTS" -o "$test_file" -w -r)
            else
                transfer_size="$TRANSFER_SIZE"
                ior_args=(-a POSIX -t "$transfer_size" -b "$BLOCK_SIZE" -s "$SEGMENTS" -F -o "$test_file" -w -r)
            fi

            echo -e "\n${BLUE}Running ${mode} test with ${procs} processes${NC}"
            if mpirun $MPIRUN_FLAGS -np "$procs" ior "${ior_args[@]}" > "$output_file" 2>&1; then
                echo -e "${GREEN}Completed ${mode} test with ${procs} processes${NC}"
                display_test_results "$output_file" "Parallel Scaling ${mode} (${procs} procs)"

                while IFS= read -r line; do
                    local operation bandwidth iops latency
                    operation=$(printf "%s\n" "$line" | awk "{print \$1}")
                    bandwidth=$(printf "%s\n" "$line" | awk "{print \$2}")
                    iops=$(printf "%s\n" "$line" | awk "{print \$3}")
                    latency=$(printf "%s\n" "$line" | awk "{print \$4}")
                    echo "${mode},${procs},${operation},${bandwidth},${iops},${latency},ok,${output_file}" >> "$csv_file"
                done < <(grep -E "^(write|read) " "$output_file" | head -n 2)
            else
                echo -e "${RED}Failed ${mode} test with ${procs} processes${NC}"
                echo "${mode},${procs},NA,0,0,0,failed,${output_file}" >> "$csv_file"
                cat "$output_file"
            fi
        done
    done

    echo -e "\n${GREEN}Parallel scaling tests completed!${NC}"
    echo "CSV summary: $csv_file"
}

# Function to run thread scaling tests with enhanced output
run_thread_scaling_tests() {
    echo -e "${YELLOW}Running Thread Scaling Tests${NC}"
    echo "This will test both shared and independent file access patterns"
    echo "with different thread counts: $DEFAULT_THREAD_SEQUENCE"
    echo -e "Total tests to run: $((2 * $(echo $DEFAULT_THREAD_SEQUENCE | wc -w)))\n"
    
    read -p "Press Enter to start the tests, or Ctrl+C to cancel..."
    
    # Create a summary file
    local summary_file="${OUTPUT_DIR}/thread_scaling_summary_${TIMESTAMP}.txt"
    echo "Thread Scaling Test Results - $(date)" > "$summary_file"
    echo "System Information:" >> "$summary_file"
    echo "- CPU Model: $(lscpu | grep "Model name" | sed 's/Model name:\s*//')" >> "$summary_file"
    echo "- Total Cores: $(nproc)" >> "$summary_file"
    echo "- Memory: $(free -h | grep Mem | awk '{print $2}')" >> "$summary_file"
    echo "----------------------------------------" >> "$summary_file"
    
    # Create CSV summary for plotting
    local csv_file="${OUTPUT_DIR}/thread_scaling_data_${TIMESTAMP}.csv"
    echo "Threads,Access,Operation,Bandwidth,IOPS,Latency" > "$csv_file"
    
    # Run tests for each thread count
    for threads in $DEFAULT_THREAD_SEQUENCE; do
        echo -e "\n${BLUE}Testing with $threads threads${NC}"
        
        # Shared file access test
        echo -e "\n${GREEN}Running Shared File Access Test${NC}"
        local shared_test_name="thread_scaling_shared_${threads}_${TIMESTAMP}"
        local shared_output="${OUTPUT_DIR}/${shared_test_name}.txt"
        
        # N:1 shared-file mode requires xfer-size == block-size when segments > 1
        mpirun -np $threads ior -a POSIX -t ${BLOCK_SIZE} -b ${BLOCK_SIZE} \
            -s ${SEGMENTS} -o ${TEST_FILE_PATH}_thread_scaling_shared -w -r > "$shared_output" 2>&1
        
        # Independent file access test
        echo -e "${GREEN}Running Independent File Access Test${NC}"
        local indep_test_name="thread_scaling_independent_${threads}_${TIMESTAMP}"
        local indep_output="${OUTPUT_DIR}/${indep_test_name}.txt"
        
        mpirun -np $threads ior -a POSIX -t ${TRANSFER_SIZE} -b ${BLOCK_SIZE} \
            -s ${SEGMENTS} -F -o ${TEST_FILE_PATH}_thread_scaling_independent -w -r > "$indep_output" 2>&1
        
        # Extract and display results
        echo -e "\n${YELLOW}Results for $threads threads:${NC}"
        
        # Process shared file results
        echo -e "\nShared File Access:"
        display_test_results "$shared_output" "Shared File ($threads threads)"
        
        # Add to CSV
        while IFS= read -r line; do
            if [[ $line =~ ^(write|read) ]]; then
                op=$(echo $line | awk '{print $1}')
                bw=$(echo $line | awk '{print $2}')
                iops=$(echo $line | awk '{print $3}')
                lat=$(echo $line | awk '{print $4}')
                echo "$threads,shared,$op,$bw,$iops,$lat" >> "$csv_file"
            fi
        done < "$shared_output"
        
        # Process independent file results
        echo -e "\nIndependent File Access:"
        display_test_results "$indep_output" "Independent File ($threads threads)"
        
        # Add to CSV
        while IFS= read -r line; do
            if [[ $line =~ ^(write|read) ]]; then
                op=$(echo $line | awk '{print $1}')
                bw=$(echo $line | awk '{print $2}')
                iops=$(echo $line | awk '{print $3}')
                lat=$(echo $line | awk '{print $4}')
                echo "$threads,independent,$op,$bw,$iops,$lat" >> "$csv_file"
            fi
        done < "$indep_output"
        
        # Add to summary
        {
            echo -e "\nThread count: $threads"
            echo "Shared File Access:"
            grep "^write\|^read" "$shared_output"
            echo "Independent File Access:"
            grep "^write\|^read" "$indep_output"
            echo "----------------------------------------"
        } >> "$summary_file"
    done
    
    echo -e "\n${GREEN}Thread scaling tests completed!${NC}"
    echo "Summary saved to: $summary_file"
    echo "CSV data saved to: $csv_file"
    echo -e "\n${YELLOW}Summary of all tests:${NC}"
    cat "$summary_file"
}

# Function to display recent results
view_results() {
    # Ensure OUTPUT_DIR is set
    OUTPUT_DIR=${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}
    
    echo -e "${BLUE}Recent Test Results:${NC}"
    
    # Create directory if it doesn't exist
    mkdir -p "${OUTPUT_DIR}"
    
    # Check if there are any result files
    if [ -d "${OUTPUT_DIR}" ] && ls ${OUTPUT_DIR}/*.txt >/dev/null 2>&1; then
        # Create a temporary array to store file information
        declare -a files
        declare -a descriptions
        
        # Get the latest 5 files and store them in the array
        while IFS= read -r file; do
            # Extract test type from filename
            local basename=$(basename "$file")
            local test_type=""
            local timestamp=""
            
            if [[ $basename =~ thread_scaling ]]; then
                test_type="Thread Scaling Test"
                timestamp=$(echo $basename | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            elif [[ $basename =~ serial ]]; then
                test_type="Serial Test"
                timestamp=$(echo $basename | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            elif [[ $basename =~ parallel_shared ]]; then
                test_type="Parallel Shared File Test"
                timestamp=$(echo $basename | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            elif [[ $basename =~ parallel_independent ]]; then
                test_type="Parallel Independent File Test"
                timestamp=$(echo $basename | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            fi
            
            # Format timestamp for display
            if [ -n "$timestamp" ]; then
                local formatted_time=$(date -d "${timestamp:0:8} ${timestamp:9:6}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
                descriptions+=("$test_type ($formatted_time)")
                files+=("$file")
            fi
        done < <(ls -t ${OUTPUT_DIR}/*.txt 2>/dev/null | head -5)
        
        # Display menu of results
        echo -e "\nSelect a result to view:"
        for i in "${!files[@]}"; do
            echo -e "${GREEN}$((i+1)))${NC} ${descriptions[$i]}"
        done
        echo -e "${GREEN}6)${NC} Return to main menu"
        
        # Get user selection
        while true; do
            read -p "Enter selection (1-6): " selection
            if [[ "$selection" =~ ^[1-6]$ ]]; then
                break
            fi
            echo "Invalid selection. Please enter a number between 1 and 6."
        done
        
        # Display selected result or return
        if [ "$selection" -eq 6 ]; then
            return
        elif [ "$selection" -le "${#files[@]}" ]; then
            local selected_file="${files[$((selection-1))]}"
            
            # Display complete results with headers
            echo -e "\n${YELLOW}=== Complete Test Results ===${NC}"
            echo -e "${BLUE}----------------------------------------${NC}"
            
            # Display test configuration
            echo "Test Configuration:"
            grep "^command used:" "$selected_file" 2>/dev/null
            grep "^access pattern:" "$selected_file" 2>/dev/null
            grep "^clients:" "$selected_file" 2>/dev/null
            
            echo -e "\nPerformance Results:"
            echo "access    bw(MiB/s)  IOPS       Latency(s)  block(KiB) xfer(KiB)  open(s)    wr/rd(s)   close(s)   total(s)   iter"
            echo "------    ---------  ----       ----------  ---------- ---------  --------   --------   --------   --------   ----"
            grep "^write\|^read" "$selected_file"
            
            echo -e "\n${BLUE}----------------------------------------${NC}"
            read -p "Press Enter to continue..."
        fi
    else
        echo "No test results found in ${OUTPUT_DIR}"
        read -p "Press Enter to continue..."
    fi
}

# Function to run tests based on number of processes
run_tests_based_on_procs() {
    echo -e "${YELLOW}Running tests based on number of processes (${NUM_PROCS})${NC}"
    if [ "${NUM_PROCS}" -eq 1 ]; then
        echo -e "${BLUE}Selected serial tests based on process count${NC}"
        run_serial_tests
    else
        echo -e "${BLUE}Selected parallel tests based on process count${NC}"
        run_parallel_tests
    fi
    echo -e "${GREEN}Tests completed!${NC}"
}

# Function to get custom parameters
get_custom_parameters() {
    echo -e "${YELLOW}Enter Custom Parameters (press Enter for default):${NC}"
    
    read -p "Transfer Size [${DEFAULT_TRANSFER_SIZE}]: " input
    TRANSFER_SIZE=${input:-$DEFAULT_TRANSFER_SIZE}
    
    read -p "Block Size [${DEFAULT_BLOCK_SIZE}]: " input
    BLOCK_SIZE=${input:-$DEFAULT_BLOCK_SIZE}
    
    read -p "Segments [${DEFAULT_SEGMENTS}]: " input
    SEGMENTS=${input:-$DEFAULT_SEGMENTS}
    
    read -p "Number of Parallel Processes [${DEFAULT_NUM_PROCS}]: " input
    NUM_PROCS=${input:-$DEFAULT_NUM_PROCS}
    
    read -p "Output Directory [${DEFAULT_OUTPUT_DIR}]: " input
    OUTPUT_DIR=${input:-$DEFAULT_OUTPUT_DIR}
    
    read -p "Test File Path [${DEFAULT_TEST_FILE}]: " input
    TEST_FILE_PATH=${input:-$DEFAULT_TEST_FILE}
}

# Function to set recommended parameters
set_recommended_parameters() {
    echo -e "${YELLOW}Setting recommended parameters...${NC}"
    
    # Automatically calculate recommended values based on system
    total_memory=$(free -m | awk '/^Mem:/{print $2}')
#    recommended_block_size=$((total_memory / 8))m  # Use 1/8 of total memory
    recommended_block_size="64m"
    
    TRANSFER_SIZE="4m"  # Good for most systems
    BLOCK_SIZE=${recommended_block_size}
    SEGMENTS="8"
    NUM_PROCS="${DEFAULT_NUM_PROCS}"
    OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}"
    TEST_FILE_PATH="${DEFAULT_TEST_FILE}"
    
    echo -e "${GREEN}Recommended parameters set based on system configuration${NC}"
}

# Function to run block size scaling test
run_block_size_test() {
    echo -e "${YELLOW}Running Serial Block Size Scaling Test${NC}"
    
    # Use serial test parameters
    local NUM_PROCS=1  # Force single process
    local SEGMENTS=8
    
    # Create test directory and files
    local test_name="block_size_test_${TIMESTAMP}"
    local output_dir="${OUTPUT_DIR}/block_size_test_${TIMESTAMP}"
    mkdir -p "$output_dir"
    
    # Create summary files
    local summary_file="${output_dir}/block_size_summary.txt"
    local csv_file="${output_dir}/block_size_data.csv"
    
    # Write headers
    {
        echo "Serial Block Size Scaling Test Results - $(date)"
        echo "System Information:"
        echo "- CPU Model: $(lscpu | grep "Model name" | sed 's/Model name:\s*//')"
        echo "- Memory: $(free -h | grep Mem | awk '{print $2}')"
        echo "- Mode: Serial (Single Process)"
        echo "----------------------------------------"
    } > "$summary_file"
    
    # CSV header
    echo "BlockSize,TransferSize,Operation,Bandwidth(MiB/s),IOPS,Latency(s)" > "$csv_file"
    
    # Block size sequence (powers of 2 from 1MB to 1GB)
    local block_sizes=(
        "1m:64k"    # 1MB block : 64KB transfer
        "2m:64k"    # 2MB block : 64KB transfer
        "4m:64k"    # 4MB block : 64KB transfer
        "8m:64k"    # 8MB block : 64KB transfer
        "16m:64k"   # 16MB block : 64KB transfer
        "32m:64k"   # 32MB block : 64KB transfer
        "64m:64k"   # 64MB block : 64KB transfer
        "128m:64k"  # 128MB block : 64KB transfer
        "256m:64k"  # 256MB block : 64KB transfer
        "512m:64k"  # 512MB block : 64KB transfer
        "1g:64k"    # 1GB block : 64KB transfer
    )
    
    echo -e "\n${BLUE}Serial Block Size Test Plan:${NC}"
    echo "Mode: Serial (Single Process)"
    echo "Will test block sizes from 4KB to 1GB"
    echo "Number of test configurations: ${#block_sizes[@]}"
    echo "Each test includes write and read operations"
    echo -e "Results will be saved to: $output_dir\n"
    
    read -p "Press Enter to start the tests, or Ctrl+C to cancel..."
    
    # Run tests for each block size
    for config in "${block_sizes[@]}"; do
        local block_size=${config%:*}
        local transfer_size=${config#*:}
        
        echo -e "\n${GREEN}Testing block size: $block_size (transfer: $transfer_size)${NC}"
        
        # Create unique test file name
        local test_file="${output_dir}/test_${block_size}"
        local result_file="${output_dir}/result_${block_size}.txt"
        
        # Run IOR test in serial mode
        ior -a POSIX -t $transfer_size -b $block_size -s $segments -F \
            -o $test_file -w -r > "$result_file" 2>&1
        
        if [ $? -eq 0 ]; then
            # Extract results
            local write_bw=$(grep "^write" "$result_file" | awk '{print $2}')
            local write_iops=$(grep "^write" "$result_file" | awk '{print $3}')
            local write_lat=$(grep "^write" "$result_file" | awk '{print $4}')
            local read_bw=$(grep "^read" "$result_file" | awk '{print $2}')
            local read_iops=$(grep "^read" "$result_file" | awk '{print $3}')
            local read_lat=$(grep "^read" "$result_file" | awk '{print $4}')
            
            # Add to CSV
            echo "$block_size,$transfer_size,write,$write_bw,$write_iops,$write_lat" >> "$csv_file"
            echo "$block_size,$transfer_size,read,$read_bw,$read_iops,$read_lat" >> "$csv_file"
            
            # Display results
            echo -e "\nResults for $block_size blocks:"
            echo "Write: $write_bw MB/s ($write_iops IOPS)"
            echo "Read:  $read_bw MB/s ($read_iops IOPS)"
        else
            echo -e "${RED}Test failed for block size $block_size${NC}"
        fi
        
        # Clean up test file
        rm -f "$test_file"*
    done
    
    # Generate summary report
    {
        echo -e "\nBlock Size Scaling Test Summary"
        echo "================================="
        echo -e "\nWrite Performance:"
        echo "Block Size  Bandwidth(MB/s)  IOPS     Latency(s)"
        echo "---------  --------------  -------  -----------"
        awk -F',' '$3=="write" {
            printf "%-9s  %14.1f  %7.1f  %11.6f\n", $1, $4, $5, $6
        }' "$csv_file" | sort -V
        
        echo -e "\nRead Performance:"
        echo "Block Size  Bandwidth(MB/s)  IOPS     Latency(s)"
        echo "---------  --------------  -------  -----------"
        awk -F',' '$3=="read" {
            printf "%-9s  %14.1f  %7.1f  %11.6f\n", $1, $4, $5, $6
        }' "$csv_file" | sort -V
        
        # Find optimal block sizes
        echo -e "\nOptimal Configurations:"
        echo "Write: $(awk -F',' '$3=="write" {if($4>max){max=$4;bs=$1}} END{print bs " (" max " MB/s)"}' "$csv_file")"
        echo "Read:  $(awk -F',' '$3=="read" {if($4>max){max=$4;bs=$1}} END{print bs " (" max " MB/s)"}' "$csv_file")"
        
        # Add performance analysis
        echo -e "\nPerformance Analysis:"
        echo "1. Small Block Performance (4k-64k):"
        echo "   - Best for measuring IOPS and small file performance"
        echo "   - Typically limited by storage system's IOPS capability"
        
        echo -e "\n2. Medium Block Performance (128k-1m):"
        echo "   - Balance between IOPS and bandwidth"
        echo "   - Good for general file system operations"
        
        echo -e "\n3. Large Block Performance (2m-1g):"
        echo "   - Best for measuring maximum sequential bandwidth"
        echo "   - Optimal for large file transfers"
        
    } >> "$summary_file"
    
    echo -e "\n${GREEN}Serial block size scaling test completed!${NC}"
    echo "Summary saved to: $summary_file"
    echo "Raw data saved to: $csv_file"
    
    # Display summary
    echo -e "\n${YELLOW}Test Summary:${NC}"
    cat "$summary_file"
}

# Main function
main() {
    # Check dependencies
    if ! command -v ior &> /dev/null; then
        echo -e "${RED}Error: IOR is not installed${NC}"
        exit 1
    fi
    
    if ! command -v mpirun &> /dev/null; then
        echo -e "${YELLOW}Warning: MPI is not installed. Parallel tests will not work${NC}"
    fi
    
    # Ensure OUTPUT_DIR is set and created at startup
    OUTPUT_DIR=${DEFAULT_OUTPUT_DIR}
    mkdir -p "${OUTPUT_DIR}"
    
    while true; do
        show_menu
        read -p "Select an option: " choice
        
        case $choice in
            1)
                get_custom_parameters
                confirm_parameters && run_tests_based_on_procs
                ;;
            2)
                set_recommended_parameters
                confirm_parameters && run_all_tests
                ;;
            3)
                if [ -z "$TRANSFER_SIZE" ]; then
                    set_recommended_parameters
                fi
                confirm_parameters && run_serial_tests
                ;;
            4)
                if [ -z "$TRANSFER_SIZE" ]; then
                    set_recommended_parameters
                fi
                confirm_parameters && run_parallel_tests
                ;;
            5)
                if [ -z "$TRANSFER_SIZE" ]; then
                    set_recommended_parameters
                fi
                confirm_parameters && run_thread_scaling_tests
                ;;
            6)
                # Block size test uses its own parameters, skip confirmation
                run_block_size_test
                ;;
            7)
                view_results
                ;;
            8)
                echo -e "${GREEN}Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Run the main function
main
