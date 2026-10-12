/*
 * Gauss-Seidel iterative solver for Ax = b (HIP + MPI)
 *
 * Build:
 *   mpicxx -x hip -O3 -o gauss_seidel gauss_seidel.hip
 *
 * Run:
 *   mpirun -np <N> ./gauss_seidel [n] [max_iters] [tol]
 *   e.g. mpirun -np 4 ./gauss_seidel 256 5000 1e-8
 */

#include <hip/hip_runtime.h>
#include <mpi.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define HIP_CHECK(call)                                                                            \
    do {                                                                                           \
        hipError_t err__ = (call);                                                                 \
        if (err__ != hipSuccess) {                                                                 \
            std::fprintf(stderr, "HIP error %s:%d: %s\n", __FILE__, __LINE__,                       \
                         hipGetErrorString(err__));                                                 \
            std::exit(EXIT_FAILURE);                                                               \
        }                                                                                          \
    } while (0)

// ---------------------------------------------------------------------------
// One Gauss-Seidel sweep over a contiguous row range [row_start, row_end).
// Each thread handles one row (parallel across rows).
// ---------------------------------------------------------------------------
__global__ void gaussSeidelSweep(const double* __restrict__ A,
                                 const double* __restrict__ b,
                                 double* __restrict__ x,
                                 int n,
                                 int row_start,
                                 int row_end)
{
    int local_i = blockIdx.x * blockDim.x + threadIdx.x;
    if (local_i >= row_end - row_start)
        return;

    int i = row_start + local_i;

    double sigma = 0.0;
    const double* row = A + static_cast<size_t>(i) * n;
    for (int j = 0; j < n; ++j) {
        if (j != i) {
            sigma += row[j] * x[j];
        }
    }
    x[i] = (b[i] - sigma) / row[i];
}

// ---------------------------------------------------------------------------
// Parallel residual: r[i] = b[i] - sum_j A[i,j] * x[j]
// ---------------------------------------------------------------------------
__global__ void residualKernel(const double* __restrict__ A,
                               const double* __restrict__ b,
                               const double* __restrict__ x,
                               double* __restrict__ r,
                               int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) {
        return;
    }

    double sum = 0.0;
    const double* row = A + static_cast<size_t>(i) * n;
    for (int j = 0; j < n; ++j) {
        sum += row[j] * x[j];
    }
    r[i] = b[i] - sum;
}

// Block reduction of sum of squares -> partial[blockIdx.x]
__global__ void sumSquaresPartial(const double* __restrict__ r, double* __restrict__ partial, int n)
{
    extern __shared__ double sdata[];
    int tid = threadIdx.x;
    int i   = blockIdx.x * blockDim.x + threadIdx.x;

    double val = 0.0;
    if (i < n) {
        val = r[i] * r[i];
    }
    sdata[tid] = val;
    __syncthreads();

    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }

    if (tid == 0) {
        partial[blockIdx.x] = sdata[0];
    }
}

static double norm2Host(const std::vector<double>& v)
{
    double s = 0.0;
    for (double x : v) {
        s += x * x;
    }
    return std::sqrt(s);
}

// Build a strictly diagonally dominant SPD-ish matrix with known solution x* = 1.
static void buildSystem(int n, std::vector<double>& A, std::vector<double>& b, std::vector<double>& xExact)
{
    A.assign(static_cast<size_t>(n) * n, 0.0);
    b.assign(n, 0.0);
    xExact.assign(n, 1.0);

    for (int i = 0; i < n; ++i) {
        double rowSum = 0.0;
        for (int j = 0; j < n; ++j) {
            if (i == j) {
                continue;
            }
            double aij = 1.0 / (std::abs(i - j) + 2.0);
            A[static_cast<size_t>(i) * n + j] = aij;
            rowSum += std::abs(aij);
        }
        A[static_cast<size_t>(i) * n + i] = rowSum + 1.0; // diagonal dominance
    }

    // b = A * xExact
    for (int i = 0; i < n; ++i) {
        double sum = 0.0;
        for (int j = 0; j < n; ++j) {
            sum += A[static_cast<size_t>(i) * n + j] * xExact[j];
        }
        b[i] = sum;
    }
}

static double deviceResidualNorm(const double* d_A,
                                 const double* d_b,
                                 const double* d_x,
                                 double* d_r,
                                 double* d_partial,
                                 std::vector<double>& h_partial,
                                 int n,
                                 int threads)
{
    int blocks = (n + threads - 1) / threads;
    residualKernel<<<blocks, threads>>>(d_A, d_b, d_x, d_r, n);
    HIP_CHECK(hipGetLastError());

    sumSquaresPartial<<<blocks, threads, threads * sizeof(double)>>>(d_r, d_partial, n);
    HIP_CHECK(hipGetLastError());

    h_partial.resize(blocks);
    HIP_CHECK(hipMemcpy(h_partial.data(), d_partial, blocks * sizeof(double), hipMemcpyDeviceToHost));

    double sum = 0.0;
    for (double p : h_partial) {
        sum += p;
    }
    return std::sqrt(sum);
}

