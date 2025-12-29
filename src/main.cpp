#include "Dashun.h"
#include "Dashun_linux.hpp"
#include "test_nn_20251207_0.hpp"
#include "test_nn_20251219_0.hpp"
#include <thread>
#include <chrono>


    
///////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////
/*
* 适用于机器人的DRL（深度强化学习）
*
* 蜘蛛机器人拥有10个舵机（4只胳膊、4只腿、2个摄像云台），它还有2个陀螺仪参数。
*  将舵机目前的位置+陀螺仪参数传递给神经网络，输出10个舵机的概率值
*  将概率值加上一个0~1之间的随机因子，获取最终输出
*
* 每个舵机180度，即 10 * 180 = 1800 个参数
*/
int main() {

    /* 初始化相机 */    
    Camera_init(640, 480);
    Camera_check();
    Camera_setVideoFormat();
    Camera_reqBuf();
    Camera_setup();
    Camera_run();


    /* 创建归一化器 */
    ImageLoader image_loader(3, 64, 64, true, false);

    // 创建网络组件
    ConvLayer conv1(3, 8, 3, 1, 1);       // 输入3通道，输出16通道，3x3卷积，padding=1
    PoolingLayer pool1(2, 2, 2, 0, true);  // 2x2最大池化，步长2
    ConvLayer conv2(8, 16, 3, 1, 1);       // 输入3通道，输出16通道，3x3卷积，padding=1
    PoolingLayer pool2(2, 2, 2, 0, true);  // 2x2最大池化，步长2
    ConvLayer conv3(16, 32, 3, 1, 1);      // 输入16通道，输出32通道
    PoolingLayer pool3(2, 2, 2, 0, true);  // 2x2最大池化，步长2
    ConvLayer conv4(32, 64, 3, 1, 1);      // 输入16通道，输出32通道
    PoolingLayer pool4(2, 2, 2, 0, true);  // 2x2最大池化，步长2
    ConvLayer conv5(64, 128, 3, 1, 1);      // 输入16通道，输出32通道
    PoolingLayer pool5(2, 2, 2, 0, true);  // 2x2最大池化，步长2
    ConvLayer conv6(128, 256, 3, 1, 1);      // 输入16通道，输出32通道
    PoolingLayer pool6(2, 2, 2, 0, true);  // 2x2最大池化，步长2
    FlattenLayer flatten;                   // 展平层

    // 使用CNN构建器
    CNNBuilder cnn;
    
    // 定义输入尺寸
    int input_channels = 3;
    int input_height = 64;
    int input_width = 64;
    int batch_size = 1;
    
    // 构建网络
    cnn.add_conv_layer(conv1, input_channels, input_height, input_width);
    cnn.add_pool_layer(pool1, 8, input_height, input_width);  // 卷积后尺寸不变（因padding=1）
    cnn.add_conv_layer(conv2, 8, input_height/2, input_width/2);  // 池化后尺寸减半
    cnn.add_pool_layer(pool2, 16, input_height/2, input_width/2);
    cnn.add_conv_layer(conv3, 16, input_height/4, input_width/4);  // 池化后尺寸减半
    cnn.add_pool_layer(pool3, 32, input_height/4, input_width/4);
    cnn.add_conv_layer(conv4, 32, input_height/8, input_width/8);  // 池化后尺寸减半
    cnn.add_pool_layer(pool4, 64, input_height/8, input_width/8);
    cnn.add_conv_layer(conv5, 64, input_height/16, input_width/16);  // 池化后尺寸减半
    cnn.add_pool_layer(pool5, 128, input_height/16, input_width/16);
    cnn.add_conv_layer(conv6, 128, input_height/32, input_width/32);  // 池化后尺寸减半
    cnn.add_pool_layer(pool6, 256, input_height/32, input_width/32);
    cnn.add_flatten_layer(flatten, 256, input_height/64, input_width/64);
    
    // 打印网络结构
    cnn.print_architecture();

    qing::NNBuilder nn;
    using nnl = NeuralNetwork;
    auto layer1 = nnl::Create_in_Factory(256, 512, 0.01, nnl::ActivationFunc::Sigmoid);
    auto layer2 = nnl::Create_in_Factory(512, 256, 0.01, nnl::ActivationFunc::Sigmoid);
    auto layer3  = nnl::Create_in_Factory(256, 100, 0.01, nnl::ActivationFunc::Sigmoid);
    auto layer4 = nnl::Create_in_Factory(100, 10,  0.01, nnl::ActivationFunc::Sigmoid);
    nn.add(layer1);
    nn.add(layer2);
    nn.add(layer3);
    nn.add(layer4);
    nn.print_shape();

    /*
     * NOTE: 这里必须等待摄像头初始化完成
     *
     * FIXME: 在主函数中初始化摄像头
     */
    std::this_thread::sleep_for(std::chrono::seconds(1));
    bool flag = true;
    while (flag) {

        auto img = get_frame_from_camera(flag); 
        auto image_data = image_loader.load_from_cimg(img, true);
        if (image_data.empty()) {
            std::cerr << "Failed to load image!" << std::endl;
            break;
        }

        /* 前向传播 */
        auto output = cnn.forward(image_data, batch_size, true);
        if (!output.empty()) {
            std::cout << "Forward pass successful!" << std::endl;
            std::cout << "Input size: " << image_data.size() << std::endl;
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

        std::vector<float> t(10);
        auto r = nn.forward(output);
        auto y = nn.cal_err(r, t);

        for (auto i: y) {
            std::cout << i << " ";
        }
        std::cout << std::endl;

        y = nn.backward(y);
        y = cnn.backward(y);

        std::this_thread::sleep_for(std::chrono::microseconds(10));
    }

    Camera_stop();  
    return 0;
}
