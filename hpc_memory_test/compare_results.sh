#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 || "$#" -gt 5 ]]; then
    echo "Usage: $0 <result_dir_1> <result_dir_2> <result_dir_3> [tolerance_pct] [output_csv]" >&2
    echo "Example: $0 run1 run2 run3 5 comparison.csv" >&2
    exit 2
fi

directories=("$1" "$2" "$3")
tolerance=${4:-5}
output_file=${5:-comparison_results.csv}

if ! [[ "$tolerance" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v value="$tolerance" 'BEGIN { exit !(value >= 0) }'; then
    echo "Invalid tolerance: $tolerance" >&2
    exit 2
fi

for directory in "${directories[@]}"; do
    if [[ ! -d "$directory" ]]; then
        echo "Result directory not found: $directory" >&2
        exit 2
    fi
done

temp_dir=$(mktemp -d)
comparison_status=0
trap 'rm -rf "$temp_dir"' EXIT

for index in 0 1 2; do
    directory=${directories[$index]}
    directory=${directory%/}
    output_rows="$temp_dir/normalized_$index.tsv"
    : > "$output_rows"

    while IFS= read -r -d '' csv_file; do
        relative_path=${csv_file#"$directory"/}
        awk -F, -v relative_path="$relative_path" '
            NR > 1 && NF >= 6 && $1 != "" {
                mode = (NF >= 7 && $7 != "") ? $7 : "legacy"
                key = relative_path SUBSEP $1 SUBSEP $2 SUBSEP mode
                count[key]++
                sum[key, 1] += $3
                sum[key, 2] += $4
                sum[key, 3] += $5
                sum[key, 4] += $6
            }
            END {
                for (key in count) {
                    split(key, fields, SUBSEP)
                    printf "%s\t%s\t%s\t%s\t%.6f\t%.6f\t%.6f\t%.6f\n",
                        fields[1], fields[2], fields[3], fields[4],
                        sum[key, 1] / count[key], sum[key, 2] / count[key],
                        sum[key, 3] / count[key], sum[key, 4] / count[key]
                }
            }
        ' "$csv_file" >> "$output_rows"
    done < <(find "$directory" -type f -name results.csv -print0 | sort -z)
done

{
    echo "Relative_CSV,Stride,Threads,Mode,Metric,Mean,Dir1,Dir2,Dir3,Error_Rate_Pct,Tolerance_Pct,Status"
    awk -F'\t' -v tolerance="$tolerance" \
        -v dir1="${directories[0]}" -v dir2="${directories[1]}" -v dir3="${directories[2]}" '
        BEGIN {
            metric_count = split("Copy Scale Add Triad", metrics, " ")
            available_count = 0
        }
        {
            key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
            if (!(key in count)) count[key] = 0
            count[key]++
            for (metric_index = 1; metric_index <= 4; metric_index++)
                value[key, count[key], metric_index] = $(metric_index + 4)
        }
        END {
            for (key in count) {
                split(key, fields, SUBSEP)
                for (metric_index = 1; metric_index <= metric_count; metric_index++) {
                    sum = 0
                    minimum = ""
                    maximum = ""
                    available_count = 0

                    for (run_index = 1; run_index <= count[key]; run_index++) {
                        current = value[key, run_index, metric_index] + 0
                        sum += current
                        available_count++
                        if (minimum == "" || current < minimum) minimum = current
                        if (current > maximum) maximum = current
                    }

                    if (available_count == 0) {
                        mean = 0
                        error_rate = "N/A"
                        status = "MISSING"
                    } else {
                        mean = sum / available_count
                        if (available_count == 3 && mean != 0) {
                            error_rate = (maximum - minimum) * 100.0 / mean
                            status = (error_rate <= tolerance) ? "PASS" : "FAIL"
                        } else {
                            error_rate = "N/A"
                            status = (available_count == 3 && maximum == minimum) ? "PASS" : "FAIL"
                        }
                    }

                    value_1 = (available_count >= 1) ? sprintf("%.2f", value[key, 1, metric_index]) : "MISSING"
                    value_2 = (available_count >= 2) ? sprintf("%.2f", value[key, 2, metric_index]) : "MISSING"
                    value_3 = (available_count >= 3) ? sprintf("%.2f", value[key, 3, metric_index]) : "MISSING"
                    mean_text = (available_count > 0) ? sprintf("%.2f", mean) : "MISSING"
                    error_text = (error_rate == "N/A") ? error_rate : sprintf("%.2f", error_rate)

                    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
                        fields[1], fields[2], fields[3], fields[4], metrics[metric_index],
                        mean_text, value_1, value_2, value_3, error_text, tolerance, status

                    if (status == "MISSING") missing_count++
                    else if (status == "FAIL") failed_count++
                    else passed_count++
                }
            }

            printf "SUMMARY,,,,,PASS=%d,FAIL=%d,MISSING=%d,,,,\n", passed_count, failed_count, missing_count > "/dev/stderr"
            exit (failed_count > 0 || missing_count > 0) ? 1 : 0
        }
    ' "$temp_dir/normalized_0.tsv" "$temp_dir/normalized_1.tsv" "$temp_dir/normalized_2.tsv" || comparison_status=1
} > "$output_file"

:
if command -v column >/dev/null 2>&1; then
    column -s, -t < "$output_file"
else
    cat "$output_file"
fi
exit "$comparison_status"