// ---------------------------------------------------------------------------
// Helper: compute local residual norm (only over local rows)
// ---------------------------------------------------------------------------
static double localResidualNorm(const double* d_A,
                                const double* d_b,
                                const double* d_x,
                                double* d_r,
                                double* d_partial,
                                std::vector<double>& h_partial,
                                int n,
                                int threads,
                                int row_start,
                                int row_end)
{
    int blocks = (n + threads - 1) / threads;
    residualKernel<<<blocks, threads>>>(d_A, d_b, d_x, d_r, n);
    HIP_CHECK(hipGetLastError());

    // Sum squares only over local rows [row_start, row_end)
    int local_n = row_end - row_start;
    int local_blocks = (local_n + threads - 1) / threads;
    sumSquaresPartial<<<local_blocks, threads, threads * sizeof(double)>>>(d_r + row_start, d_partial, local_n);
    HIP_CHECK(hipGetLastError());

    h_partial.resize(local_blocks);
    HIP_CHECK(hipMemcpy(h_partial.data(), d_partial, local_blocks * sizeof(double), hipMemcpyDeviceToHost));

    double sum = 0.0;
    for (double p : h_partial) {
        sum += p;
    }
    return sum;
}

int main(int argc, char** argv)
{
    MPI_Init(&argc, &argv);

    int rank = 0, num_ranks = 1;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &num_ranks);

    MPI_Comm local_comm;
    MPI_Comm_split_type(MPI_COMM_WORLD, MPI_COMM_TYPE_SHARED, rank,
                        MPI_INFO_NULL, &local_comm);
    int local_rank = 0;
    MPI_Comm_rank(local_comm, &local_rank);

    int device_count = 0;
    HIP_CHECK(hipGetDeviceCount(&device_count));
    if (device_count == 0) {
        if (rank == 0)
            std::fprintf(stderr, "No HIP devices available\n");
        MPI_Abort(MPI_COMM_WORLD, EXIT_FAILURE);
    }
    int gpu_id = local_rank % device_count;
    HIP_CHECK(hipSetDevice(gpu_id));
    MPI_Comm_free(&local_comm);

    int    n         = (argc > 1) ? std::atoi(argv[1]) : 128;
    int    maxIters  = (argc > 2) ? std::atoi(argv[2]) : 5000;
    double tol       = (argc > 3) ? std::atof(argv[3]) : 1e-8;
    const int threads = 256;

    if (n <= 0 || maxIters <= 0 || tol <= 0.0) {
        if (rank == 0) {
            std::fprintf(stderr, "Usage: %s [n] [max_iters] [tol]\n", argv[0]);
        }
        MPI_Finalize();
        return EXIT_FAILURE;
    }

    if (rank == 0) {
        std::printf("Gauss-Seidel (HIP + MPI): n=%d, maxIters=%d, tol=%.1e, ranks=%d\n",
                    n, maxIters, tol, num_ranks);
    }

    // ------------------------------------------------------------------
    // Build system on every rank (same system)
    // ------------------------------------------------------------------
    std::vector<double> h_A, h_b, h_xExact, h_x(n, 0.0);
    buildSystem(n, h_A, h_b, h_xExact);

    const size_t bytesA = static_cast<size_t>(n) * n * sizeof(double);
    const size_t bytesV = static_cast<size_t>(n) * sizeof(double);

    int blocks = (n + threads - 1) / threads;

    double *d_A = nullptr, *d_b = nullptr, *d_x = nullptr, *d_r = nullptr, *d_partial = nullptr;

    HIP_CHECK(hipMalloc(&d_A, bytesA));
    HIP_CHECK(hipMalloc(&d_b, bytesV));
    HIP_CHECK(hipMalloc(&d_x, bytesV));
    HIP_CHECK(hipMalloc(&d_r, bytesV));
    HIP_CHECK(hipMalloc(&d_partial, blocks * sizeof(double)));

    HIP_CHECK(hipMemcpy(d_A, h_A.data(), bytesA, hipMemcpyHostToDevice));
    HIP_CHECK(hipMemcpy(d_b, h_b.data(), bytesV, hipMemcpyHostToDevice));
    HIP_CHECK(hipMemcpy(d_x, h_x.data(), bytesV, hipMemcpyHostToDevice));

    // ------------------------------------------------------------------
    // Determine local row range for this rank
    // ------------------------------------------------------------------
    int rows_per_rank = n / num_ranks;
    int extra = n % num_ranks;
    int row_start = rank * rows_per_rank + std::min(rank, extra);
    int row_end = row_start + rows_per_rank + (rank < extra ? 1 : 0);

    // ------------------------------------------------------------------
    // Timing
    // ------------------------------------------------------------------
    hipEvent_t t0, t1;
    HIP_CHECK(hipEventCreate(&t0));
    HIP_CHECK(hipEventCreate(&t1));
    HIP_CHECK(hipEventRecord(t0));

    std::vector<double> h_partial;
    double res0 = deviceResidualNorm(d_A, d_b, d_x, d_r, d_partial, h_partial, n, threads);
    double res  = res0;
    int    iter = 0;

    for (iter = 0; iter < maxIters; ++iter) {
        if (res < tol) {
            break;
        }

        // Local Gauss-Seidel sweep over this rank's rows
        int local_n = row_end - row_start;
        int local_blocks = (local_n + threads - 1) / threads;
        gaussSeidelSweep<<<local_blocks, threads>>>(d_A, d_b, d_x, n, row_start, row_end);
        HIP_CHECK(hipGetLastError());
        HIP_CHECK(hipDeviceSynchronize());

        // Synchronize x across all ranks (block-Jacobi style)
        // Each rank updated its own rows; gather all updated values.
        {
            // Copy current x from device to host first
            HIP_CHECK(hipMemcpy(h_x.data(), d_x, bytesV, hipMemcpyDeviceToHost));

            // Gather local row counts and displacements
            std::vector<int> recv_counts(num_ranks);
            std::vector<int> recv_displs(num_ranks);
            int local_count = row_end - row_start;
            MPI_Allgather(&local_count, 1, MPI_INT, recv_counts.data(), 1, MPI_INT, MPI_COMM_WORLD);
            recv_displs[0] = 0;
            for (int i = 1; i < num_ranks; ++i) {
                recv_displs[i] = recv_displs[i - 1] + recv_counts[i - 1];
            }

            // Gather updated x values from all ranks
            MPI_Allgatherv(
                MPI_IN_PLACE, 0, MPI_DATATYPE_NULL,
                h_x.data(), recv_counts.data(), recv_displs.data(), MPI_DOUBLE,
                MPI_COMM_WORLD);
        }

        // Push updated x back to device
        HIP_CHECK(hipMemcpy(d_x, h_x.data(), bytesV, hipMemcpyHostToDevice));

        // Compute global residual
        double local_res = localResidualNorm(d_A, d_b, d_x, d_r, d_partial, h_partial, n, threads, row_start, row_end);
        double global_res_sq = 0.0;
        MPI_Allreduce(&local_res, &global_res_sq, 1, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD);
        res = std::sqrt(global_res_sq);

        if ((iter + 1) % 100 == 0 || res < tol) {
            if (rank == 0) {
                std::printf("  iter %5d  ||r|| = %.6e\n", iter + 1, res);
            }
        }
    }

    HIP_CHECK(hipEventRecord(t1));
    HIP_CHECK(hipEventSynchronize(t1));
    float ms = 0.0f;
    HIP_CHECK(hipEventElapsedTime(&ms, t0, t1));

    HIP_CHECK(hipMemcpy(h_x.data(), d_x, bytesV, hipMemcpyDeviceToHost));

    double err = 0.0;
    for (int i = 0; i < n; ++i) {
        double d = h_x[i] - h_xExact[i];
        err += d * d;
    }
    err = std::sqrt(err);

    if (rank == 0) {
        std::printf("Done in %d iterations, time = %.3f ms\n", iter, ms);
        std::printf("Initial ||r|| = %.6e, final ||r|| = %.6e\n", res0, res);
        std::printf("||x - x*||_2 = %.6e  (exact x*_i = 1)\n", err);
        std::printf("x[0..4] =");
        for (int i = 0; i < n && i < 5; ++i) {
            std::printf(" %.8f", h_x[i]);
        }
        std::printf("\n");
    }

    HIP_CHECK(hipEventDestroy(t0));
    HIP_CHECK(hipEventDestroy(t1));
    HIP_CHECK(hipFree(d_A));
    HIP_CHECK(hipFree(d_b));
    HIP_CHECK(hipFree(d_x));
    HIP_CHECK(hipFree(d_r));
    HIP_CHECK(hipFree(d_partial));

    int success = (res < tol && err < 1e-4) ? 1 : 0;
    int global_success = 0;
    MPI_Allreduce(&success, &global_success, 1, MPI_INT, MPI_MIN, MPI_COMM_WORLD);

    MPI_Finalize();

    return global_success ? EXIT_SUCCESS : EXIT_FAILURE;
}
