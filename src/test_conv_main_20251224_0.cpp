#include "ConvLayer.hpp"
#include <random>
#include <chrono>

// 测试函数
int main() {
    // 设置随机数种子
    unsigned seed = std::chrono::system_clock::now().time_since_epoch().count();
    std::default_random_engine generator(seed);
    std::uniform_real_distribution<float> distribution(0.0f, 1.0f);
    
    // 10. 完整训练流程演示
    std::cout << "完整训练流程演示..." << std::endl;
    
    // 创建一个小型网络进行演示
    ConvLayer conv_net(1, 1, 3, 1, 1);  // 简单的1x1卷积网络
    conv_net.set_input_shape(5, 5);
    
    // 生成训练数据 - 使用随机数
    std::vector<float> train_input(1 * 1 * 5 * 5);
    std::vector<float> train_target(1 * 1 * 5 * 5);
    
    // 随机生成输入数据
    for (size_t i = 0; i < train_input.size(); i++) {
        train_input[i] = distribution(generator);
    }
    
    // 随机生成目标数据（也可以设为输入的某种变换，这里简单设为随机）
    for (size_t i = 0; i < train_target.size(); i++) {
        train_target[i] = distribution(generator);
    }
    
    // 或者：目标设为输入的简单变换（例如：输入 + 噪声）
    // for (size_t i = 0; i < train_target.size(); i++) {
    //     train_target[i] = train_input[i] + 0.1f * distribution(generator);
    // }
    
    for (int epoch = 0; epoch < 10; epoch++) {
        // 前向传播
        auto train_output = conv_net.forward(train_input, 1, true);
        
        // 计算损失（这里使用简单的L2损失）
        std::vector<float> loss_grad(train_output.size());
        float loss = 0.0f;
        
        for (size_t i = 0; i < train_output.size(); i++) {
            float diff = train_output[i] - train_target[i];
            loss += diff * diff;
            loss_grad[i] = 2.0f * diff;  // L2损失的梯度
        }
        
        loss /= train_output.size();
        
        // 反向传播
        conv_net.backward(loss_grad, 1);
        
        // 更新参数
        conv_net.update_parameters(0.01f, 0.9f);
        
        if (epoch % 2 == 0) {
            std::cout << "Epoch " << epoch << ", Loss: " << loss << std::endl;
        }
    }
    
    return 0;
}