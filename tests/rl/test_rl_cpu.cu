#include "../common.cuh"
#include "../../src/rl/rl_cpu.cuh"

void test_rl_cpu_compression_implementation_plan_example(void)
{
    uint8_t data[] = {5, 5, 8, 8, 8, 7, 7, 7, 7, 3, 4, 4, 4};
    size_t dataSize = 13;
    uint8_t expectedCounts[] = {2, 3, 4, 1, 3};
    uint8_t expectedValues[] = {5, 8, 7, 3, 4};
    size_t expectedCount = 5;

    auto compressedData = RunLength::cpuCompress(data, dataSize);
    TEST_CHECK_(compressedData.count == expectedCount, "%zu is equal to %zu", compressedData.count, expectedCount);
    TEST_ARRAYS_EQUAL(expectedCounts, compressedData.outputCounts, expectedCount, "%hhu");
    TEST_ARRAYS_EQUAL(expectedValues, compressedData.outputValues, expectedCount, "%hhu");
}

void test_rl_cpu_compression_empty(void)
{
    uint8_t data[] = {};
    size_t dataSize = 0;
    uint8_t expectedCounts[] = {};
    uint8_t expectedValues[] = {};
    size_t expectedCount = 0;

    auto compressedData = RunLength::cpuCompress(data, dataSize);
    TEST_CHECK_(compressedData.count == expectedCount, "%zu is equal to %zu", compressedData.count, expectedCount);
    TEST_ARRAYS_EQUAL(expectedCounts, compressedData.outputCounts, expectedCount, "%hhu");
    TEST_ARRAYS_EQUAL(expectedValues, compressedData.outputValues, expectedCount, "%hhu");
}

void test_rl_cpu_compression_single_value(void)
{
    uint8_t data[] = {9};
    size_t dataSize = 1;
    uint8_t expectedCounts[] = {1};
    uint8_t expectedValues[] = {9};
    size_t expectedCount = 1;

    auto compressedData = RunLength::cpuCompress(data, dataSize);
    TEST_CHECK_(compressedData.count == expectedCount, "%zu is equal to %zu", compressedData.count, expectedCount);
    TEST_ARRAYS_EQUAL(expectedCounts, compressedData.outputCounts, expectedCount, "%hhu");
    TEST_ARRAYS_EQUAL(expectedValues, compressedData.outputValues, expectedCount, "%hhu");
}

void test_rl_cpu_compression_unique_elements(void)
{
    uint8_t data[] = {1, 2, 3, 4, 5};
    size_t dataSize = 5;
    uint8_t expectedCounts[] = {1, 1, 1, 1, 1};
    uint8_t expectedValues[] = {1, 2, 3, 4, 5};
    size_t expectedCount = 5;

    auto compressedData = RunLength::cpuCompress(data, dataSize);
    TEST_CHECK_(compressedData.count == expectedCount, "%zu is equal to %zu", compressedData.count, expectedCount);
    TEST_ARRAYS_EQUAL(expectedCounts, compressedData.outputCounts, expectedCount, "%hhu");
    TEST_ARRAYS_EQUAL(expectedValues, compressedData.outputValues, expectedCount, "%hhu");
}

void test_rl_cpu_compression_multiple_sequences(void)
{
    uint8_t data[] = {5, 5, 8, 8, 8, 7, 7, 7, 7, 3, 4, 4, 4};
    size_t dataSize = 13;
    uint8_t expectedCounts[] = {2, 3, 4, 1, 3};
    uint8_t expectedValues[] = {5, 8, 7, 3, 4};
    size_t expectedCount = 5;

    auto compressedData = RunLength::cpuCompress(data, dataSize);
    TEST_CHECK_(compressedData.count == expectedCount, "%zu is equal to %zu", compressedData.count, expectedCount);
    TEST_ARRAYS_EQUAL(expectedCounts, compressedData.outputCounts, expectedCount, "%hhu");
    TEST_ARRAYS_EQUAL(expectedValues, compressedData.outputValues, expectedCount, "%hhu");
}

void test_rl_cpu_compression_large_sequence(void)
{
    uint8_t data[256];
    size_t dataSize = 256;

    for (size_t i = 0; i < dataSize; ++i)
    {
        data[i] = 100;
    }

    uint8_t expectedCounts[] = {255, 1};
    uint8_t expectedValues[] = {100, 100};
    size_t expectedCount = 2;

    auto compressedData = RunLength::cpuCompress(data, dataSize);
    TEST_CHECK_(compressedData.count == expectedCount, "%zu is equal to %zu", compressedData.count, expectedCount);
    TEST_ARRAYS_EQUAL(expectedCounts, compressedData.outputCounts, expectedCount, "%hhu");
    TEST_ARRAYS_EQUAL(expectedValues, compressedData.outputValues, expectedCount, "%hhu");
}

void test_rl_cpu_compression_alternating(void)
{
    uint8_t data[] = {1, 2, 1, 2, 1, 2, 1, 2};
    size_t dataSize = 8;
    uint8_t expectedCounts[] = {1, 1, 1, 1, 1, 1, 1, 1};
    uint8_t expectedValues[] = {1, 2, 1, 2, 1, 2, 1, 2};
    size_t expectedCount = 8;

    auto compressedData = RunLength::cpuCompress(data, dataSize);
    TEST_CHECK_(compressedData.count == expectedCount, "%zu is equal to %zu", compressedData.count, expectedCount);
    TEST_ARRAYS_EQUAL(expectedCounts, compressedData.outputCounts, expectedCount, "%hhu");
    TEST_ARRAYS_EQUAL(expectedValues, compressedData.outputValues, expectedCount, "%hhu");
}

TEST_LIST = {
    {"test_rl_cpu_compression_implementation_plan_example", test_rl_cpu_compression_implementation_plan_example},
    {"test_rl_cpu_compression_empty", test_rl_cpu_compression_empty},
    {"test_rl_cpu_compression_single_value", test_rl_cpu_compression_single_value},
    {"test_rl_cpu_compression_unique_elements", test_rl_cpu_compression_unique_elements},
    {"test_rl_cpu_compression_multiple_sequences", test_rl_cpu_compression_multiple_sequences},
    {"test_rl_cpu_compression_large_sequence", test_rl_cpu_compression_large_sequence},
    {"test_rl_cpu_compression_alternating", test_rl_cpu_compression_alternating},
    {nullptr, nullptr}};