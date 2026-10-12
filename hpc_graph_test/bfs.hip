/**
 * GPU Breadth-First Search (BFS) using HIP + MPI
 *
 * Level-synchronous BFS on a CSR graph with multi-node parallelism:
 *   - Each MPI rank owns a contiguous block of vertices
 *   - Each rank performs local frontier expansion on its GPU
 *   - After each level, all ranks exchange newly-discovered frontier nodes
 *     via MPI_Allgatherv so every rank has the full frontier for the next level
 *   - Distance array is replicated on every rank (updated locally, consistent globally)
 *
 * Build:
 *   mpicxx -x hip -O3 -o bfs bfs.hip
 *
 * Run:
 *   mpirun -np <N> ./bfs [num_vertices] [avg_degree] [source]
 */

#include <hip/hip_runtime.h>
#include <mpi.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <queue>
#include <random>
#include <string>
#include <vector>

#define HIP_CHECK(call)                                                        \
    do {                                                                       \
        hipError_t err__ = (call);                                             \
        if (err__ != hipSuccess) {                                             \
            std::cerr << "HIP error at " << __FILE__ << ":" << __LINE__        \
                      << " — " << hipGetErrorString(err__) << std::endl;       \
            std::exit(EXIT_FAILURE);                                           \
        }                                                                      \
    } while (0)

// ---------------------------------------------------------------------------
// CSR graph (host)
// ---------------------------------------------------------------------------

struct Graph {
    int n = 0;                       // number of vertices
    std::vector<int> row_ptr;        // size n+1
    std::vector<int> col_idx;        // size = number of edges (undirected: 2*m)
};

/// Build an undirected random graph with approximately avg_degree neighbors
/// per vertex. Self-loops and duplicate edges are avoided.
Graph generate_random_graph(int n, int avg_degree, unsigned seed = 42) {
    Graph g;
    g.n = n;
    g.row_ptr.assign(n + 1, 0);

    std::mt19937 rng(seed);
    std::uniform_int_distribution<int> dist(0, n - 1);

    // Adjacency lists (dedup with sort+unique later)
    std::vector<std::vector<int>> adj(n);
    const int target_edges = (n * avg_degree) / 2; // undirected edge count

    for (int e = 0; e < target_edges; ++e) {
        int u = dist(rng);
        int v = dist(rng);
        if (u == v)
            continue;
        adj[u].push_back(v);
        adj[v].push_back(u);
    }

    for (int u = 0; u < n; ++u) {
        auto& nbrs = adj[u];
        std::sort(nbrs.begin(), nbrs.end());
        nbrs.erase(std::unique(nbrs.begin(), nbrs.end()), nbrs.end());
        g.row_ptr[u + 1] = g.row_ptr[u] + static_cast<int>(nbrs.size());
    }

    g.col_idx.resize(g.row_ptr[n]);
    for (int u = 0; u < n; ++u) {
        std::copy(adj[u].begin(), adj[u].end(),
                  g.col_idx.begin() + g.row_ptr[u]);
    }
    return g;
}

// ---------------------------------------------------------------------------
// CPU reference BFS
// ---------------------------------------------------------------------------

std::vector<int> bfs_cpu(const Graph& g, int source) {
    std::vector<int> dist(g.n, -1);
    if (source < 0 || source >= g.n)
        return dist;

    std::queue<int> q;
    dist[source] = 0;
    q.push(source);

    while (!q.empty()) {
        int u = q.front();
        q.pop();
        for (int e = g.row_ptr[u]; e < g.row_ptr[u + 1]; ++e) {
            int v = g.col_idx[e];
            if (dist[v] < 0) {
                dist[v] = dist[u] + 1;
                q.push(v);
            }
        }
    }
    return dist;
}

// ---------------------------------------------------------------------------
// GPU kernels
// ---------------------------------------------------------------------------

