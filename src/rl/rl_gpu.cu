#include <thrust/execution_policy.h>
#include <thrust/functional.h>
#include <thrust/scan.h>
#include <stdexcept>

#include "rl_gpu.cuh"
#include "../utils.cuh"
#include "../timers/cpu_timer.cuh"
#include "../timers/gpu_timer.cuh"

namespace RunLength
{
    // Main functions

    RLCompressed gpuCompress(uint8_t *data, size_t size)
    {
        if (size == 0)
        {
            return RLCompressed();
        }

        std::exception error;
        bool isError = false;

        Timers::CpuTimer cpuTimer;
        Timers::GpuTimer gpuTimer;

        uint32_t outputSize = 0;

        // CPU arrays
        uint8_t *outputValues = nullptr;
        uint8_t *outputCounts = nullptr;

        // GPU arrays
        uint8_t *d_data = nullptr;
        uint32_t *d_startMask = nullptr;
        uint32_t *d_scannedStartMask = nullptr;
        uint32_t *d_startIndices = nullptr;
        uint32_t *d_startIndicesLength = nullptr;
        uint8_t *d_outputValues = nullptr;
        uint8_t *d_outputCounts = nullptr;
        uint32_t *d_recalculateSequence = nullptr;
        uint32_t *d_shouldRecalculate = nullptr;

        try
        {
            gpuTimer.start();

            // Copy input data to GPU
            CHECK_CUDA(cudaMalloc(&d_data, sizeof(uint8_t) * size));
            CHECK_CUDA(cudaMemcpy(d_data, data, sizeof(uint8_t) * size, cudaMemcpyHostToDevice));

            gpuTimer.end();
            gpuTimer.printResult("Copy input data to GPU");

            gpuTimer.start();

            // Prepare GPU arrays
            CHECK_CUDA(cudaMalloc(&d_startMask, sizeof(uint32_t) * size));
            CHECK_CUDA(cudaMemset(d_startMask, 0, sizeof(uint32_t) * size));
            CHECK_CUDA(cudaMalloc(&d_scannedStartMask, sizeof(uint32_t) * size));
            CHECK_CUDA(cudaMalloc(&d_startIndices, sizeof(uint32_t) * size));
            CHECK_CUDA(cudaMalloc(&d_startIndicesLength, sizeof(uint32_t)));
            // We could do it only after we know how much exactly we need, but it doesn't really matter
            // as we will copy back exact amount back to cpu anyway.
            // This way error handling is easier as all allocations are done at the beggining of the function.
            CHECK_CUDA(cudaMalloc(&d_outputValues, sizeof(uint8_t) * size));
            CHECK_CUDA(cudaMalloc(&d_outputCounts, sizeof(uint8_t) * size));
            // Same here, we could wait and allocate it later with exact size, but this way it's easier
            // to handle errors.
            CHECK_CUDA(cudaMalloc(&d_recalculateSequence, sizeof(uint32_t) * size));
            CHECK_CUDA(cudaMalloc(&d_shouldRecalculate, sizeof(uint32_t)));
            CHECK_CUDA(cudaMemset(d_shouldRecalculate, 0, sizeof(uint32_t)));

            gpuTimer.end();
            gpuTimer.printResult("Allocate arrays on GPU");

            gpuTimer.start();

            // Calculate start mask
            const uint32_t calculateStartMaskThreadsCount = 1024;
            const uint32_t calculateStartMaskBlocksCount = ceil(size * 1.0 / calculateStartMaskThreadsCount);
            compressCalculateStartMask<<<calculateStartMaskBlocksCount, calculateStartMaskThreadsCount>>>(d_data, size, d_startMask);
            CHECK_CUDA(cudaDeviceSynchronize());
            CHECK_CUDA(cudaGetLastError());

            // Calculate scanned start mask
            compressCalculateScannedStartMask(d_startMask, d_scannedStartMask, size);

            // Calculate start indicies
            const uint32_t calculateStartIndiciesThreadsCount = 1024;
            const uint32_t calculateStartIndiciesBlocksCount = ceil(size * 1.0 / calculateStartIndiciesThreadsCount);
            compressCalculateStartIndicies<<<calculateStartIndiciesBlocksCount, calculateStartIndiciesThreadsCount>>>(d_scannedStartMask, size, d_startIndices, d_startIndicesLength);
            CHECK_CUDA(cudaDeviceSynchronize());
            CHECK_CUDA(cudaGetLastError());

            // First copy to CPU size of final output to know how much bytes to copy (and allocate)
            // and to know how big kernel should be

            CHECK_CUDA(cudaMemcpy(&outputSize, d_startIndicesLength, sizeof(uint32_t), cudaMemcpyDeviceToHost));

            // Check if we need to recalculate some sequence due to size > 255
            const uint32_t checkForMoreSequencesThreadsCount = 1024;
            const uint32_t checkForMoreSequencesBlocksCount = ceil(outputSize * 1.0 / checkForMoreSequencesThreadsCount);
            compressCheckForMoreSequences<<<checkForMoreSequencesBlocksCount, checkForMoreSequencesThreadsCount>>>(d_startIndices, d_startIndicesLength, size, d_recalculateSequence, d_shouldRecalculate);
            CHECK_CUDA(cudaDeviceSynchronize());
            CHECK_CUDA(cudaGetLastError());

            // Copy to cpu boolean value to check if need to recalculate some sequences
            uint32_t shouldRecalculate = 0;
            CHECK_CUDA(cudaMemcpy(&shouldRecalculate, d_shouldRecalculate, sizeof(uint32_t), cudaMemcpyDeviceToHost));

            if (shouldRecalculate != 0)
            {
                // Copy data to CPU needed for threads counts of next kernel
                uint32_t lastRecalculateSequence;
                CHECK_CUDA(cudaMemcpy(&lastRecalculateSequence, &d_recalculateSequence[outputSize - 1], sizeof(uint32_t), cudaMemcpyDeviceToHost));

                // Prescan on `recalculateSequence`
                compressRecalculateSequencePrescan(d_recalculateSequence, outputSize);

                // Copy data to CPU needed for threads counts of next kernel
                uint32_t lastRecalculateSequencePrescan;
                CHECK_CUDA(cudaMemcpy(&lastRecalculateSequencePrescan, &d_recalculateSequence[outputSize - 1], sizeof(uint32_t), cudaMemcpyDeviceToHost));

                // Recalculate start mask
                const uint32_t recalculateStartMaskAllThreads = lastRecalculateSequence + lastRecalculateSequencePrescan;
                const uint32_t recalculateStartMaskThreadsCount = 1024;
                const uint32_t recalculateStartMaskBlocksCount = ceil(recalculateStartMaskAllThreads * 1.0 / recalculateStartMaskThreadsCount);
                compressRecalculateStartMask<<<recalculateStartMaskBlocksCount, recalculateStartMaskThreadsCount>>>(d_startMask, recalculateStartMaskAllThreads, d_recalculateSequence, outputSize, d_startIndices);
                CHECK_CUDA(cudaDeviceSynchronize());
                CHECK_CUDA(cudaGetLastError());

                // Do points 2. and 3. again
                // Calculate scanned start mask
                compressCalculateScannedStartMask(d_startMask, d_scannedStartMask, size);

                // Calculate start indicies
                compressCalculateStartIndicies<<<calculateStartIndiciesBlocksCount, calculateStartIndiciesThreadsCount>>>(d_scannedStartMask, size, d_startIndices, d_startIndicesLength);
                CHECK_CUDA(cudaDeviceSynchronize());
                CHECK_CUDA(cudaGetLastError());

                // Copy to CPU final outputSize
                outputSize = 0;
                CHECK_CUDA(cudaMemcpy(&outputSize, d_startIndicesLength, sizeof(uint32_t), cudaMemcpyDeviceToHost));
            }

            // Calculate final output
            const uint32_t calculateOutputThreadsCount = 1024;
            const uint32_t calculateOutputBlocksCount = ceil(outputSize * 1.0 / calculateOutputThreadsCount);
            compressCalculateOutput<<<calculateOutputBlocksCount, calculateOutputThreadsCount>>>(d_data, size, d_startIndices, d_startIndicesLength, d_outputValues, d_outputCounts);
            CHECK_CUDA(cudaDeviceSynchronize());
            CHECK_CUDA(cudaGetLastError());

            gpuTimer.end();
            gpuTimer.printResult("Compress data");

            cpuTimer.start();

            // Allocate needed cpu arrays
            outputValues = reinterpret_cast<uint8_t *>(malloc(sizeof(uint8_t) * outputSize));
            if (outputValues == nullptr)
            {
                throw std::runtime_error("Cannot allocate memory");
            }
            outputCounts = reinterpret_cast<uint8_t *>(malloc(sizeof(uint8_t) * outputSize));
            if (outputCounts == nullptr)
            {
                throw std::runtime_error("Cannot allocate memory");
            }

            cpuTimer.end();
            cpuTimer.printResult("Allocate arrays on CPU");

            gpuTimer.start();

            // Copy results to CPU
            CHECK_CUDA(cudaMemcpy(outputValues, d_outputValues, sizeof(uint8_t) * outputSize, cudaMemcpyDeviceToHost));
            CHECK_CUDA(cudaMemcpy(outputCounts, d_outputCounts, sizeof(uint8_t) * outputSize, cudaMemcpyDeviceToHost));

            gpuTimer.end();
            gpuTimer.printResult("Copy results to CPU");
        }
        catch (const std::exception &e)
        {
            isError = true;
            error = e;
        }

        gpuTimer.start();

        // Deallocate GPU arrays
        cudaFree(d_data);
        cudaFree(d_startMask);
        cudaFree(d_scannedStartMask);
        cudaFree(d_startIndices);
        cudaFree(d_startIndicesLength);
        cudaFree(d_outputValues);
        cudaFree(d_outputCounts);

        gpuTimer.end();
        gpuTimer.printResult("Deallocate GPU array");

        if (isError)
        {
            throw error;
        }

        return RLCompressed(outputValues, outputCounts, outputSize);
    }

