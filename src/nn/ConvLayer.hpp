#pragma once
#include <iostream>
#include <vector>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <chrono>
#include <random>
#include <numeric>
#include <functional>

class ConvLayer {
private:
    // 参数
    int input_channels;
    int output_channels;
    int kernel_size;
    int stride;
    int padding;
    int input_height;
    int input_width;
    int output_height;
    int output_width;
    
    // Leaky ReLU参数
    float negative_slope;  // Leaky ReLU的负斜率，通常为0.01
    
    // 权重和偏置
    std::vector<float> weights;  // shape: [output_channels, input_channels, kernel_size, kernel_size]
    std::vector<float> bias;     // shape: [output_channels]
    
    // 梯度和动量
    std::vector<float> d_weights;  // 权重梯度
    std::vector<float> d_bias;     // 偏置梯度
    std::vector<float> weight_momentum;  // 动量
    std::vector<float> bias_momentum;    // 偏置动量
    
    // 中间变量缓存（用于反向传播）
    std::vector<float> col_buffer;      // im2col后的矩阵
    std::vector<float> input_cache;     // 缓存的输入（用于计算输入梯度）
    std::vector<float> output_cache;    // 缓存的输出（激活前）
    std::vector<float> activated_cache; // 激活后的输出缓存
    std::vector<float> col_cache;       // 缓存的col矩阵（用于权重梯度计算）
    
    // 辅助函数
    void im2col(const float* input, int batch_size);
    void col2im(const float* col, float* im, int batch_size);
    void sgemm(int M, int N, int K, 
               const float* A, const float* B, float* C,
               bool transA = false, bool transB = false);
    void sgemm_add(int M, int N, int K,
                   const float* A, const float* B, float* C,
                   float alpha = 1.0f, float beta = 1.0f,
                   bool transA = false, bool transB = false);
    
    // Leaky ReLU激活函数及其导数
    inline float leaky_relu(float x) const {
        return x > 0 ? x : negative_slope * x;
    }
    
    inline float leaky_relu_derivative(float x) const {
        return x > 0 ? 1.0f : negative_slope;
    }
    
    // 应用激活函数到整个张量
    void apply_leaky_relu(float* data, int size) {
        for (int i = 0; i < size; i++) {
            data[i] = leaky_relu(data[i]);
        }
    }
    
    // 计算激活函数的梯度
    void compute_activation_gradient(const float* pre_activation, float* gradient, int size) {
        for (int i = 0; i < size; i++) {
            gradient[i] *= leaky_relu_derivative(pre_activation[i]);
        }
    }
    
public:
    // 构造函数 - 添加negative_slope参数
    ConvLayer(int in_channels, int out_channels, 
              int kernel_size, int stride = 1, int padding = 0, 
              float negative_slope = 0.01f)
        : input_channels(in_channels),
          output_channels(out_channels),
          kernel_size(kernel_size),
          stride(stride),
          padding(padding),
          negative_slope(negative_slope) {
        
        // 初始化权重和偏置
        int weight_size = out_channels * in_channels * kernel_size * kernel_size;
        weights.resize(weight_size);
        d_weights.resize(weight_size, 0.0f);
        weight_momentum.resize(weight_size, 0.0f);
        
        bias.resize(out_channels);
        d_bias.resize(out_channels, 0.0f);
        bias_momentum.resize(out_channels, 0.0f);
        
        // He初始化（适合ReLU激活函数）
        float std_dev = sqrt(2.0f / (in_channels * kernel_size * kernel_size));
        std::default_random_engine generator;
        std::normal_distribution<float> distribution(0.0f, std_dev);
        
        for (int i = 0; i < weight_size; i++) {
            weights[i] = distribution(generator);
        }
        
        for (int i = 0; i < out_channels; i++) {
            bias[i] = 0.1f;  // 小的正偏置
        }
    }
    
    // 设置输入尺寸（计算输出尺寸）
    void set_input_shape(int height, int width) {
        input_height = height;
        input_width = width;
        
        output_height = (height + 2 * padding - kernel_size) / stride + 1;
        output_width = (width + 2 * padding - kernel_size) / stride + 1;
        
        // 预分配缓冲区
        int col_height = input_channels * kernel_size * kernel_size;
        int col_width = output_height * output_width;
        col_buffer.resize(col_height * col_width);
        
        // 清空缓存
        input_cache.clear();
        output_cache.clear();
        activated_cache.clear();
        col_cache.clear();
    }
    
