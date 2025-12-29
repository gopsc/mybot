#include "Dashun.h"
#include "CNNBuilder.hpp"
#include <iostream>
#include <vector>
#include <random>

// 测试函数：完整的CNN前向传播示例
void test_cnn_pipeline() {
    std::cout << "\n=== Complete CNN Pipeline Test ===" << std::endl;
    
    // 创建网络组件
    ConvLayer conv1(3, 16, 3, 1, 1);       // 输入3通道，输出16通道，3x3卷积，padding=1
    PoolingLayer pool1(2, 2, 2, 0, true);  // 2x2最大池化，步长2
    ConvLayer conv2(16, 32, 3, 1, 1);      // 输入16通道，输出32通道
    PoolingLayer pool2(2, 2, 2, 0, true);  // 2x2最大池化，步长2
    FlattenLayer flatten;                   // 展平层
    
    // 使用CNN构建器
    CNNBuilder cnn;
    
    // 定义输入尺寸
    int input_channels = 3;
    int input_height = 32;
    int input_width = 32;
    int batch_size = 4;
    
    // 构建网络
    cnn.add_conv_layer(conv1, input_channels, input_height, input_width);
    cnn.add_pool_layer(pool1, 16, input_height, input_width);  // 卷积后尺寸不变（因padding=1）
    cnn.add_conv_layer(conv2, 16, input_height/2, input_width/2);  // 池化后尺寸减半
    cnn.add_pool_layer(pool2, 32, input_height/2, input_width/2);
    cnn.add_flatten_layer(flatten, 32, input_height/4, input_width/4);
    
    // 打印网络结构
    cnn.print_architecture();
    
    // 创建随机输入数据
    std::vector<float> input(batch_size * input_channels * input_height * input_width);
    std::default_random_engine generator;
    std::normal_distribution<float> distribution(0.0f, 1.0f);
    
    for (size_t i = 0; i < input.size(); i++) {
        input[i] = distribution(generator);
    }
    
    // 前向传播
    std::cout << "\nPerforming forward pass..." << std::endl;
    auto output = cnn.forward(input, batch_size, true);
    
    if (!output.empty()) {
        std::cout << "Forward pass successful!" << std::endl;
        std::cout << "Input size: " << input.size() << std::endl;
        std::cout << "Output size: " << output.size() << std::endl;
        
        // 计算输出统计信息
        float sum = 0.0f, max_val = output[0], min_val = output[0];
        for (float val : output) {
            sum += val;
            if (val > max_val) max_val = val;
            if (val < min_val) min_val = val;
        }
        
        std::cout << "Output statistics:" << std::endl;
        std::cout << "  Mean: " << sum / output.size() << std::endl;
        std::cout << "  Min: " << min_val << std::endl;
        std::cout << "  Max: " << max_val << std::endl;
    }
}

int main() {
    test_cnn_pipeline();
    return 0;
}