    RLDecompressed gpuDecompress(uint8_t *values, uint8_t *counts, size_t size)
    {
        if (size == 0)
        {
            return RLDecompressed();
        }

        Timers::CpuTimer cpuTimer;
        Timers::GpuTimer gpuTimer;

        std::exception error;
        bool isError = false;

        size_t outputSize = 0;

        // CPU arrays
        uint8_t *data;

        // GPU arrays
        uint8_t *d_values;
        uint8_t *d_counts;
        uint8_t *d_data;
        uint32_t *d_startIndicies;

        try
        {
            gpuTimer.start();

            // Copy input data to GPU
            CHECK_CUDA(cudaMalloc(&d_values, sizeof(uint8_t) * size));
            CHECK_CUDA(cudaMemcpy(d_values, values, sizeof(uint8_t) * size, cudaMemcpyHostToDevice));

            CHECK_CUDA(cudaMalloc(&d_counts, sizeof(uint8_t) * size));
            CHECK_CUDA(cudaMemcpy(d_counts, counts, sizeof(uint8_t) * size, cudaMemcpyHostToDevice));

            gpuTimer.end();
            gpuTimer.printResult("Copy input data to GPU");

            gpuTimer.start();

            // Prepare GPU arrays
            CHECK_CUDA(cudaMalloc(&d_startIndicies, sizeof(uint32_t) * size));

            gpuTimer.end();
            gpuTimer.printResult("Allocate arrays on GPU");

            gpuTimer.start();

            // Calculate startIndicies
            decompressCalculateStartIndicies(d_counts, size, d_startIndicies);

            // Calculate final output length
            uint32_t startIndiciesLast;
            CHECK_CUDA(cudaMemcpy(&startIndiciesLast, &d_startIndicies[size - 1], sizeof(uint32_t), cudaMemcpyDeviceToHost));
            outputSize = startIndiciesLast + counts[size - 1];

            // Allocate GPU array for final output
            CHECK_CUDA(cudaMalloc(&d_data, sizeof(uint8_t) * outputSize));

            // Calculate final output
            const uint32_t calculateOutputThreadsCount = 1024;
            const uint32_t calculateOutputBlocksCount = ceil(outputSize * 1.0 / calculateOutputThreadsCount);
            decompressCalculateOutput<<<calculateOutputBlocksCount, calculateOutputThreadsCount>>>(d_values, size, d_startIndicies, outputSize, d_data);
            CHECK_CUDA(cudaDeviceSynchronize());
            CHECK_CUDA(cudaGetLastError());

            gpuTimer.end();
            gpuTimer.printResult("Decompress data");

            cpuTimer.start();

            // Allocate CPU array
            data = reinterpret_cast<uint8_t *>(malloc(sizeof(uint8_t) * outputSize));
            if (data == nullptr)
            {
                throw std::runtime_error("Cannot allocate memory");
            }

            cpuTimer.end();
            cpuTimer.printResult("Allocate arrays on CPU");

            gpuTimer.start();

            // Copy result to CPU
            CHECK_CUDA(cudaMemcpy(data, d_data, sizeof(uint8_t) * outputSize, cudaMemcpyDeviceToHost));

            gpuTimer.end();
            gpuTimer.printResult("Copy result to CPU");
        }
        catch (const std::exception &e)
        {
            isError = true;
            error = e;
        }

        gpuTimer.start();

        // Deallocate GPU arrays
        cudaFree(d_values);
        cudaFree(d_counts);
        cudaFree(d_data);
        cudaFree(d_startIndicies);

        gpuTimer.end();
        gpuTimer.printResult("Deallocate GPU arrays");

        if (isError)
        {
            throw error;
        }

        return RLDecompressed(data, outputSize);
    }

