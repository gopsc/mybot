#pragma once
#include <iostream>
#include <vector>
#include <algorithm>
#include <functional>
#include <tuple>
#include "ConvLayer.hpp"

class FlattenLayer {
private:
    // 输入输出尺寸
    int batch_size;
    int input_channels;
    int input_height;
    int input_width;
    int output_size;
    
    // 缓存输入形状（用于反向传播）
    std::vector<int> input_shape_cache;
    std::vector<float> input_cache;  // 缓存输入数据（可选）
    
    // 辅助函数
    //void flatten_forward(const float* input, float* output);
    //void flatten_backward(const float* grad_output, float* grad_input);
    
public:
    // 构造函数
    FlattenLayer() : batch_size(0), input_channels(0), 
                     input_height(0), input_width(0), output_size(0) {}
    
    // 设置输入尺寸（自动计算输出尺寸）
    void set_input_shape(int channels, int height, int width, int batch = 1) {
        input_channels = channels;
        input_height = height;
        input_width = width;
        batch_size = batch;
        
        // 计算输出大小
        output_size = channels * height * width;
        
        // 缓存输入形状
        input_shape_cache = {channels, height, width, batch};
    }
    
    // 设置输入尺寸（从卷积/池化层获取）
    template<typename... Args>
    void set_input_shape(std::tuple<Args...> shape_tuple) {
        set_input_shape(std::get<0>(shape_tuple), 
                       std::get<1>(shape_tuple), 
                       std::get<2>(shape_tuple));
    }
    
    // 前向传播
    std::vector<float> forward(const std::vector<float>& input, int batch_size = 1, bool training = true) {
        // 如果之前没有设置输入尺寸，自动推断
        if (input_channels == 0 && input_height == 0 && input_width == 0) {
            // 这里假设输入是完整的batch数据，需要外部调用set_input_shape
            // 或者根据输入大小推断（但不知道高度和宽度）
            std::cerr << "Warning: Input shape not set for FlattenLayer. "
                      << "Please call set_input_shape() first." << std::endl;
            return input;  // 安全返回，但可能不正确
        }
        
        // 检查输入大小是否匹配
        int expected_input_size = batch_size * input_channels * input_height * input_width;
        if (input.size() != static_cast<size_t>(expected_input_size)) {
            std::cerr << "Error: Input size mismatch in FlattenLayer. "
                      << "Expected: " << expected_input_size 
                      << ", Got: " << input.size() << std::endl;
            return std::vector<float>();
        }
        
        // 如果训练模式，缓存输入形状
        if (training) {
            this->batch_size = batch_size;
            input_shape_cache = {input_channels, input_height, input_width, batch_size};
            input_cache = input;  // 可选：缓存输入数据
        }
        
        // 计算输出大小
        int output_total_size = batch_size * output_size;
        std::vector<float> output(output_total_size, 0.0f);
        
        // 执行展平操作
        flatten_forward(input.data(), output.data());
        
        return output;
    }
    
    // 反向传播
    std::vector<float> backward(const std::vector<float>& grad_output, int batch_size = 1) {
        // 检查梯度大小是否匹配
        int expected_grad_size = batch_size * output_size;
        if (grad_output.size() != static_cast<size_t>(expected_grad_size)) {
            std::cerr << "Error: Gradient size mismatch in FlattenLayer. "
                      << "Expected: " << expected_grad_size 
                      << ", Got: " << grad_output.size() << std::endl;
            return std::vector<float>();
        }
        
        // 恢复输入形状
        if (input_shape_cache.size() >= 4) {
            input_channels = input_shape_cache[0];
            input_height = input_shape_cache[1];
            input_width = input_shape_cache[2];
            this->batch_size = input_shape_cache[3];
        }
        
        // 计算输入梯度大小
        int input_total_size = this->batch_size * input_channels * input_height * input_width;
        std::vector<float> grad_input(input_total_size, 0.0f);
        
        // 执行反向展平操作
        flatten_backward(grad_output.data(), grad_input.data());
        
        return grad_input;
    }
    
    // 获取输出尺寸
    int get_output_size() const {
        return output_size;
    }
    
