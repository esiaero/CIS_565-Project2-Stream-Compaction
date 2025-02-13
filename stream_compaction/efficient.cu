#include <cuda.h>
#include <cuda_runtime.h>
#include "common.h"
#include "efficient.h"
#include <device_launch_parameters.h>

namespace StreamCompaction {
    namespace Efficient {
        using StreamCompaction::Common::PerformanceTimer;
        PerformanceTimer& timer()
        {
            static PerformanceTimer timer;
            return timer;
        }
        
        constexpr unsigned blockSize = 128;

        __global__ void kernUpsweep(int d, int n, int* data) {
            unsigned index = (blockIdx.x * blockDim.x) + threadIdx.x;
            unsigned rightPOT = 1 << (d + 1);
            index *= rightPOT; // "by 2^(d+1)"
            unsigned rightIdx = index + rightPOT - 1;
            if (rightIdx > n) { return; } //  not necessary since n is always POT?
            data[rightIdx] += data[index + (1 << d) - 1];
        }

        __global__ void kernDownsweep(int d, int n, int* data) {
            unsigned index = (blockIdx.x * blockDim.x) + threadIdx.x;
            unsigned rightPOT = 1 << (d + 1);
            index *= rightPOT;
            unsigned leftIdx = index + (1 << d) - 1;
            unsigned rightIdx = index + rightPOT - 1;
            if (rightIdx > n) { return; }

            int tmp = data[leftIdx];
            data[leftIdx] = data[rightIdx];
            data[rightIdx] += tmp;
        }

        /**
         * Performs prefix-sum (aka scan) on idata, storing the result into odata.
         */
        void scan(int n, int *odata, const int *idata) {
            int smallestPOTGreater = 1 << ilog2ceil(n); // smallest POT larger than n
            int* dev_data;
            cudaMalloc((void**)&dev_data, smallestPOTGreater * sizeof(int));
            cudaMemcpy(dev_data, idata, n * sizeof(int), cudaMemcpyHostToDevice);
            cudaMemset(dev_data + n, 0, (smallestPOTGreater - n) * sizeof(int)); // necessary? 

            int neededThreads = smallestPOTGreater;
            dim3 fullBlocksPerGrid;

            timer().startGpuTimer();
            for (int d = 0; d < ilog2ceil(smallestPOTGreater); ++d, neededThreads /= 2) {
                fullBlocksPerGrid = (neededThreads + blockSize - 1) / blockSize;
                kernUpsweep<<<fullBlocksPerGrid, blockSize>>>(d, n, dev_data);
                cudaDeviceSynchronize();
            }
            cudaMemset(&dev_data[smallestPOTGreater - 1], 0, sizeof(int));
            for (int d = ilog2ceil(smallestPOTGreater) - 1; d >= 0; --d, neededThreads *= 2) {
                fullBlocksPerGrid = (neededThreads + blockSize - 1) / blockSize;
                kernDownsweep<<<fullBlocksPerGrid, blockSize>>>(d, smallestPOTGreater, dev_data);
                cudaDeviceSynchronize();
            }
            timer().endGpuTimer();

            cudaMemcpy(odata, dev_data, n * sizeof(int), cudaMemcpyDeviceToHost);
            cudaFree(dev_data);
        }

        /**
         * Performs stream compaction on idata, storing the result into odata.
         * All zeroes are discarded.
         *
         * @param n      The number of elements in idata.
         * @param odata  The array into which to store elements.
         * @param idata  The array of elements to compact.
         * @returns      The number of elements remaining after compaction.
         */
        int compact(int n, int *odata, const int *idata) {
            int smallestPOTGreater = 1 << ilog2ceil(n); // smallest POT larger than n
            int* dev_idata;
            int* dev_odata;
            int* bool_data;
            int* indices_data;

            cudaMalloc((void**)&dev_idata, smallestPOTGreater * sizeof(int));
            cudaMalloc((void**)&dev_odata, smallestPOTGreater * sizeof(int));
            cudaMalloc((void**)&bool_data, smallestPOTGreater * sizeof(int));
            cudaMalloc((void**)&indices_data, smallestPOTGreater * sizeof(int));
            cudaMemcpy(dev_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);
            dim3 fullBlocksPerGrid((smallestPOTGreater + blockSize - 1) / blockSize);

            timer().startGpuTimer();
            Common::kernMapToBoolean<<<fullBlocksPerGrid, blockSize>>>(smallestPOTGreater, bool_data, dev_idata);
            cudaDeviceSynchronize();

            // -----PREFIX SUM CODE FROM SCAN-----
            cudaMemcpy(indices_data, bool_data, smallestPOTGreater * sizeof(int), cudaMemcpyDeviceToDevice);
            cudaMemset(indices_data + n, 0, (smallestPOTGreater - n) * sizeof(int)); // necessary? 
            int neededThreads = smallestPOTGreater;
            for (int d = 0; d < ilog2ceil(smallestPOTGreater); ++d, neededThreads /= 2) {
                fullBlocksPerGrid = (neededThreads + blockSize - 1) / blockSize;
                kernUpsweep<<<fullBlocksPerGrid, blockSize>>>(d, n, indices_data);
                cudaDeviceSynchronize();
            }

            cudaMemset(&indices_data[smallestPOTGreater - 1], 0, sizeof(int));

            for (int d = ilog2ceil(smallestPOTGreater) - 1; d >= 0; --d, neededThreads *= 2) {
                fullBlocksPerGrid = (neededThreads + blockSize - 1) / blockSize;
                kernDownsweep<<<fullBlocksPerGrid, blockSize>>>(d, smallestPOTGreater, indices_data);
                cudaDeviceSynchronize();
            }
            // -----END PREFIX SUM CODE FROM SCAN------
            fullBlocksPerGrid = (smallestPOTGreater + blockSize - 1) / blockSize;
            Common::kernScatter<<<fullBlocksPerGrid, blockSize>>>(smallestPOTGreater, dev_odata, dev_idata, bool_data, indices_data);
            timer().endGpuTimer();

            cudaMemcpy(odata, dev_odata, n * sizeof(int), cudaMemcpyDeviceToHost);
            int size;
            cudaMemcpy(&size, &indices_data[smallestPOTGreater - 1], sizeof(int), cudaMemcpyDeviceToHost); // cpy last elem of indcies_value 
            
            cudaFree(bool_data);
            cudaFree(indices_data);
            cudaFree(dev_idata);
            cudaFree(dev_odata);
            return size;
        }
    }
}