    // Kernels

    __global__ void compressCalculateStartMask(uint8_t *d_data, size_t size, uint32_t *d_startMask)
    {
        auto threadId = blockDim.x * blockIdx.x + threadIdx.x;
        if (threadId == 0 || (threadId > 0 && threadId < size && d_data[threadId] != d_data[threadId - 1]))
        {
            d_startMask[threadId] = 1;
        }
    }

    __global__ void compressCalculateStartIndicies(uint32_t *d_scannedStartMask, size_t size, uint32_t *d_startIndicies, uint32_t *d_startIndiciesLength)
    {
        __shared__ uint32_t s_maxLength[1];
        auto threadId = blockDim.x * blockIdx.x + threadIdx.x;
        auto localThreadId = threadIdx.x;

        // Initialize shared memory
        if (localThreadId == 0)
        {
            // It will always be at least 1, in case of length 0 we early return from main compress function
            s_maxLength[0] = 1;
        }
        __syncthreads();

        if (threadId == 0)
        {
            d_startIndicies[0] = 0;
        }
        else if (threadId < size && d_scannedStartMask[threadId] != d_scannedStartMask[threadId - 1])
        {
            auto id = d_scannedStartMask[threadId] - 1;
            d_startIndicies[id] = threadId;
            // + 1 because we want the length, not the index
            atomicMax(&s_maxLength[0], id + 1);
        }
        __syncthreads();

        // Save currently biggest changed index in global variable
        if (localThreadId == 0)
        {
            atomicMax(d_startIndiciesLength, s_maxLength[0]);
        }
    }

