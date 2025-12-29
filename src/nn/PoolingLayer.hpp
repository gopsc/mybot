#pragma once
#include <iostream>
#include <vector>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <functional>

class PoolingLayer {
private:
    // 池化类型枚举
    enum class PoolType {
        MAX,
        AVG
    };
    
    // 参数
    int pool_height;
    int pool_width;
    int stride;
    int padding;
    PoolType pool_type;
    
    // 输入输出尺寸
    int input_channels;
    int input_height;
    int input_width;
    int output_height;
    int output_width;
    
    // 中间变量缓存（用于反向传播）
    std::vector<int> max_idx_cache;  // 最大池化时缓存最大值位置
    std::vector<float> input_cache;  // 缓存的输入
    std::vector<float> output_cache; // 缓存的输出
    
    // 辅助函数
    //void max_pool_forward(const float* input, float* output, int batch_size);
    //void avg_pool_forward(const float* input, float* output, int batch_size);
    //void max_pool_backward(const float* grad_output, float* grad_input, int batch_size);
    //void avg_pool_backward(const float* grad_output, float* grad_input, int batch_size);
    
public:
    // 构造函数
    PoolingLayer(int pool_size, int stride = 2, int padding = 0, bool max_pool = true)
        : pool_height(pool_size),
          pool_width(pool_size),
          stride(stride),
          padding(padding),
          pool_type(max_pool ? PoolType::MAX : PoolType::AVG) {}
    
    // 带不同高度和宽度的构造函数
    PoolingLayer(int pool_height, int pool_width, int stride = 2, int padding = 0, bool max_pool = true)
        : pool_height(pool_height),
          pool_width(pool_width),
          stride(stride),
          padding(padding),
          pool_type(max_pool ? PoolType::MAX : PoolType::AVG) {}
    
    // 设置输入尺寸
    void set_input_shape(int channels, int height, int width) {
        input_channels = channels;
        input_height = height;
        input_width = width;
        
        // 计算输出尺寸
        output_height = (height + 2 * padding - pool_height) / stride + 1;
        output_width = (width + 2 * padding - pool_width) / stride + 1;
        
        // 清空缓存
        max_idx_cache.clear();
        input_cache.clear();
        output_cache.clear();
    }
    
    // 前向传播
    std::vector<float> forward(const std::vector<float>& input, int batch_size = 1, bool training = true) {
        // 计算输出大小
        int output_size = batch_size * input_channels * output_height * output_width;
        std::vector<float> output(output_size, 0.0f);
        
        // 如果训练模式，缓存输入
        if (training) {
            input_cache = input;
        }
        
        // 根据池化类型选择前向传播函数
        if (pool_type == PoolType::MAX) {
            max_pool_forward(input.data(), output.data(), batch_size);
        } else {
            avg_pool_forward(input.data(), output.data(), batch_size);
        }
        
        // 如果训练模式，缓存输出
        if (training) {
            output_cache = output;
        }
        
        return output;
    }
    
    // 反向传播
    std::vector<float> backward(const std::vector<float>& grad_output, int batch_size = 1) {
        // 创建输入梯度
        std::vector<float> grad_input(batch_size * input_channels * input_height * input_width, 0.0f);
        
        // 根据池化类型选择反向传播函数
        if (pool_type == PoolType::MAX) {
            max_pool_backward(grad_output.data(), grad_input.data(), batch_size);
        } else {
            avg_pool_backward(grad_output.data(), grad_input.data(), batch_size);
        }
        
        return grad_input;
    }
    
    // 获取输出尺寸
    std::tuple<int, int, int> get_output_shape() const {
        return std::make_tuple(input_channels, output_height, output_width);
    }
    
