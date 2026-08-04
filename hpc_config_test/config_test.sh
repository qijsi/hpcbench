# !/bin/bash
##########################################################################
# CPU 信息
OUTPUT_FILE="cpu_info.txt"

# 从lscpu命令中提取信息
ARCHITECTURE=$(lscpu | grep "Architecture:" | awk '{print $2}')
MODEL_NAME=$(lscpu | grep -m1 "Model name:" | sed 's/Model name:[[:space:]]*//')
SOCKETS=$(lscpu | grep "Socket(s):" | awk '{print $2}')
CORES_PER_SOCKET=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')
TOTAL_PHYSICAL_CORES=$((SOCKETS * CORES_PER_SOCKET))
CPU_MHZ=$(lscpu | grep -E "CPU MHz:|CPU max MHz:" | head -n1 | awk '{print $3}')
CPU_MHZ=$(printf "%.0f" "$CPU_MHZ")
NUMA_NODES=$(lscpu | grep "NUMA node(s):" | awk '{print $3}')

# 输出到终端
echo "CPU配置信息："
echo "--------------------------------------------------------------"
echo "处理器型号: $MODEL_NAME"
echo "处理器数量: $SOCKETS"
echo "处理器核心数: $CORES_PER_SOCKET"
echo "总物理核心数: $TOTAL_PHYSICAL_CORES"
echo "处理器架构: $ARCHITECTURE"
echo "处理器主频: $CPU_MHZ MHz"
echo "NUMA节点数: $NUMA_NODES"
echo "--------------------------------------------------------------"

# 保存到文件
{
    echo "CPU配置"
    echo "--------------------------------------------------------------"
    echo "处理器型号: $MODEL_NAME"
    echo "处理器数量: $SOCKETS"
    echo "处理器核心数: $CORES_PER_SOCKET"
    echo "总物理核心数: $TOTAL_PHYSICAL_CORES"
    echo "处理器架构: $ARCHITECTURE"
    echo "处理器主频: $CPU_MHZ MHz"
    echo "NUMA节点数: $NUMA_NODES"
    echo "--------------------------------------------------------------"
} > "$OUTPUT_FILE"

echo "CPU配置信息已保存到文件: $OUTPUT_FILE"
echo ""
sleep 3s
##########################################################################
# 加速卡配置信息
# 加载DTK环境
source /opt/dtk-25.04.4/env.sh
# 执行rocminfo命令并将输出保存到tmp.txt
rocminfo > tmp.txt


INPUT_FILE="tmp.txt"
OUTPUT_FILE="dcu_info.txt"

# 提示开始
# echo "正在提取DCU加速卡信息..."

# 输出头部信息到终端
echo "加速卡配置信息："
echo "--------------------------------------------------------------"
printf "%-4s %-8s %-8s %-10s %-9s\n" "序号" "名称" "计算单元" "主频(MHz)" "显存(GB)"
echo "--------------------------------------------------------------"

# 初始化输出文件
{
  echo "DCU 加速卡信息概览："
  echo "--------------------------------------------------------------"
  printf "%-4s %-8s %-8s %-10s %-9s\n" "序号" "名称" "计算单元" "主频(MHz)" "显存(GB)"
  echo "--------------------------------------------------------------"
} > "$OUTPUT_FILE"

