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

    /* Warm up before all timed kernels. */
#ifdef _OPENMP
#pragma omp parallel for
#endif
    for (int j=0; j<STREAM_ARRAY_SIZE; j += STRIDE)
        c[j] = a[j];
#ifdef _OPENMP
#pragma omp parallel for
#endif
    for (int j=0; j<STREAM_ARRAY_SIZE; j += STRIDE)
        b[j] = scalar*c[j];
#ifdef _OPENMP
#pragma omp parallel for
#endif
    for (int j=0; j<STREAM_ARRAY_SIZE; j += STRIDE)
        c[j] = a[j]+b[j];
#ifdef _OPENMP
#pragma omp parallel for
#endif
    for (int j=0; j<STREAM_ARRAY_SIZE; j += STRIDE)
        a[j] = b[j]+scalar*c[j];

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