    // 获取参数信息
    void print_info() const {
        std::cout << "Pooling Layer Info:" << std::endl;
        std::cout << "  Type: " << (pool_type == PoolType::MAX ? "Max Pooling" : "Average Pooling") << std::endl;
        std::cout << "  Pool Size: " << pool_height << "x" << pool_width << std::endl;
        std::cout << "  Stride: " << stride << std::endl;
        std::cout << "  Padding: " << padding << std::endl;
        std::cout << "  Input Shape: " << input_channels << "x" << input_height << "x" << input_width << std::endl;
        std::cout << "  Output Shape: " << input_channels << "x" << output_height << "x" << output_width << std::endl;
    }
    
private:
    // 最大池化前向传播实现
    void max_pool_forward(const float* input, float* output, int batch_size) {
        // 计算填充后的尺寸
        int padded_height = input_height + 2 * padding;
        int padded_width = input_width + 2 * padding;
        
        // 清空最大值位置缓存
        max_idx_cache.clear();
        max_idx_cache.resize(batch_size * input_channels * output_height * output_width, -1);
        
        // 对每个批次、每个通道进行处理
        for (int b = 0; b < batch_size; b++) {
            for (int c = 0; c < input_channels; c++) {
                // 当前通道的输入和输出指针
                const float* input_ptr = input + b * input_channels * input_height * input_width + 
                                         c * input_height * input_width;
                float* output_ptr = output + b * input_channels * output_height * output_width + 
                                    c * output_height * output_width;
                int* max_idx_ptr = max_idx_cache.data() + b * input_channels * output_height * output_width + 
                                   c * output_height * output_width;
                
                // 对每个输出位置进行计算
                for (int oh = 0; oh < output_height; oh++) {
                    for (int ow = 0; ow < output_width; ow++) {
                        // 计算池化窗口的起始位置
                        int start_h = oh * stride - padding;
                        int start_w = ow * stride - padding;
                        
                        // 计算池化窗口的结束位置
                        int end_h = std::min(start_h + pool_height, padded_height);
                        int end_w = std::min(start_w + pool_width, padded_width);
                        
                        // 调整起始位置，确保不超出边界
                        start_h = std::max(start_h, 0);
                        start_w = std::max(start_w, 0);
                        
                        // 在池化窗口内寻找最大值
                        float max_val = -std::numeric_limits<float>::max();
                        int max_idx = -1;
                        
                        for (int ph = start_h; ph < end_h; ph++) {
                            for (int pw = start_w; pw < end_w; pw++) {
                                // 计算原始输入中的索引（考虑填充）
                                int orig_ph = ph - padding;
                                int orig_pw = pw - padding;
                                
                                // 检查是否在有效范围内
                                if (orig_ph >= 0 && orig_ph < input_height && 
                                    orig_pw >= 0 && orig_pw < input_width) {
                                    int idx = orig_ph * input_width + orig_pw;
                                    float val = input_ptr[idx];
                                    
                                    if (val > max_val) {
                                        max_val = val;
                                        max_idx = idx;
                                    }
                                }
                            }
                        }
                        
                        // 存储输出和最大值位置
                        output_ptr[oh * output_width + ow] = max_val;
                        max_idx_ptr[oh * output_width + ow] = max_idx;
                    }
                }
            }
        }
    }
    
    // 平均池化前向传播实现
    void avg_pool_forward(const float* input, float* output, int batch_size) {
        // 计算填充后的尺寸
        int padded_height = input_height + 2 * padding;
        int padded_width = input_width + 2 * padding;
        
        // 对每个批次、每个通道进行处理
        for (int b = 0; b < batch_size; b++) {
            for (int c = 0; c < input_channels; c++) {
                // 当前通道的输入和输出指针
                const float* input_ptr = input + b * input_channels * input_height * input_width + 
                                         c * input_height * input_width;
                float* output_ptr = output + b * input_channels * output_height * output_width + 
                                    c * output_height * output_width;
                
                // 对每个输出位置进行计算
                for (int oh = 0; oh < output_height; oh++) {
                    for (int ow = 0; ow < output_width; ow++) {
                        // 计算池化窗口的起始位置
                        int start_h = oh * stride - padding;
                        int start_w = ow * stride - padding;
                        
                        // 计算池化窗口的结束位置
                        int end_h = std::min(start_h + pool_height, padded_height);
                        int end_w = std::min(start_w + pool_width, padded_width);
                        
                        // 调整起始位置，确保不超出边界
                        start_h = std::max(start_h, 0);
                        start_w = std::max(start_w, 0);
                        
                        // 在池化窗口内计算平均值
                        float sum = 0.0f;
                        int count = 0;
                        
                        for (int ph = start_h; ph < end_h; ph++) {
                            for (int pw = start_w; pw < end_w; pw++) {
                                // 计算原始输入中的索引（考虑填充）
                                int orig_ph = ph - padding;
                                int orig_pw = pw - padding;
                                
                                // 检查是否在有效范围内
                                if (orig_ph >= 0 && orig_ph < input_height && 
                                    orig_pw >= 0 && orig_pw < input_width) {
                                    int idx = orig_ph * input_width + orig_pw;
                                    sum += input_ptr[idx];
                                    count++;
                                }
                            }
                        }
                        
                        // 计算平均值
                        output_ptr[oh * output_width + ow] = (count > 0) ? sum / count : 0.0f;
                    }
                }
            }
        }
    }
    