# awk 处理，带序号、单位转换
awk -v output="$OUTPUT_FILE" '
BEGIN {
  RS="\\*{7,}"
  FS="\n"
  count=0
}
{
  for (i=1; i<=NF; i++) {
    if ($i ~ /Device Type:[[:space:]]*HCU/) {
      name=cu=clock=maxmem=""
      maxmem = 0

      for (j=1; j<=NF; j++) {
        if ($j ~ /Marketing Name:/) {
          sub(/.*Marketing Name:[[:space:]]*/, "", $j); 
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $j);  # 移除首尾空格
          name=$j
        }
        if ($j ~ /Compute Unit:/) {
          sub(/.*Compute Unit:[[:space:]]*/, "", $j); 
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $j);  # 移除首尾空格
          cu=$j
        }
        if ($j ~ /Max Clock Freq\..*:/) {
          sub(/.*Max Clock Freq\..*:[[:space:]]*/, "", $j); 
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $j);  # 移除首尾空格
          clock=$j
        }
        if ($j ~ /Size:[[:space:]]*[0-9]+.*KB/) {
          match($j, /Size:[[:space:]]*([0-9]+)/, m)
          if (m[1] > maxmem) maxmem = m[1]
        }
      }

      count++
      mem_gb = sprintf("%.0f", maxmem / 1024 / 1024)
      

      # 打印到终端
      printf "%-4s %-10s %-6s %-8s %-10s\n", count, name, cu, clock, mem_gb

      # 写入文件
      printf "%-4s %-10s %-6s %-8s %-10s\n", count, name, cu, clock, mem_gb >> output
    }
  }
}
' "$INPUT_FILE"

# 完成提示
echo "--------------------------------------------------------------"
# echo "共检测到 DCU 加速卡数量：$(grep -c 'Device Type:[[:space:]]*HCU' "$INPUT_FILE")"
echo "加速卡配置信息已保存至文件：$OUTPUT_FILE"
echo ""
# 删除文件
rm tmp.txt

sleep 3s
##########################################################################
# 内存配置信息
OUTPUT_FILE="memory_info.txt"

# 检查是否以root运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行此脚本以获取完整内存信息"
    exit 1
fi

# 获取内存条信息
MEMORY_MODULES=$(dmidecode | grep -P -A5 "Memory\s+Device" | grep Size | grep -v Range)

# 统计内存条数量和单个容量
NUM_OF_DEVICES=$(echo "$MEMORY_MODULES" | wc -l)
SINGLE_SIZE=$(echo "$MEMORY_MODULES" | head -n1 | awk '{print $2,$3}')

# 计算总内存量（数量*单个容量）
TOTAL_SIZE_GB=$(echo "$NUM_OF_DEVICES * $(echo "$SINGLE_SIZE" | awk '{print $1}')" | bc)
TOTAL_SIZE="$TOTAL_SIZE_GB GB"

# 获取其他内存信息
MEMORY_INFO=$(dmidecode -t memory 2>/dev/null)

# 提取内存类型（从第一个实际安装的内存条获取）
MEMORY_TYPE=$(dmidecode | grep -P -A10 "Memory\s+Device" | grep "Type:" | grep -v "Unknown" | head -n1 | awk '{print $2}')
[ -z "$MEMORY_TYPE" ] && MEMORY_TYPE="Unknown"

# 提取位宽和速度信息
DATA_WIDTH=$(echo "$MEMORY_INFO" | awk '/Memory Device$/ {device=1} device && /Data Width:/ {print $3; exit}')
SPEED=$(echo "$MEMORY_INFO" | awk '/Memory Device$/ {device=1} device && /Speed:/ {print $2,$3; exit}')

# 输出内存配置信息
echo "内存配置信息:"
echo "----------------------------------------"
printf "%-20s %s\n" "内存类型:" "$MEMORY_TYPE"
printf "%-20s %s\n" "单个内存条容量:" "$SINGLE_SIZE"
printf "%-20s %s\n" "内存条数量:" "$NUM_OF_DEVICES"
printf "%-20s %s bits\n" "数据位宽:" "$DATA_WIDTH"
printf "%-20s %s\n" "内存速度:" "$SPEED"
printf "%-20s %s\n" "系统总内存(计算):" "$TOTAL_SIZE"
echo "----------------------------------------"