    // 获取输出尺寸（返回元组）
    std::tuple<int> get_output_shape() const {
        return std::make_tuple(output_size);
    }
    
    // 获取输入尺寸
    std::tuple<int, int, int> get_input_shape() const {
        return std::make_tuple(input_channels, input_height, input_width);
    }
    
    // 获取完整输入尺寸（包含批次）
    std::tuple<int, int, int, int> get_full_input_shape() const {
        return std::make_tuple(input_channels, input_height, input_width, batch_size);
    }
    
    // 打印层信息
    void print_info() const {
        std::cout << "Flatten Layer Info:" << std::endl;
        std::cout << "  Input Shape: " << input_channels << "x" 
                  << input_height << "x" << input_width;
        if (batch_size > 0) {
            std::cout << " (batch: " << batch_size << ")";
        }
        std::cout << std::endl;
        std::cout << "  Output Size: " << output_size;
        if (batch_size > 0) {
            std::cout << " (total: " << batch_size * output_size << ")";
        }
        std::cout << std::endl;
    }
    
    // 重置层状态
    void reset() {
        input_shape_cache.clear();
        input_cache.clear();
        batch_size = 0;
        input_channels = 0;
        input_height = 0;
        input_width = 0;
        output_size = 0;
    }
    
    // 检查是否已初始化
    bool is_initialized() const {
        return input_channels > 0 && input_height > 0 && input_width > 0;
    }
    
private:
    // 展平前向传播实现
    void flatten_forward(const float* input, float* output) {
        // 简单地将多维数据复制到一维数组
        int elements_per_sample = input_channels * input_height * input_width;
        
        for (int b = 0; b < batch_size; b++) {
            const float* input_ptr = input + b * elements_per_sample;
            float* output_ptr = output + b * output_size;
            
            // 直接内存复制
            std::copy(input_ptr, input_ptr + elements_per_sample, output_ptr);
            
            // 或者使用循环（等效）
            /*
            for (int i = 0; i < elements_per_sample; i++) {
                output_ptr[i] = input_ptr[i];
            }
            */
        }
    }
    
    // 展平反向传播实现
    void flatten_backward(const float* grad_output, float* grad_input) {
        // 反向传播只是将梯度重新整形为输入形状
        int elements_per_sample = input_channels * input_height * input_width;
        
        for (int b = 0; b < batch_size; b++) {
            const float* grad_output_ptr = grad_output + b * output_size;
            float* grad_input_ptr = grad_input + b * elements_per_sample;
            
            // 直接内存复制
            std::copy(grad_output_ptr, grad_output_ptr + elements_per_sample, grad_input_ptr);
            
            // 或者使用循环（等效）
            /*
            for (int i = 0; i < elements_per_sample; i++) {
                grad_input_ptr[i] = grad_output_ptr[i];
            }
            */
        }
    }
};

// 动态展平层（自动推断输入形状）
class DynamicFlattenLayer {
private:
    int batch_size;
    int input_channels;
    int input_height;
    int input_width;
    int output_size;
    
public:
    DynamicFlattenLayer() : batch_size(0), input_channels(0), 
                           input_height(0), input_width(0), output_size(0) {}
    
    // 前向传播（自动推断形状）
    std::vector<float> forward(const std::vector<float>& input, 
                               std::tuple<int, int, int> input_shape,
                               int batch_size = 1, 
                               bool training = true) {
        // 从元组获取输入形状
        input_channels = std::get<0>(input_shape);
        input_height = std::get<1>(input_shape);
        input_width = std::get<2>(input_shape);
        this->batch_size = batch_size;
        
        // 验证输入大小
        int expected_size = batch_size * input_channels * input_height * input_width;
        if (input.size() != static_cast<size_t>(expected_size)) {
            std::cerr << "Error: Input size mismatch in DynamicFlattenLayer. "
                      << "Expected: " << expected_size 
                      << ", Got: " << input.size() 
                      << " (shape: " << input_channels << "x" 
                      << input_height << "x" << input_width 
                      << ", batch: " << batch_size << ")" << std::endl;
            return std::vector<float>();
        }
        
        // 计算输出大小
        output_size = input_channels * input_height * input_width;
        int total_output_size = batch_size * output_size;
        std::vector<float> output(total_output_size);
        
        // 执行展平
        const float* input_ptr = input.data();
        float* output_ptr = output.data();
        
        int elements_per_sample = output_size;
        for (int b = 0; b < batch_size; b++) {
            std::copy(input_ptr, input_ptr + elements_per_sample, output_ptr);
            input_ptr += elements_per_sample;
            output_ptr += elements_per_sample;
        }
        
        return output;
    }
    