    // 最大池化反向传播实现
    void max_pool_backward(const float* grad_output, float* grad_input, int batch_size) {
        // 初始化输入梯度为0
        std::memset(grad_input, 0, batch_size * input_channels * input_height * input_width * sizeof(float));
        
        // 对每个批次、每个通道进行处理
        for (int b = 0; b < batch_size; b++) {
            for (int c = 0; c < input_channels; c++) {
                // 当前通道的梯度指针
                const float* grad_output_ptr = grad_output + b * input_channels * output_height * output_width + 
                                               c * output_height * output_width;
                float* grad_input_ptr = grad_input + b * input_channels * input_height * input_width + 
                                        c * input_height * input_width;
                const int* max_idx_ptr = max_idx_cache.data() + b * input_channels * output_height * output_width + 
                                         c * output_height * output_width;
                
                // 对每个输出位置进行反向传播
                for (int oh = 0; oh < output_height; oh++) {
                    for (int ow = 0; ow < output_width; ow++) {
                        // 获取最大值位置索引
                        int max_idx = max_idx_ptr[oh * output_width + ow];
                        
                        // 如果最大值位置有效，将梯度传递到该位置
                        if (max_idx >= 0) {
                            grad_input_ptr[max_idx] += grad_output_ptr[oh * output_width + ow];
                        }
                    }
                }
            }
        }
    }
    