# 保存到文件
{
    echo "内存配置详细信息:"
    echo "----------------------------------------"
    printf "%-20s %s\n" "内存类型:" "$MEMORY_TYPE"
    printf "%-20s %s\n" "单个内存条容量:" "$SINGLE_SIZE"
    printf "%-20s %s\n" "内存条数量:" "$NUM_OF_DEVICES"
    printf "%-20s %s bits\n" "数据位宽:" "$DATA_WIDTH"
    printf "%-20s %s\n" "内存速度:" "$SPEED"
    printf "%-20s %s\n" "系统总内存:" "$TOTAL_SIZE"
    echo "----------------------------------------"
    
    # 添加详细内存条信息
    echo ""
    echo "各内存条详细信息:"
    echo "----------------------------------------"
    echo "$MEMORY_MODULES" | awk '{print NR".",$0}'
} > "$OUTPUT_FILE"

echo "内存配置信息已保存到文件: $OUTPUT_FILE"
echo ""
sleep 3s
##########################################################################
# 存储配置信息
OUTPUT_FILE="storage_info.txt"

# 获取所有磁盘设备列表（排除分区）
DISKS=$(lsblk -d -o NAME,TYPE | grep 'disk' | awk '{print $1}')

# 初始化存储统计数组
declare -A storage_stats

# 分析每个磁盘
for disk in $DISKS; do
    # 获取磁盘大小(GB)
    size_gb=$(lsblk -b -d -o SIZE /dev/$disk | tail -1 | awk '{printf "%.0f", $1/1000/1000/1000}')
    
    # 获取磁盘类型（NVMe/SSD/HDD）
    if [[ $disk == nvme* ]]; then
        type="NVMe SSD"
    else
        rotation=$(cat /sys/block/$disk/queue/rotational 2>/dev/null)
        if [[ $rotation -eq 0 ]]; then
            type="SSD"
        else
            type="HDD"
        fi
    fi
    
    # 获取I/O容量（从fdisk获取）
    io_size=$(fdisk -l /dev/$disk 2>/dev/null | grep "I/O size" | awk '{print $4}')
    [ -z "$io_size" ] && io_size="N/A" || io_size="${io_size} bytes"
    
    # 生成容量类型键
    key="${type}_${size_gb}GB"
    
    # 更新统计信息
    if [ -z "${storage_stats[$key]}" ]; then
        storage_stats[$key]="type=$type;size=$size_gb;count=1;io=$io_size"
    else
        count=$(echo "${storage_stats[$key]}" | grep -oP 'count=\K\d+')
        new_count=$((count + 1))
        storage_stats[$key]=$(echo "${storage_stats[$key]}" | sed "s/count=$count/count=$new_count/")
    fi
done

# 输出详细设备信息
echo "存储配置信息："
echo "------------------------------------------------------------"
printf "%-10s %-15s %-15s %-20s\n" "设备名称" "存储类型" "大小(GB)" "I/O大小"
echo "------------------------------------------------------------"

for disk in $DISKS; do
    size_gb=$(lsblk -b -d -o SIZE /dev/$disk | tail -1 | awk '{printf "%.0f", $1/1000/1000/1000}')
    
    if [[ $disk == nvme* ]]; then
        type="NVMe SSD"
    else
        rotation=$(cat /sys/block/$disk/queue/rotational 2>/dev/null)
        if [[ $rotation -eq 0 ]]; then
            type="SSD"
        else
            type="HDD"
        fi
    fi
    
    io_size=$(fdisk -l /dev/$disk 2>/dev/null | grep "I/O size" | awk '{print $4}')
    [ -z "$io_size" ] && io_size="N/A" || io_size="${io_size} bytes"
    
    printf "%-10s %-15s %-15s %-20s\n" "/dev/$disk" "$type" "$size_gb" "$io_size"
done

# 输出汇总信息（按容量分类）
echo ""
echo "存储设备分类汇总:"
echo "------------------------------------------------------------"
printf "%-15s %-15s %-10s %-20s\n" "存储类型" "大小(GB)" "数量" "I/O大小"
echo "------------------------------------------------------------"