    // 反向传播
    std::vector<float> backward(const std::vector<float>& grad_output, int batch_size = 1) {
        // 检查是否已初始化
        if (output_size == 0) {
            std::cerr << "Error: DynamicFlattenLayer not initialized. "
                      << "Call forward() first." << std::endl;
            return std::vector<float>();
        }
        
        // 验证梯度大小
        int expected_grad_size = batch_size * output_size;
        if (grad_output.size() != static_cast<size_t>(expected_grad_size)) {
            std::cerr << "Error: Gradient size mismatch in DynamicFlattenLayer. "
                      << "Expected: " << expected_grad_size 
                      << ", Got: " << grad_output.size() << std::endl;
            return std::vector<float>();
        }
        
        // 恢复输入形状
        int total_input_size = batch_size * input_channels * input_height * input_width;
        std::vector<float> grad_input(total_input_size);
        
        // 执行反向展平
        const float* grad_output_ptr = grad_output.data();
        float* grad_input_ptr = grad_input.data();
        
        int elements_per_sample = output_size;
        for (int b = 0; b < batch_size; b++) {
            std::copy(grad_output_ptr, grad_output_ptr + elements_per_sample, grad_input_ptr);
            grad_output_ptr += elements_per_sample;
            grad_input_ptr += elements_per_sample;
        }
        
        return grad_input;
    }
    
    // 获取输出尺寸
    int get_output_size() const { return output_size; }
    
    // 获取输入形状
    std::tuple<int, int, int> get_input_shape() const {
        return std::make_tuple(input_channels, input_height, input_width);
    }
};

// 使用示例函数
inline void flatten_layer_example() {
    std::cout << "=== Flatten Layer Example ===" << std::endl;
    
    // 创建展平层
    FlattenLayer flatten;
    
    // 设置输入形状（例如从池化层获取的输出）
    // 假设池化层输出：64通道，7x7特征图
    flatten.set_input_shape(64, 7, 7);
    
    // 创建模拟输入数据（batch_size=2）
    int batch_size = 2;
    std::vector<float> input(2 * 64 * 7 * 7);
    for (size_t i = 0; i < input.size(); i++) {
        input[i] = static_cast<float>(i) / 100.0f;
    }
    
    // 前向传播
    std::cout << "Forward pass..." << std::endl;
    auto output = flatten.forward(input, batch_size, true);
    
    std::cout << "Input size: " << input.size() << std::endl;
    std::cout << "Output size: " << output.size() << std::endl;
    std::cout << "Expected output size per sample: " << flatten.get_output_size() << std::endl;
    
    // 打印部分结果
    std::cout << "First 10 output values: ";
    for (int i = 0; i < std::min(10, static_cast<int>(output.size())); i++) {
        std::cout << output[i] << " ";
    }
    std::cout << std::endl;
    
    // 创建模拟梯度（全为1）
    std::vector<float> grad_output(output.size(), 1.0f);
    
    // 反向传播
    std::cout << "Backward pass..." << std::endl;
    auto grad_input = flatten.backward(grad_output, batch_size);
    
    std::cout << "Gradient input size: " << grad_input.size() << std::endl;
    std::cout << "Expected gradient input size: " << 2 * 64 * 7 * 7 << std::endl;
    
    // 验证形状正确性
    auto [channels, height, width] = flatten.get_input_shape();
    std::cout << "Recovered input shape: " << channels 
              << "x" << height << "x" << width << std::endl;
    
    // 打印层信息
    flatten.print_info();
}