    // 平均池化反向传播实现
    void avg_pool_backward(const float* grad_output, float* grad_input, int batch_size) {
        // 初始化输入梯度为0
        std::memset(grad_input, 0, batch_size * input_channels * input_height * input_width * sizeof(float));
        
        // 计算填充后的尺寸
        int padded_height = input_height + 2 * padding;
        int padded_width = input_width + 2 * padding;
        
        // 对每个批次、每个通道进行处理
        for (int b = 0; b < batch_size; b++) {
            for (int c = 0; c < input_channels; c++) {
                // 当前通道的梯度指针
                const float* grad_output_ptr = grad_output + b * input_channels * output_height * output_width + 
                                               c * output_height * output_width;
                float* grad_input_ptr = grad_input + b * input_channels * input_height * input_width + 
                                        c * input_height * input_width;
                
                // 对每个输出位置进行反向传播
                for (int oh = 0; oh < output_height; oh++) {
                    for (int ow = 0; ow < output_width; ow++) {
                        // 计算池化窗口的起始位置
                        int start_h = oh * stride - padding;
                        int start_w = ow * stride - padding;
                        
                        // 计算池化窗口的结束位置
                        int end_h = std::min(start_h + pool_height, padded_height);
                        int end_w = std::min(start_w + pool_width, padded_width);
                        
                        // 调整起始位置，确保不超出边界
                        start_h = std::max(start_h, 0);
                        start_w = std::max(start_w, 0);
                        
                        // 计算有效池化窗口的大小
                        int count = 0;
                        for (int ph = start_h; ph < end_h; ph++) {
                            for (int pw = start_w; pw < end_w; pw++) {
                                // 计算原始输入中的索引（考虑填充）
                                int orig_ph = ph - padding;
                                int orig_pw = pw - padding;
                                
                                // 检查是否在有效范围内
                                if (orig_ph >= 0 && orig_ph < input_height && 
                                    orig_pw >= 0 && orig_pw < input_width) {
                                    count++;
                                }
                            }
                        }
                        
                        // 如果池化窗口内有有效元素，计算平均梯度
                        if (count > 0) {
                            float avg_grad = grad_output_ptr[oh * output_width + ow] / count;
                            
                            // 将平均梯度分配到池化窗口内的每个位置
                            for (int ph = start_h; ph < end_h; ph++) {
                                for (int pw = start_w; pw < end_w; pw++) {
                                    // 计算原始输入中的索引（考虑填充）
                                    int orig_ph = ph - padding;
                                    int orig_pw = pw - padding;
                                    
                                    // 检查是否在有效范围内
                                    if (orig_ph >= 0 && orig_ph < input_height && 
                                        orig_pw >= 0 && orig_pw < input_width) {
                                        int idx = orig_ph * input_width + orig_pw;
                                        grad_input_ptr[idx] += avg_grad;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
};

// 使用示例函数
inline void pooling_layer_example() {
    std::cout << "=== Pooling Layer Example ===" << std::endl;
    
    // 创建最大池化层
    PoolingLayer max_pool(2, 2, 0, true);  // 2x2 最大池化，步长2，无填充
    max_pool.set_input_shape(3, 4, 4);     // 3个通道，4x4输入
    
    // 创建输入数据
    std::vector<float> input(3 * 4 * 4);
    for (int i = 0; i < 3 * 4 * 4; i++) {
        input[i] = static_cast<float>(i) / 10.0f;
    }
    
    // 前向传播
    std::cout << "Forward pass..." << std::endl;
    auto output = max_pool.forward(input, 1, true);
    
    // 获取输出形状
    auto [channels, height, width] = max_pool.get_output_shape();
    std::cout << "Output shape: " << channels << "x" << height << "x" << width << std::endl;
    
    // 打印输出
    std::cout << "Output values (first 10): ";
    for (int i = 0; i < std::min(10, static_cast<int>(output.size())); i++) {
        std::cout << output[i] << " ";
    }
    std::cout << std::endl;
    
    // 创建梯度（假设全为1）
    std::vector<float> grad_output(output.size(), 1.0f);
    
    // 反向传播
    std::cout << "Backward pass..." << std::endl;
    auto grad_input = max_pool.backward(grad_output, 1);
    
    std::cout << "Gradient input size: " << grad_input.size() << std::endl;
    std::cout << "Gradient input values (first 10): ";
    for (int i = 0; i < std::min(10, static_cast<int>(grad_input.size())); i++) {
        std::cout << grad_input[i] << " ";
    }
    std::cout << std::endl;
    
    // 打印层信息
    max_pool.print_info();
}

// 全局平均池化层（常用于CNN分类网络的最后）
class GlobalAveragePooling {
private:
    int input_channels;
    int input_height;
    int input_width;
    std::vector<float> input_cache;
    
public:
    // 设置输入尺寸
    void set_input_shape(int channels, int height, int width) {
        input_channels = channels;
        input_height = height;
        input_width = width;
    }
    
    // 前向传播
    std::vector<float> forward(const std::vector<float>& input, int batch_size = 1, bool training = true) {
        // 缓存输入（如果需要）
        if (training) {
            input_cache = input;
        }
        
        // 计算输出大小：每个通道一个值
        int output_size = batch_size * input_channels;
        std::vector<float> output(output_size, 0.0f);
        
        // 对每个批次、每个通道计算平均值
        int spatial_size = input_height * input_width;
        for (int b = 0; b < batch_size; b++) {
            for (int c = 0; c < input_channels; c++) {
                const float* input_ptr = input.data() + b * input_channels * spatial_size + c * spatial_size;
                float sum = 0.0f;
                
                // 计算该通道所有空间位置的平均值
                for (int i = 0; i < spatial_size; i++) {
                    sum += input_ptr[i];
                }
                
                output[b * input_channels + c] = sum / spatial_size;
            }
        }
        
        return output;
    }
    
    // 反向传播
    std::vector<float> backward(const std::vector<float>& grad_output, int batch_size = 1) {
        // 创建输入梯度
        int spatial_size = input_height * input_width;
        std::vector<float> grad_input(batch_size * input_channels * spatial_size, 0.0f);
        
        // 对每个批次、每个通道分配梯度
        for (int b = 0; b < batch_size; b++) {
            for (int c = 0; c < input_channels; c++) {
                float grad = grad_output[b * input_channels + c] / spatial_size;
                float* grad_input_ptr = grad_input.data() + b * input_channels * spatial_size + c * spatial_size;
                
                // 将梯度均匀分配到所有空间位置
                for (int i = 0; i < spatial_size; i++) {
                    grad_input_ptr[i] = grad;
                }
            }
        }
        
        return grad_input;
    }
    
    // 获取输出尺寸
    std::tuple<int, int> get_output_shape() const {
        return std::make_tuple(input_channels, 1);
    }
};

/*

// 创建池化层
PoolingLayer pool(2, 2, 0, true);  // 2x2最大池化，步长2，无填充
pool.set_input_shape(64, 28, 28);  // 64通道，28x28输入

// 前向传播
auto output = pool.forward(input, batch_size, true);

// 反向传播
auto grad_input = pool.backward(grad_output, batch_size);

*/