    __global__ void compressCheckForMoreSequences(uint32_t *d_startIndicies, uint32_t *d_startIndiciesLength, size_t size, uint32_t *d_recalculateSequence, uint32_t *d_shouldRecalculate)
    {
        __shared__ uint32_t s_shouldRecalculate[1];
        __shared__ uint32_t s_startIndiciesLength[1];
        auto threadId = blockDim.x * blockIdx.x + threadIdx.x;
        auto localThreadId = threadIdx.x;

        // Initialize shared memory
        if (localThreadId == 0)
        {
            s_shouldRecalculate[0] = false;
            s_startIndiciesLength[0] = d_startIndiciesLength[0];
        }
        __syncthreads();

        // Case when there is only one sequence
        if (s_startIndiciesLength[0] == 1)
        {
            if (threadId == 0)
            {
                uint32_t diff = size;
                if (diff > 255)
                {
                    d_recalculateSequence[0] = ((diff - 1) / 255) + 1;
                    atomicOr(s_shouldRecalculate, 1);
                }
            }
        }
        else if (threadId <= s_startIndiciesLength[0] - 1)
        {
            uint32_t diff = 0;
            if (threadId < s_startIndiciesLength[0] - 1)
            {
                diff = d_startIndicies[threadId + 1] - d_startIndicies[threadId];
            }
            else
            {
                diff = size - d_startIndicies[threadId];
            }
            if (diff > 255)
            {
                d_recalculateSequence[threadId] = ((diff - 1) / 255) + 1;
                atomicOr(s_shouldRecalculate, 1);
            }
        }
        __syncthreads();

        // Save result from shared to global memory
        if (localThreadId == 0)
        {
            atomicOr(d_shouldRecalculate, s_shouldRecalculate[0]);
        }
    }

