// 示例代码：如何使用ImageLoader和ConvLayer配合
#include "Dashun.h"

int main() {
    // 1. 创建图像加载器（加载RGB图像，调整为224x224，归一化到[0,1]）
    ImageLoader image_loader(3, 224, 224, true, false);
    
    // 2. 加载单张图片
    std::string image_path = "test.jpg";
    auto image_data = image_loader.load_image(image_path, true);
    
    if (image_data.empty()) {
        std::cerr << "Failed to load image!" << std::endl;
        return 1;
    }
    
    // 3. 创建卷积层
    ConvLayer conv1(3, 16, 3, 1, 1);  // 输入通道3，输出通道16，3x3卷积核
    
    // 4. 设置卷积层输入尺寸
    conv1.set_input_shape(224, 224);
    
    // 5. 前向传播（批处理大小为1）
    auto output = conv1.forward(image_data, 1, true);
    
    std::cout << "Convolution output size: " << output.size() << std::endl;
    
    // 6. 批量处理示例
    std::vector<std::string> image_paths = {"img1.jpg", "img2.jpg", "img3.jpg"};
    auto batch_data = image_loader.load_batch(image_paths, true);
    
    int batch_size = image_loader.get_batch_size(batch_data);
    std::cout << "Batch size: " << batch_size << std::endl;
    
    if (batch_size > 0) {
        auto batch_output = conv1.forward(batch_data, batch_size, true);
        std::cout << "Batch output size: " << batch_output.size() << std::endl;
    }
    
    return 0;
}