    // 前向传播
    std::vector<float> forward(const std::vector<float>& input, int batch_size = 1, bool training = true) {
        // 计算输出大小
        int output_size = batch_size * output_channels * output_height * output_width;
        std::vector<float> output(output_size, 0.0f);
        std::vector<float> pre_activation(output_size, 0.0f);  // 激活前的输出
        
        // 如果训练模式，缓存输入
        if (training) {
            input_cache = input;
        }
        
        // 对batch中的每个样本进行处理
        for (int b = 0; b < batch_size; b++) {
            const float* input_ptr = input.data() + b * input_channels * input_height * input_width;
            
            // 1. im2col转换
            im2col(input_ptr, 1);
            
            // 2. 矩阵乘法：weights * col_buffer
            int M = output_channels;  // 输出通道数
            int N = output_height * output_width;  // 输出特征图大小
            int K = input_channels * kernel_size * kernel_size;  // 卷积核展平大小
            
            // 如果训练模式，缓存col矩阵
            if (training && b == 0) {
                col_cache = col_buffer;
            }
            
            // 临时存储矩阵乘法结果（激活前）
            std::vector<float> gemm_result(M * N, 0.0f);
            sgemm(M, N, K, weights.data(), col_buffer.data(), gemm_result.data());
            
            // 3. 加上偏置并存储到pre_activation
            float* pre_activation_ptr = pre_activation.data() + b * output_channels * output_height * output_width;
            float* output_ptr = output.data() + b * output_channels * output_height * output_width;
            
            for (int oc = 0; oc < output_channels; oc++) {
                float bias_val = bias[oc];
                for (int i = 0; i < output_height * output_width; i++) {
                    float value = gemm_result[oc * N + i] + bias_val;
                    pre_activation_ptr[oc * output_height * output_width + i] = value;
                    
                    // 4. 应用Leaky ReLU激活函数
                    output_ptr[oc * output_height * output_width + i] = leaky_relu(value);
                }
            }
        }
        
        // 如果训练模式，缓存激活前和激活后的输出
        if (training) {
            output_cache = pre_activation;  // 缓存激活前的输出
            activated_cache = output;       // 缓存激活后的输出
        }
        
        return output;  // 返回激活后的输出
    }
    
    // 反向传播
    std::vector<float> backward(const std::vector<float>& grad_output, int batch_size = 1) {
        // grad_output是激活函数后的梯度，需要先计算激活函数前的梯度
        std::vector<float> grad_pre_activation(grad_output);
        
        // 计算激活函数的梯度：grad_pre_activation = grad_output * leaky_relu_derivative(pre_activation)
        for (int b = 0; b < batch_size; b++) {
            const float* pre_activation_ptr = output_cache.data() + b * output_channels * output_height * output_width;
            float* grad_ptr = grad_pre_activation.data() + b * output_channels * output_height * output_width;
            
            for (int i = 0; i < output_channels * output_height * output_width; i++) {
                grad_ptr[i] *= leaky_relu_derivative(pre_activation_ptr[i]);
            }
        }
        
        // 1. 计算偏置梯度: d_bias = sum(grad_pre_activation, axis=(0,2,3))
        std::fill(d_bias.begin(), d_bias.end(), 0.0f);
        for (int b = 0; b < batch_size; b++) {
            const float* grad_ptr = grad_pre_activation.data() + b * output_channels * output_height * output_width;
            for (int oc = 0; oc < output_channels; oc++) {
                float sum = 0.0f;
                for (int i = 0; i < output_height * output_width; i++) {
                    sum += grad_ptr[oc * output_height * output_width + i];
                }
                d_bias[oc] += sum;
            }
        }
        
        // 2. 计算权重梯度: d_weights = grad_pre_activation_col * col_cache^T
        std::fill(d_weights.begin(), d_weights.end(), 0.0f);
        
        int M = output_channels;  // 输出通道数
        int N = input_channels * kernel_size * kernel_size;  // 卷积核展平大小
        int K = output_height * output_width;  // 输出特征图大小
        
        // 将grad_pre_activation reshape为矩阵 [output_channels, batch_size * output_height * output_width]
        std::vector<float> grad_pre_activation_mat(M * K * batch_size, 0.0f);
        for (int b = 0; b < batch_size; b++) {
            const float* grad_ptr = grad_pre_activation.data() + b * output_channels * output_height * output_width;
            for (int oc = 0; oc < output_channels; oc++) {
                for (int i = 0; i < output_height * output_width; i++) {
                    grad_pre_activation_mat[oc * (K * batch_size) + b * K + i] = 
                        grad_ptr[oc * output_height * output_width + i];
                }
            }
        }
        
        // 扩展col_cache以匹配batch大小
        std::vector<float> col_cache_batched(N * K * batch_size, 0.0f);
        for (int b = 0; b < batch_size; b++) {
            std::copy(col_cache.begin(), col_cache.end(), 
                     col_cache_batched.begin() + b * N * K);
        }
        
        // 矩阵乘法: d_weights = grad_pre_activation_mat * col_cache_batched^T
        // grad_pre_activation_mat: [M, K*batch_size], col_cache_batched^T: [K*batch_size, N]
        sgemm_add(M, N, K * batch_size, 
                 grad_pre_activation_mat.data(), col_cache_batched.data(), d_weights.data(),
                 1.0f, 0.0f, false, true);
        
        // 3. 计算输入梯度: d_input_col = weights^T * grad_pre_activation_mat
        // 然后通过col2im将d_input_col转换为d_input
        std::vector<float> d_input(batch_size * input_channels * input_height * input_width, 0.0f);
        
        // 计算d_input_col
        std::vector<float> d_input_col(N * K * batch_size, 0.0f);
        sgemm(N, K * batch_size, M, 
              weights.data(), grad_pre_activation_mat.data(), d_input_col.data(),
              true, false);
        
        // 将d_input_col通过col2im转换回输入形状
        for (int b = 0; b < batch_size; b++) {
            float* d_input_ptr = d_input.data() + b * input_channels * input_height * input_width;
            col2im(d_input_col.data() + b * N * K, d_input_ptr, 1);
        }
        
        return d_input;
    }
    