    __global__ void compressCalculateOutput(uint8_t *d_data, size_t size, uint32_t *d_startIndicies, uint32_t *d_startIndiciesLength, uint8_t *d_outputValues, uint8_t *d_outputCounts)
    {
        __shared__ uint32_t s_length[1];
        auto threadId = blockDim.x * blockIdx.x + threadIdx.x;
        auto localThreadId = threadIdx.x;

        // Initialize shared memory
        if (localThreadId == 0)
        {
            s_length[0] = d_startIndiciesLength[0];
        }
        __syncthreads();

        if (threadId < s_length[0])
        {
            d_outputValues[threadId] = d_data[d_startIndicies[threadId]];
        }

        if (threadId == s_length[0] - 1)
        {
            d_outputCounts[threadId] = (uint8_t)((uint32_t)size - d_startIndicies[threadId]);
        }
        else if (threadId < s_length[0] - 1)
        {
            d_outputCounts[threadId] = d_startIndicies[threadId + 1] - d_startIndicies[threadId];
        }
    }

    __global__ void compressRecalculateStartMask(uint32_t *d_startMask, uint32_t allThreads, uint32_t *d_recalculateSequence, size_t recalculateSequenceLength, uint32_t *d_startIndicies)
    {
        auto threadId = blockDim.x * blockIdx.x + threadIdx.x;
        if (threadId < allThreads)
        {
            auto j = binarySearchInsideRange(d_recalculateSequence, recalculateSequenceLength, threadId);
            auto k = threadId - d_recalculateSequence[j];
            d_startMask[d_startIndicies[j] + k * 255] = 1;
        }
    }

    __global__ void decompressCalculateOutput(uint8_t *d_values, size_t size, uint32_t *d_startIndicies, size_t threadsCount, uint8_t *d_data)
    {
        auto threadId = blockDim.x * blockIdx.x + threadIdx.x;
        if (threadId < threadsCount)
        {
            auto j = binarySearchInsideRange(d_startIndicies, size, threadId);
            d_data[threadId] = d_values[j];
        }
    }

    // Helpers

    void compressCalculateScannedStartMask(uint32_t *d_startMask, uint32_t *d_scannedStartMask, size_t size)
    {
        thrust::inclusive_scan(thrust::device, d_startMask, d_startMask + size, d_scannedStartMask);
    }

    void compressRecalculateSequencePrescan(uint32_t *d_recalculateSequence, uint32_t size)
    {
        thrust::exclusive_scan(thrust::device, d_recalculateSequence, d_recalculateSequence + size, d_recalculateSequence);
    }

    void decompressCalculateStartIndicies(uint8_t *d_counts, size_t size, uint32_t *d_startIndicies)
    {
        thrust::exclusive_scan(thrust::device, d_counts, d_counts + size, d_startIndicies, 0, thrust::plus<uint32_t>());
    }

    __device__ size_t binarySearchInsideRange(uint32_t *d_arr, size_t size, uint32_t value)
    {
        size_t left = 0;
        size_t right = size - 1;

        while (left <= right)
        {
            size_t m = (left + right) / 2;

            if (d_arr[m] <= value)
            {
                if (m == size - 1 || d_arr[m + 1] > value)
                {
                    return m;
                }
                else
                {
                    left = m + 1;
                }
            }
            else
            {
                right = m - 1;
            }
        }

        return size;
    }

} // RunLength