/// Expand one BFS level: for each node in the current frontier, visit its
/// neighbors. Newly discovered nodes are written into next_frontier.
__global__ void bfs_expand_kernel(const int* __restrict__ row_ptr,
                                  const int* __restrict__ col_idx,
                                  const int* __restrict__ frontier,
                                  int frontier_size,
                                  int* __restrict__ next_frontier,
                                  int* __restrict__ next_frontier_size,
                                  int* __restrict__ dist,
                                  int level,
                                  int owner_start,
                                  int owner_end) {
    const int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= frontier_size)
        return;

    const int u = frontier[tid];
    const int start = row_ptr[u];
    const int end = row_ptr[u + 1];

    for (int e = start; e < end; ++e) {
        const int v = col_idx[e];
        if (v < owner_start || v >= owner_end)
            continue;

        // Claim unvisited node: dist[v] is -1 initially
        if (atomicCAS(&dist[v], -1, level + 1) == -1) {
            const int slot = atomicAdd(next_frontier_size, 1);
            next_frontier[slot] = v;
        }
    }
}

__global__ void mark_frontier_kernel(const int* __restrict__ frontier,
                                     int frontier_size,
                                     int* __restrict__ dist,
                                     int level) {
    const int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < frontier_size)
        dist[frontier[tid]] = level;
}

// ---------------------------------------------------------------------------
// MPI-aware GPU BFS driver
// ---------------------------------------------------------------------------