    // 更新参数（使用SGD with momentum）
    void update_parameters(float learning_rate = 0.01f, float momentum = 0.9f) {
        // 更新权重
        for (size_t i = 0; i < weights.size(); i++) {
            weight_momentum[i] = momentum * weight_momentum[i] - learning_rate * d_weights[i];
            weights[i] += weight_momentum[i];
        }
        
        // 更新偏置
        for (size_t i = 0; i < bias.size(); i++) {
            bias_momentum[i] = momentum * bias_momentum[i] - learning_rate * d_bias[i];
            bias[i] += bias_momentum[i];
        }
        
        // 重置梯度（可选）
        // std::fill(d_weights.begin(), d_weights.end(), 0.0f);
        // std::fill(d_bias.begin(), d_bias.end(), 0.0f);
    }
    
    // Adam优化器更新参数
    void update_parameters_adam(float learning_rate = 0.001f, 
                               float beta1 = 0.9f, float beta2 = 0.999f,
                               float epsilon = 1e-8f, int t = 1) {
        static std::vector<float> m_weights(weights.size(), 0.0f);
        static std::vector<float> v_weights(weights.size(), 0.0f);
        static std::vector<float> m_bias(bias.size(), 0.0f);
        static std::vector<float> v_bias(bias.size(), 0.0f);
        
        // 更新权重的一阶矩和二阶矩估计
        for (size_t i = 0; i < weights.size(); i++) {
            m_weights[i] = beta1 * m_weights[i] + (1 - beta1) * d_weights[i];
            v_weights[i] = beta2 * v_weights[i] + (1 - beta2) * d_weights[i] * d_weights[i];
            
            // 偏差校正
            float m_hat = m_weights[i] / (1 - powf(beta1, t));
            float v_hat = v_weights[i] / (1 - powf(beta2, t));
            
            // 更新权重
            weights[i] -= learning_rate * m_hat / (sqrtf(v_hat) + epsilon);
        }
        
        // 更新偏置的一阶矩和二阶矩估计
        for (size_t i = 0; i < bias.size(); i++) {
            m_bias[i] = beta1 * m_bias[i] + (1 - beta1) * d_bias[i];
            v_bias[i] = beta2 * v_bias[i] + (1 - beta2) * d_bias[i] * d_bias[i];
            
            // 偏差校正
            float m_hat = m_bias[i] / (1 - powf(beta1, t));
            float v_hat = v_bias[i] / (1 - powf(beta2, t));
            
            // 更新偏置
            bias[i] -= learning_rate * m_hat / (sqrtf(v_hat) + epsilon);
        }
    }
    