for key in "${!storage_stats[@]}"; do
    type=$(echo "${storage_stats[$key]}" | grep -oP 'type=\K[^;]+')
    size=$(echo "${storage_stats[$key]}" | grep -oP 'size=\K[^;]+')
    count=$(echo "${storage_stats[$key]}" | grep -oP 'count=\K[^;]+')
    io=$(echo "${storage_stats[$key]}" | grep -oP 'io=\K[^;]+')
    
    printf "%-15s %-15s %-10s %-20s\n" "$type" "$size" "$count" "$io"
done | sort -k2n  # 按容量大小排序
echo "------------------------------------------------------------"
# 保存到文件
{
    echo "存储配置信息:"
    echo "------------------------------------------------------------"
    printf "%-10s %-15s %-15s %-20s\n" "设备名称" "存储类型" "大小(GB)" "I/O大小"
    echo "------------------------------------------------------------"
    
    for disk in $DISKS; do
        size_gb=$(lsblk -b -d -o SIZE /dev/$disk | tail -1 | awk '{printf "%.1f", $1/1024/1024/1024}')
        
        if [[ $disk == nvme* ]]; then
            type="NVMe SSD"
        else
            rotation=$(cat /sys/block/$disk/queue/rotational 2>/dev/null)
            if [[ $rotation -eq 0 ]]; then
                type="SSD"
            else
                type="HDD"
            fi
        fi
        
        io_size=$(fdisk -l /dev/$disk 2>/dev/null | grep "I/O size" | awk '{print $4}')
        [ -z "$io_size" ] && io_size="N/A" || io_size="${io_size} bytes"
        
        printf "%-10s %-15s %-15s %-20s\n" "/dev/$disk" "$type" "$size_gb" "$io_size"
    done
    echo ""
    echo "存储设备分类汇总:"
    echo "------------------------------------------------------------"
    printf "%-15s %-15s %-10s %-20s\n" "存储类型" "大小(GB)" "数量" "I/O大小"
    echo "------------------------------------------------------------"
    
    for key in "${!storage_stats[@]}"; do
        type=$(echo "${storage_stats[$key]}" | grep -oP 'type=\K[^;]+')
        size=$(echo "${storage_stats[$key]}" | grep -oP 'size=\K[^;]+')
        count=$(echo "${storage_stats[$key]}" | grep -oP 'count=\K[^;]+')
        io=$(echo "${storage_stats[$key]}" | grep -oP 'io=\K[^;]+')
        
        printf "%-15s %-15s %-10s %-20s\n" "$type" "$size" "$count" "$io"
    done | sort -k2n
    echo "------------------------------------------------------------"
} > "$OUTPUT_FILE"


echo "存储配置信息已保存到文件: $OUTPUT_FILE"
echo ""
sleep 3s
##########################################################################
# 网络配置信息
OUTPUT_FILE="network_info.txt"

# 获取所有物理以太网接口列表（排除lo、docker和虚拟接口）
ETH_INTERFACES=$(ip link | awk -F': ' '$0 !~ /lo|docker|vir|^[^0-9]/ {print $2}')

# 获取所有InfiniBand接口列表
IB_INTERFACES=$(ibstat 2>/dev/null | grep "^CA '" | sed "s/CA '//;s/'//")

# 输出表头
echo "网络配置信息："
echo "--------------------------------------------------"
printf "%-10s %-15s %-8s %-15s\n" "网络名称" "接口类型" "最大传输单元MTU" "理论带宽(Gb/s)"
echo "--------------------------------------------------"

# 处理以太网接口
for dev in $ETH_INTERFACES; do
    # 获取接口类型
    if_type=$(ip link show $dev | grep -oP '(?<=link/)[^ ]+')
    
    # 获取MTU值
    mtu=$(ip link show $dev | grep -oP '(?<=mtu )\d+')
    
    # 获取理论带宽并转换为Gb/s
    speed_mbps=$(ethtool $dev 2>/dev/null | grep -i "Speed:" | awk '{print $2}' | sed 's/Mb\/s//')
    if [ -n "$speed_mbps" ]; then
        speed_gbps=$(awk -v mb=$speed_mbps 'BEGIN{printf "%.1f", mb/1000}')
    else
        speed_gbps="N/A"
    fi
    
    # 输出以太网信息
    printf "%-10s %-15s %-8s %-15s\n" "$dev" "$if_type" "$mtu" "$speed_gbps"