/// Each rank holds a full copy of the graph and the distance array.
/// Frontier expansion happens on the local GPU; after each level we
/// all-gather the newly-discovered frontier so every rank sees the same
/// frontier for the next level.
std::vector<int> bfs_gpu_mpi(const Graph& g, int source,
                             int rank, int num_ranks,
                             double* out_time_ms) {
    std::vector<int> h_dist(g.n, -1);
    if (source < 0 || source >= g.n)
        return h_dist;

    const size_t n_bytes = static_cast<size_t>(g.n) * sizeof(int);
    const size_t e_bytes = g.col_idx.size() * sizeof(int);

    int *d_row_ptr = nullptr, *d_col_idx = nullptr;
    int *d_frontier = nullptr, *d_next_frontier = nullptr;
    int *d_dist = nullptr, *d_next_size = nullptr;

    HIP_CHECK(hipMalloc(&d_row_ptr, (g.n + 1) * sizeof(int)));
    HIP_CHECK(hipMalloc(&d_col_idx, e_bytes));
    HIP_CHECK(hipMalloc(&d_frontier, n_bytes));
    HIP_CHECK(hipMalloc(&d_next_frontier, n_bytes));
    HIP_CHECK(hipMalloc(&d_dist, n_bytes));
    HIP_CHECK(hipMalloc(&d_next_size, sizeof(int)));

    HIP_CHECK(hipMemcpy(d_row_ptr, g.row_ptr.data(),
                        (g.n + 1) * sizeof(int), hipMemcpyHostToDevice));
    HIP_CHECK(hipMemcpy(d_col_idx, g.col_idx.data(), e_bytes,
                        hipMemcpyHostToDevice));
    HIP_CHECK(hipMemset(d_dist, 0xFF, n_bytes)); // fill with -1

    // Seed source
    int zero = 0;
    HIP_CHECK(hipMemcpy(d_dist + source, &zero, sizeof(int),
                        hipMemcpyHostToDevice));
    HIP_CHECK(hipMemcpy(d_frontier, &source, sizeof(int),
                        hipMemcpyHostToDevice));

    int frontier_size = 1;
    int level = 0;
    constexpr int threads = 256;

    const int vertices_per_rank = g.n / num_ranks;
    const int extra_vertices = g.n % num_ranks;
    const int owner_start = rank * vertices_per_rank + std::min(rank, extra_vertices);
    const int owner_end = owner_start + vertices_per_rank + (rank < extra_vertices ? 1 : 0);

    // Host buffers for MPI all-gather of frontiers
    std::vector<int> h_frontier(g.n);
    std::vector<int> h_next_frontier(g.n);
    std::vector<int> all_recv_counts(num_ranks);
    std::vector<int> all_recv_displs(num_ranks);

    auto t0 = std::chrono::steady_clock::now();

    while (frontier_size > 0) {
        HIP_CHECK(hipMemset(d_next_size, 0, sizeof(int)));

        const int blocks = (frontier_size + threads - 1) / threads;
        bfs_expand_kernel<<<blocks, threads>>>(
            d_row_ptr, d_col_idx, d_frontier, frontier_size, d_next_frontier,
            d_next_size, d_dist, level, owner_start, owner_end);
        HIP_CHECK(hipGetLastError());
        HIP_CHECK(hipDeviceSynchronize());

        // Copy local next_frontier back to host
        int local_next_size = 0;
        HIP_CHECK(hipMemcpy(&local_next_size, d_next_size, sizeof(int),
                            hipMemcpyDeviceToHost));

        if (local_next_size > 0) {
            HIP_CHECK(hipMemcpy(h_next_frontier.data(), d_next_frontier,
                                static_cast<size_t>(local_next_size) * sizeof(int),
                                hipMemcpyDeviceToHost));
        }

        // All-gather sizes
        MPI_Allgather(&local_next_size, 1, MPI_INT,
                      all_recv_counts.data(), 1, MPI_INT, MPI_COMM_WORLD);

        // Build displacements
        all_recv_displs[0] = 0;
        for (int i = 1; i < num_ranks; ++i) {
            all_recv_displs[i] = all_recv_displs[i - 1] + all_recv_counts[i - 1];
        }
        int total_next_size = all_recv_displs[num_ranks - 1] + all_recv_counts[num_ranks - 1];

        if (total_next_size > g.n) {
            if (rank == 0) {
                std::cerr << "Global frontier exceeds graph size: "
                          << total_next_size << " > " << g.n << std::endl;
            }
            MPI_Abort(MPI_COMM_WORLD, EXIT_FAILURE);
        }

        // All-gather frontiers
        MPI_Allgatherv(
            (local_next_size > 0) ? h_next_frontier.data() : nullptr,
            local_next_size, MPI_INT,
            h_frontier.data(),
            all_recv_counts.data(), all_recv_displs.data(),
            MPI_INT, MPI_COMM_WORLD);

        // Push the unified frontier back to the GPU
        if (total_next_size > 0) {
            HIP_CHECK(hipMemcpy(d_frontier, h_frontier.data(),
                                static_cast<size_t>(total_next_size) * sizeof(int),
                                hipMemcpyHostToDevice));
            const int mark_blocks = (total_next_size + threads - 1) / threads;
            mark_frontier_kernel<<<mark_blocks, threads>>>(
                d_frontier, total_next_size, d_dist, level + 1);
            HIP_CHECK(hipGetLastError());
        }
        frontier_size = total_next_size;
        ++level;
    }

    auto t1 = std::chrono::steady_clock::now();
    *out_time_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    HIP_CHECK(hipMemcpy(h_dist.data(), d_dist, n_bytes, hipMemcpyDeviceToHost));

    HIP_CHECK(hipFree(d_row_ptr));
    HIP_CHECK(hipFree(d_col_idx));
    HIP_CHECK(hipFree(d_frontier));
    HIP_CHECK(hipFree(d_next_frontier));
    HIP_CHECK(hipFree(d_dist));
    HIP_CHECK(hipFree(d_next_size));

    return h_dist;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);

    int rank = 0, num_ranks = 1;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &num_ranks);

    int n = 100000;
    int avg_degree = 8;
    int source = 0;

    if (argc > 1)
        n = std::stoi(argv[1]);
    if (argc > 2)
        avg_degree = std::stoi(argv[2]);
    if (argc > 3)
        source = std::stoi(argv[3]);

    if (n <= 0 || avg_degree <= 0 || source < 0 || source >= n) {
        if (rank == 0) {
            std::cerr << "Usage: " << argv[0]
                      << " [num_vertices] [avg_degree] [source]\n";
        }
        MPI_Finalize();
        return EXIT_FAILURE;
    }

    int device_count = 0;
    hipError_t dev_err = hipGetDeviceCount(&device_count);
    if (dev_err != hipSuccess || device_count == 0) {
        if (rank == 0) {
            std::cerr << "No HIP/ROCm device available"
                      << (dev_err != hipSuccess
                              ? std::string(" (") + hipGetErrorString(dev_err) + ")"
                              : "")
                      << ".\n"
                      << "Code compiled successfully; run on a machine with an "
                         "AMD GPU and loaded amdgpu/ROCm modules.\n";
        }
        MPI_Finalize();
        return EXIT_FAILURE;
    }

    // Each rank picks a GPU (round-robin if multiple GPUs per node)
    int gpu_id = rank % device_count;
    HIP_CHECK(hipSetDevice(gpu_id));

    hipDeviceProp_t prop{};
    HIP_CHECK(hipGetDeviceProperties(&prop, gpu_id));
    if (rank == 0) {
        std::cout << "Ranks: " << num_ranks << std::endl;
        std::cout << "Device: " << prop.name << std::endl;
    }

    // ------------------------------------------------------------------
    // Build graph on every rank (same seed => identical graph)
    // ------------------------------------------------------------------
    if (rank == 0) {
        std::cout << "Generating undirected random graph: n=" << n
                  << ", avg_degree≈" << avg_degree << std::endl;
    }
    Graph g = generate_random_graph(n, avg_degree);
    if (rank == 0) {
        std::cout << "Edges (directed CSR entries): " << g.col_idx.size()
                  << std::endl;
    }

    // ------------------------------------------------------------------
    // CPU reference (rank 0 only)
    // ------------------------------------------------------------------
    std::vector<int> cpu_dist;
    double cpu_ms = 0.0;
    if (rank == 0) {
        auto t0 = std::chrono::steady_clock::now();
        cpu_dist = bfs_cpu(g, source);
        auto t1 = std::chrono::steady_clock::now();
        cpu_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    }

    // ------------------------------------------------------------------
    // GPU BFS (all ranks participate)
    // ------------------------------------------------------------------
    // Warm-up
    double warmup_ms = 0.0;
    (void)bfs_gpu_mpi(g, source, rank, num_ranks, &warmup_ms);
    HIP_CHECK(hipDeviceSynchronize());
    MPI_Barrier(MPI_COMM_WORLD);

    double gpu_ms = 0.0;
    std::vector<int> gpu_dist = bfs_gpu_mpi(g, source, rank, num_ranks, &gpu_ms);
    HIP_CHECK(hipDeviceSynchronize());
    MPI_Barrier(MPI_COMM_WORLD);

    // ------------------------------------------------------------------
    // Verification & output (rank 0 only)
    // ------------------------------------------------------------------
    if (rank == 0) {
        int mismatches = 0;
        int reachable = 0;
        int max_level = 0;
        for (int i = 0; i < n; ++i) {
            if (cpu_dist[i] != gpu_dist[i])
                ++mismatches;
            if (cpu_dist[i] >= 0) {
                ++reachable;
                max_level = std::max(max_level, cpu_dist[i]);
            }
        }

        std::cout << "Source: " << source << std::endl;
        std::cout << "Reachable vertices: " << reachable << " / " << n << std::endl;
        std::cout << "Max BFS depth: " << max_level << std::endl;
        std::cout << "CPU time: " << cpu_ms << " ms" << std::endl;
        std::cout << "GPU time: " << gpu_ms << " ms" << std::endl;

        if (mismatches == 0) {
            std::cout << "Verification: PASSED (GPU matches CPU)\n";
        } else {
            std::cout << "Verification: FAILED (" << mismatches
                      << " distance mismatches)\n";
            int shown = 0;
            for (int i = 0; i < n && shown < 8; ++i) {
                if (cpu_dist[i] != gpu_dist[i]) {
                    std::cout << "  v=" << i << " cpu=" << cpu_dist[i]
                              << " gpu=" << gpu_dist[i] << "\n";
                    ++shown;
                }
            }
        }
    }

    MPI_Finalize();

    // Only rank 0 decides success/failure
    if (rank == 0) {
        // Recompute mismatch count for return code
        int mismatches = 0;
        for (int i = 0; i < n; ++i) {
            if (cpu_dist[i] != gpu_dist[i])
                ++mismatches;
        }
        return (mismatches == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