    // 获取参数
    const std::vector<float>& get_weights() const { return weights; }
    const std::vector<float>& get_bias() const { return bias; }
    const std::vector<float>& get_weight_gradients() const { return d_weights; }
    const std::vector<float>& get_bias_gradients() const { return d_bias; }
    
    // 设置参数（用于加载预训练模型）
    void set_weights(const std::vector<float>& new_weights) { weights = new_weights; }
    void set_bias(const std::vector<float>& new_bias) { bias = new_bias; }
    
    // 设置Leaky ReLU参数
    void set_leaky_relu_slope(float slope) { negative_slope = slope; }
    
    // 获取输出尺寸
    std::tuple<int, int> get_output_shape() const {
        return std::make_tuple(output_height, output_width);
    }
    
    // 梯度检查（用于调试）
    float gradient_check(const std::vector<float>& input, 
                        const std::vector<float>& grad_output,
                        int weight_idx, float epsilon = 1e-5f) {
        // 保存原始权重
        float original_weight = weights[weight_idx];
        
        // 计算f(x + epsilon)
        weights[weight_idx] = original_weight + epsilon;
        auto output_plus = forward(input, 1, false);
        
        // 计算f(x - epsilon)
        weights[weight_idx] = original_weight - epsilon;
        auto output_minus = forward(input, 1, false);
        
        // 恢复原始权重
        weights[weight_idx] = original_weight;
        
        // 计算数值梯度
        float numerical_grad = 0.0f;
        for (size_t i = 0; i < output_plus.size(); i++) {
            numerical_grad += grad_output[i] * (output_plus[i] - output_minus[i]) / (2 * epsilon);
        }
        
        // 返回梯度差异
        return fabs(numerical_grad - d_weights[weight_idx]);
    }
};

// im2col实现 - 将图像转换为矩阵
void ConvLayer::im2col(const float* input, int batch_size) {
    int col_height = input_channels * kernel_size * kernel_size;
    int col_width = output_height * output_width;
    
    int input_h_padded = input_height + 2 * padding;
    int input_w_padded = input_width + 2 * padding;
    
    // 创建填充后的输入（如果需要）
    std::vector<float> padded_input;
    const float* input_data = input;
    
    if (padding > 0) {
        padded_input.resize(input_channels * input_h_padded * input_w_padded, 0.0f);
        for (int c = 0; c < input_channels; c++) {
            for (int h = 0; h < input_height; h++) {
                for (int w = 0; w < input_width; w++) {
                    int padded_idx = c * input_h_padded * input_w_padded + 
                                     (h + padding) * input_h_padded + (w + padding);
                    int orig_idx = c * input_height * input_width + h * input_width + w;
                    padded_input[padded_idx] = input[orig_idx];
                }
            }
        }
        input_data = padded_input.data();
    }
    
    // 执行im2col
    int col_idx = 0;
    for (int c = 0; c < input_channels; c++) {
        for (int kh = 0; kh < kernel_size; kh++) {
            for (int kw = 0; kw < kernel_size; kw++) {
                for (int h = 0; h < output_height; h++) {
                    for (int w = 0; w < output_width; w++) {
                        int input_h = h * stride + kh;
                        int input_w = w * stride + kw;
                        
                        int input_idx = c * input_h_padded * input_w_padded + 
                                        input_h * input_w_padded + input_w;
                        
                        col_buffer[col_idx++] = input_data[input_idx];
                    }
                }
            }
        }
    }
}