done

# 处理InfiniBand接口
for dev in $IB_INTERFACES; do
    # 获取IB接口速率
    ib_rate=$(ibstat $dev 2>/dev/null | grep "Rate:" | awk '{print $2}')
    [ -z "$ib_rate" ] && ib_rate="N/A"
    
    # 输出IB信息
    printf "%-10s %-15s %-8s %-15s\n" "$dev" "InfiniBand" "N/A" "$ib_rate"
done

# 保存到文件
{
    echo "网络配置信息："
    echo "--------------------------------------------------"
    printf "%-10s %-15s %-8s %-15s\n" "网络名称" "接口类型" "最大传输单元MTU" "理论带宽(Gb/s)"
    echo "--------------------------------------------------"
    
    # 以太网接口
    for dev in $ETH_INTERFACES; do
        if_type=$(ip link show $dev | grep -oP '(?<=link/)[^ ]+')
        mtu=$(ip link show $dev | grep -oP '(?<=mtu )\d+')
        speed_mbps=$(ethtool $dev 2>/dev/null | grep -i "Speed:" | awk '{print $2}' | sed 's/Mb\/s//')
        if [ -n "$speed_mbps" ]; then
            speed_gbps=$(awk -v mb=$speed_mbps 'BEGIN{printf "%.1f", mb/1000}')
        else
            speed_gbps="N/A"
        fi
        printf "%-10s %-15s %-8s %-15s\n" "$dev" "$if_type" "$mtu" "$speed_gbps"
    done
    
    # InfiniBand接口
    for dev in $IB_INTERFACES; do
        ib_rate=$(ibstat $dev 2>/dev/null | grep "Rate:" | awk '{print $2}')
        [ -z "$ib_rate" ] && ib_rate="N/A"
        printf "%-10s %-15s %-8s %-15s\n" "$dev" "InfiniBand" "N/A" "$ib_rate"
    done
    echo "--------------------------------------------------"
} > "$OUTPUT_FILE"

echo "--------------------------------------------------"
echo "网络配置信息已保存到文件: $OUTPUT_FILE"
echo ""

sleep 3s
##########################################################################
# 软件配置信息
OUTPUT_FILE="software_info.txt"

# 提取操作系统版本（从/proc/version中的gcc信息）
OS_VERSION=$(cat /proc/version | grep -oP "SugonOS [0-9.]+-[0-9.]+")

# 提取内核版本
KERNEL_VERSION=$(uname -r)

# 提取gcc版本
GCC_VERSION=$(gcc --version | head -n1 | awk '{print $3}')

# 提取hy-smi版本
HY_SMI_VERSION=$(hy-smi --version | awk '{print $2}' | tr -d '()')

# 输出到终端
echo "软件配置信息："
echo "--------------------------------------------------"
echo "操作系统版本: $OS_VERSION"
echo "内核版本: $KERNEL_VERSION"
echo "C/C++编译器版本: gcc $GCC_VERSION"
echo "加速器监控软件版本: hy-smi $HY_SMI_VERSION"
echo "--------------------------------------------------"

# 保存到文件
{
    echo "软件配置信息："
    echo "--------------------------------------------------"
    echo "操作系统版本: $OS_VERSION"
    echo "内核版本: $KERNEL_VERSION"
    echo "C/C++编译器版本: gcc $GCC_VERSION"
    echo "加速器监控软件版本: hy-smi $HY_SMI_VERSION"
    echo "--------------------------------------------------"
} > "$OUTPUT_FILE"

echo "软件配置信息已保存到文件: $OUTPUT_FILE"
echo ""