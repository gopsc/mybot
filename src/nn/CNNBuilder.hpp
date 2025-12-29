#pragma once
#include <iostream>
#include <vector>
#include <functional>
#include "../Dashun.h"

// 卷积神经网络构建辅助类（整合卷积、池化、展平层）
class CNNBuilder {
private:
    std::vector<std::function<std::vector<float>(const std::vector<float>&, int, bool)>> forward_layers;
    std::vector<std::function<std::vector<float>(const std::vector<float>&, int)>> backward_layers;
    std::vector<std::tuple<std::string, int, int, int>> layer_shapes;
    
public:
    // 添加卷积层
    void add_conv_layer(ConvLayer& conv, int in_channels, int height, int width) {
        conv.set_input_shape(height, width);
        auto [out_height, out_width] = conv.get_output_shape();
        
        forward_layers.push_back([&conv](const std::vector<float>& input, int batch, bool train) {
            return conv.forward(input, batch, train);
        });
        
        backward_layers.push_back([&conv](const std::vector<float>& grad, int batch) {
            return conv.backward(grad, batch);
        });
        
        layer_shapes.push_back({"Conv", in_channels, out_height, out_width});
    }
    
    // 添加池化层
    void add_pool_layer(PoolingLayer& pool, int in_channels, int height, int width) {
        pool.set_input_shape(in_channels, height, width);
        auto [out_channels, out_height, out_width] = pool.get_output_shape();
        
        forward_layers.push_back([&pool](const std::vector<float>& input, int batch, bool train) {
            return pool.forward(input, batch, train);
        });
        
        backward_layers.push_back([&pool](const std::vector<float>& grad, int batch) {
            return pool.backward(grad, batch);
        });
        
        layer_shapes.push_back({"Pool", out_channels, out_height, out_width});
    }
    
    // 添加展平层
    void add_flatten_layer(FlattenLayer& flatten, int in_channels, int height, int width) {
        flatten.set_input_shape(in_channels, height, width);
        int out_size = flatten.get_output_size();
        
        forward_layers.push_back([&flatten](const std::vector<float>& input, int batch, bool train) {
            return flatten.forward(input, batch, train);
        });
        
        backward_layers.push_back([&flatten](const std::vector<float>& grad, int batch) {
            return flatten.backward(grad, batch);
        });
        
        layer_shapes.push_back({"Flatten", out_size, 1, 1});
    }
    
    // 前向传播（整个网络）
    std::vector<float> forward(const std::vector<float>& input, int batch_size = 1, bool training = true) {
        std::vector<float> current = input;
        
        for (size_t i = 0; i < forward_layers.size(); i++) {
            current = forward_layers[i](current, batch_size, training);
            
            if (current.empty()) {
                std::cerr << "Error in layer " << i << " (" 
                          << std::get<0>(layer_shapes[i]) << ")" << std::endl;
                return std::vector<float>();
            }
        }
        
        return current;
    }
    
    // 反向传播（整个网络）
    std::vector<float> backward(const std::vector<float>& grad_output, int batch_size = 1) {
        std::vector<float> current_grad = grad_output;
        
        for (int i = backward_layers.size() - 1; i >= 0; i--) {
            current_grad = backward_layers[i](current_grad, batch_size);
            
            if (current_grad.empty()) {
                std::cerr << "Error in backward pass of layer " << i << " (" 
                          << std::get<0>(layer_shapes[i]) << ")" << std::endl;
                return std::vector<float>();
            }
        }
        
        return current_grad;
    }
    
    // 打印网络结构
    void print_architecture() const {
        std::cout << "CNN Architecture:" << std::endl;
        std::cout << "=================" << std::endl;
        
        for (size_t i = 0; i < layer_shapes.size(); i++) {
            auto [layer_type, channels, height, width] = layer_shapes[i];
            
            if (layer_type == "Flatten") {
                std::cout << "Layer " << i << ": " << layer_type 
                          << " -> Output size: " << channels << std::endl;
            } else {
                std::cout << "Layer " << i << ": " << layer_type 
                          << " -> Output shape: " << channels 
                          << "x" << height << "x" << width << std::endl;
            }
        }
    }
};

/*

// 构建简单CNN
ConvLayer conv1(3, 16, 3, 1, 1);
PoolingLayer pool1(2, 2, 2);
ConvLayer conv2(16, 32, 3, 1, 1);
PoolingLayer pool2(2, 2, 2);
FlattenLayer flatten;

// 使用CNN构建器
CNNBuilder cnn;
cnn.add_conv_layer(conv1, 3, 32, 32);
cnn.add_pool_layer(pool1, 16, 32, 32);
cnn.add_conv_layer(conv2, 16, 16, 16);
cnn.add_pool_layer(pool2, 32, 16, 16);
cnn.add_flatten_layer(flatten, 32, 8, 8);

// 执行前向传播
auto output = cnn.forward(input_data, batch_size, true);

*/