// col2im实现 - 将矩阵转换回图像（用于梯度传播）
void ConvLayer::col2im(const float* col, float* im, int batch_size) {
    int col_height = input_channels * kernel_size * kernel_size;
    int col_width = output_height * output_width;
    
    int input_h_padded = input_height + 2 * padding;
    int input_w_padded = input_width + 2 * padding;
    
    // 创建填充后的图像缓冲区
    std::vector<float> padded_im(input_channels * input_h_padded * input_w_padded, 0.0f);
    
    // 执行col2im
    int col_idx = 0;
    for (int c = 0; c < input_channels; c++) {
        for (int kh = 0; kh < kernel_size; kh++) {
            for (int kw = 0; kw < kernel_size; kw++) {
                for (int h = 0; h < output_height; h++) {
                    for (int w = 0; w < output_width; w++) {
                        int input_h = h * stride + kh;
                        int input_w = w * stride + kw;
                        
                        int input_idx = c * input_h_padded * input_w_padded + 
                                        input_h * input_w_padded + input_w;
                        
                        padded_im[input_idx] += col[col_idx++];
                    }
                }
            }
        }
    }
    
    // 去除padding，得到原始输入梯度
    if (padding > 0) {
        for (int c = 0; c < input_channels; c++) {
            for (int h = 0; h < input_height; h++) {
                for (int w = 0; w < input_width; w++) {
                    int padded_idx = c * input_h_padded * input_w_padded + 
                                     (h + padding) * input_w_padded + (w + padding);
                    int orig_idx = c * input_height * input_width + h * input_width + w;
                    im[orig_idx] = padded_im[padded_idx];
                }
            }
        }
    } else {
        std::copy(padded_im.begin(), padded_im.end(), im);
    }
}

// 优化的矩阵乘法
void ConvLayer::sgemm(int M, int N, int K, 
                      const float* A, const float* B, float* C,
                      bool transA, bool transB) {
    // 初始化输出为0
    std::memset(C, 0, M * N * sizeof(float));
    
    // 调用带参数的版本
    sgemm_add(M, N, K, A, B, C, 1.0f, 0.0f, transA, transB);
}

// 带参数的矩阵乘法（支持转置）
void ConvLayer::sgemm_add(int M, int N, int K,
                          const float* A, const float* B, float* C,
                          float alpha, float beta,
                          bool transA, bool transB) {
    // 如果beta为0，清空C
    if (beta == 0.0f) {
        std::memset(C, 0, M * N * sizeof(float));
    }
    
    // 优化：使用循环展开和缓存友好的访问模式
    const int BLOCK_SIZE = 4;
    
    // 处理A转置的情况
    if (transA && !transB) {
        // C = A^T * B
        for (int i = 0; i < M; i++) {
            for (int k = 0; k < K; k++) {
                float a = A[k * M + i] * alpha;
                if (a == 0.0f) continue;
                
                const float* B_ptr = B + k * N;
                float* C_ptr = C + i * N;
                
                int j = 0;
                for (; j <= N - BLOCK_SIZE; j += BLOCK_SIZE) {
                    C_ptr[j] += a * B_ptr[j];
                    C_ptr[j + 1] += a * B_ptr[j + 1];
                    C_ptr[j + 2] += a * B_ptr[j + 2];
                    C_ptr[j + 3] += a * B_ptr[j + 3];
                }
                for (; j < N; j++) {
                    C_ptr[j] += a * B_ptr[j];
                }
            }
        }
    } else if (!transA && transB) {
        // C = A * B^T
        for (int i = 0; i < M; i++) {
            for (int j = 0; j < N; j++) {
                float sum = 0.0f;
                for (int k = 0; k < K; k++) {
                    sum += A[i * K + k] * B[j * K + k];
                }
                C[i * N + j] = beta * C[i * N + j] + alpha * sum;
            }
        }
    } else if (transA && transB) {
        // C = A^T * B^T = (B * A)^T
        for (int i = 0; i < M; i++) {
            for (int j = 0; j < N; j++) {
                float sum = 0.0f;
                for (int k = 0; k < K; k++) {
                    sum += A[k * M + i] * B[j * K + k];
                }
                C[i * N + j] = beta * C[i * N + j] + alpha * sum;
            }
        }
    } else {
        // C = A * B
        for (int i = 0; i < M; i++) {
            for (int k = 0; k < K; k++) {
                float a = A[i * K + k] * alpha;
                if (a == 0.0f) continue;
                
                const float* B_ptr = B + k * N;
                float* C_ptr = C + i * N;
                
                int j = 0;
                for (; j <= N - BLOCK_SIZE; j += BLOCK_SIZE) {
                    C_ptr[j] += a * B_ptr[j];
                    C_ptr[j + 1] += a * B_ptr[j + 1];
                    C_ptr[j + 2] += a * B_ptr[j + 2];
                    C_ptr[j + 3] += a * B_ptr[j + 3];
                }
                for (; j < N; j++) {
                    C_ptr[j] += a * B_ptr[j];
                }
            }
        }
    }
}