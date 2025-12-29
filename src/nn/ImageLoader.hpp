#pragma once

#define cimg_use_png  /* -lpng */
#define cimg_use_jpeg  /* -ljpeg */
#define cimg_display 0  // 禁用显示窗口，用于服务器环境
#include "CImg.h"
#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <numeric>
#include <cmath>
#include <memory>
#include <sys/stat.h>  // 用于检查文件是否存在
#include <dirent.h>    // 用于目录遍历

class ImageLoader {
private:
    // 图像参数
    int target_channels;     // 目标通道数（如RGB=3, 灰度=1）
    int target_height;       // 目标高度
    int target_width;        // 目标宽度
    bool normalize_to_01;    // 是否归一化到[0,1]
    bool normalize_mean_std; // 是否使用均值标准差归一化
    float mean_val;          // 均值（归一化用）
    float std_val;           // 标准差（归一化用）
    bool auto_mean_std;      // 是否自动计算均值标准差
    
    // 预计算的均值和标准差（针对每个通道）
    std::vector<float> channel_means;
    std::vector<float> channel_stds;
    
    // 用于调试的verbose标志
    bool verbose;
    
    // 辅助函数：检查文件是否存在（POSIX兼容）
    bool file_exists(const std::string& filename) {
        struct stat buffer;
        return (stat(filename.c_str(), &buffer) == 0);
    }
    
    // 辅助函数：检查是否为普通文件
    bool is_regular_file(const std::string& path) {
        struct stat path_stat;
        if (stat(path.c_str(), &path_stat) != 0) {
            return false;
        }
        return S_ISREG(path_stat.st_mode);
    }
    
    // 辅助函数：获取文件扩展名
    std::string get_file_extension(const std::string& filename) {
        size_t dot_pos = filename.find_last_of(".");
        if (dot_pos == std::string::npos) {
            return "";
        }
        return filename.substr(dot_pos);
    }
    
    // 辅助函数：转换为小写
    std::string to_lower(const std::string& str) {
        std::string result = str;
        std::transform(result.begin(), result.end(), result.begin(), ::tolower);
        return result;
    }
    
public:
    // 构造函数
    ImageLoader(int channels = 3, int height = 224, int width = 224, 
                bool norm_01 = true, bool norm_mean_std = false,
                float mean = 0.0f, float std = 1.0f, bool auto_compute = false)
        : target_channels(channels),
          target_height(height),
          target_width(width),
          normalize_to_01(norm_01),
          normalize_mean_std(norm_mean_std),
          mean_val(mean),
          std_val(std),
          auto_mean_std(auto_compute),
          verbose(false) {
        
        // 初始化通道统计量
        channel_means.resize(target_channels, 0.0f);
        channel_stds.resize(target_channels, 1.0f);
    }
    
    // 从文件加载单张图片
    std::vector<float> load_image(const std::string& filepath, bool verbose = false) {
        this->verbose = verbose;
        
        try {
            // 检查文件是否存在
            if (!file_exists(filepath)) {
                throw std::runtime_error("File not found: " + filepath);
            }
            
            // 加载图像
            cimg_library::CImg<unsigned char> img(filepath.c_str());
            
            if (verbose) {
                std::cout << "Loaded image: " << filepath << std::endl;
                std::cout << "Original size: " << img.width() << "x" << img.height() 
                          << "x" << img.spectrum() << std::endl;
            }
            
            // 转换为目标格式并预处理
            return preprocess_image(img, verbose);
            
        } catch (const std::exception& e) {
            std::cerr << "Error loading image " << filepath << ": " << e.what() << std::endl;
            return {};
        }
    }
    
    // 从CImg对象加载图片
    std::vector<float> load_from_cimg(const cimg_library::CImg<unsigned char>& input_img, bool verbose = false) {
        this->verbose = verbose;
        
        try {
            // 创建图像的副本（因为预处理函数可能会修改图像）
            cimg_library::CImg<unsigned char> img = input_img;
            
            if (verbose) {
                std::cout << "Loading from CImg object" << std::endl;
                std::cout << "Original size: " << img.width() << "x" << img.height() 
                          << "x" << img.spectrum() << std::endl;
            }
            
            // 检查图像是否为空
            if (img.is_empty()) {
                throw std::runtime_error("Input CImg object is empty");
            }
            
            // 转换为目标格式并预处理
            return preprocess_image(img, verbose);
            
        } catch (const std::exception& e) {
            std::cerr << "Error loading image from CImg object: " << e.what() << std::endl;
            return {};
        }
    }
    
    // 从CImg对象加载图片（移动语义版本）
    std::vector<float> load_from_cimg(cimg_library::CImg<unsigned char>&& input_img, bool verbose = false) {
        this->verbose = verbose;
        
        try {
            // 直接使用移动过来的图像对象
            cimg_library::CImg<unsigned char> img = std::move(input_img);
            
            if (verbose) {
                std::cout << "Loading from CImg object (move semantics)" << std::endl;
                std::cout << "Original size: " << img.width() << "x" << img.height() 
                          << "x" << img.spectrum() << std::endl;
            }
            
            // 检查图像是否为空
            if (img.is_empty()) {
                throw std::runtime_error("Input CImg object is empty");
            }
            
            // 转换为目标格式并预处理
            return preprocess_image(img, verbose);
            
        } catch (const std::exception& e) {
            std::cerr << "Error loading image from CImg object: " << e.what() << std::endl;
            return {};
        }
    }
    
    // 批量加载图片
    std::vector<float> load_batch(const std::vector<std::string>& filepaths, bool verbose = false) {
        this->verbose = verbose;
        
        std::vector<float> batch_data;
        int loaded_count = 0;
        
        for (const auto& filepath : filepaths) {
            auto img_data = load_image(filepath, verbose);
            if (!img_data.empty()) {
                if (batch_data.empty()) {
                    batch_data = img_data;
                } else {
                    // 追加到batch数据中
                    batch_data.insert(batch_data.end(), img_data.begin(), img_data.end());
                }
                loaded_count++;
            }
        }
        
        if (verbose) {
            std::cout << "Successfully loaded " << loaded_count << " images out of " 
                      << filepaths.size() << std::endl;
        }
        
        return batch_data;
    }
    
    
    // 从文件夹加载所有图片
    std::vector<float> load_from_directory(const std::string& dir_path, 
                                           const std::vector<std::string>& extensions = {".jpg", ".jpeg", ".png", ".bmp"},
                                           bool verbose = false) {
        this->verbose = verbose;
        
        std::vector<std::string> image_files;
        
        try {
            // 打开目录
            DIR* dir = opendir(dir_path.c_str());
            if (!dir) {
                throw std::runtime_error("Cannot open directory: " + dir_path);
            }
            
            // 读取目录项
            struct dirent* entry;
            while ((entry = readdir(dir)) != nullptr) {
                std::string filename = entry->d_name;
                
                // 跳过"."和".."
                if (filename == "." || filename == "..") {
                    continue;
                }
                
                // 构建完整路径
                std::string full_path = dir_path;
                if (dir_path.back() != '/') {
                    full_path += "/";
                }
                full_path += filename;
                
                // 检查是否为普通文件
                if (is_regular_file(full_path)) {
                    // 检查文件扩展名
                    std::string ext = get_file_extension(filename);
                    std::string ext_lower = to_lower(ext);
                    
                    // 检查是否在允许的扩展名列表中
                    bool valid_extension = false;
                    for (const auto& allowed_ext : extensions) {
                        if (ext_lower == to_lower(allowed_ext)) {
                            valid_extension = true;
                            break;
                        }
                    }
                    
                    if (valid_extension) {
                        image_files.push_back(full_path);
                    }
                }
            }
            
            closedir(dir);
            
            if (verbose) {
                std::cout << "Found " << image_files.size() << " images in directory: " 
                          << dir_path << std::endl;
            }
            
            return load_batch(image_files, verbose);
            
        } catch (const std::exception& e) {
            std::cerr << "Error reading directory " << dir_path << ": " << e.what() << std::endl;
            return {};
        }
    }
    
    // 计算数据集统计量（用于归一化）
    void compute_dataset_statistics(const std::vector<std::string>& filepaths, 
                                    int max_images = 1000) {
        std::cout << "Computing dataset statistics..." << std::endl;
        
        int num_images = std::min(static_cast<int>(filepaths.size()), max_images);
        std::vector<std::vector<float>> channel_sums(target_channels, std::vector<float>());
        
        // 采样计算
        for (int i = 0; i < num_images; i++) {
            auto img_data = load_image(filepaths[i], false);
            if (!img_data.empty()) {
                // 计算每个通道的像素值
                int pixels_per_channel = target_height * target_width;
                for (int c = 0; c < target_channels; c++) {
                    const float* channel_start = img_data.data() + c * pixels_per_channel;
                    channel_sums[c].insert(channel_sums[c].end(), 
                                           channel_start, 
                                           channel_start + pixels_per_channel);
                }
            }
            
            if (i % 100 == 0) {
                std::cout << "Processed " << i << " images..." << std::endl;
            }
        }
        
        // 计算均值和标准差
        for (int c = 0; c < target_channels; c++) {
            if (!channel_sums[c].empty()) {
                // 计算均值
                float sum = std::accumulate(channel_sums[c].begin(), channel_sums[c].end(), 0.0f);
                channel_means[c] = sum / channel_sums[c].size();
                
                // 计算标准差
                float variance = 0.0f;
                for (float val : channel_sums[c]) {
                    variance += (val - channel_means[c]) * (val - channel_means[c]);
                }
                variance /= channel_sums[c].size();
                channel_stds[c] = std::sqrt(variance);
                
                std::cout << "Channel " << c << ": mean = " << channel_means[c] 
                          << ", std = " << channel_stds[c] << std::endl;
            }
        }
        
        std::cout << "Statistics computation completed." << std::endl;
    }
    
    // 获取批次数（根据总像素数计算）
    int get_batch_size(const std::vector<float>& data) const {
        int single_image_size = target_channels * target_height * target_width;
        if (single_image_size == 0) return 0;
        return data.size() / single_image_size;
    }
    
    // 设置归一化参数
    void set_normalization_params(const std::vector<float>& means, 
                                  const std::vector<float>& stds) {
        if (means.size() == target_channels && stds.size() == target_channels) {
            channel_means = means;
            channel_stds = stds;
        } else {
            std::cerr << "Error: Means and stds must have size " << target_channels << std::endl;
        }
    }
    
    // 获取归一化参数
    std::pair<std::vector<float>, std::vector<float>> get_normalization_params() const {
        return {channel_means, channel_stds};
    }
    
    // 显示图像信息（用于调试）
    void display_image_info(const std::vector<float>& image_data, int channels_to_show = 3) const {
        int single_image_size = target_channels * target_height * target_width;
        
        std::cout << "Image data info:" << std::endl;
        std::cout << "  Dimensions: " << target_channels << " x " << target_height 
                  << " x " << target_width << std::endl;
        std::cout << "  Total values: " << image_data.size() << std::endl;
        
        if (!image_data.empty()) {
            // 计算统计信息
            float min_val = *std::min_element(image_data.begin(), image_data.end());
            float max_val = *std::max_element(image_data.begin(), image_data.end());
            float sum_val = std::accumulate(image_data.begin(), image_data.end(), 0.0f);
            float mean_val = sum_val / image_data.size();
            
            std::cout << "  Min value: " << min_val << std::endl;
            std::cout << "  Max value: " << max_val << std::endl;
            std::cout << "  Mean value: " << mean_val << std::endl;
            
            // 显示每个通道的前几个像素
            int pixels_per_channel = target_height * target_width;
            for (int c = 0; c < std::min(target_channels, channels_to_show); c++) {
                std::cout << "  Channel " << c << " (first 5 pixels): ";
                for (int i = 0; i < std::min(5, pixels_per_channel); i++) {
                    std::cout << image_data[c * pixels_per_channel + i] << " ";
                }
                std::cout << std::endl;
            }
        }
    }
    
    // 获取目标尺寸（公开访问器）
    int get_target_height() const { return target_height; }
    int get_target_width() const { return target_width; }
    int get_target_channels() const { return target_channels; }
    
    // 设置verbose模式
    void set_verbose(bool v) { verbose = v; }
    
private:
    // 图像预处理主函数
    std::vector<float> preprocess_image(cimg_library::CImg<unsigned char>& img, bool verbose = false) {
        // 1. 调整通道数
        adjust_channels(img);
        
        // 2. 调整尺寸
        resize_image(img);
        
        // 3. 转换为浮点数
        std::vector<float> float_data = convert_to_float(img);
        
        // 4. 重新排列维度为 [channels, height, width]
        std::vector<float> reordered_data = reorder_dimensions(float_data, img);
        
        // 5. 归一化
        if (normalize_to_01) {
            normalize_0_1(reordered_data);
        }
        
        if (normalize_mean_std) {
            normalize_mean_std_channels(reordered_data);
        }
        
        if (verbose) {
            std::cout << "Processed image size: " << target_channels << "x" 
                      << target_height << "x" << target_width << std::endl;
        }
        
        return reordered_data;
    }
    
    // 调整通道数
    void adjust_channels(cimg_library::CImg<unsigned char>& img) {
        int current_channels = img.spectrum();
        
        if (current_channels == 1 && target_channels == 3) {
            // 灰度转RGB：复制单通道到三个通道
            cimg_library::CImg<unsigned char> rgb_img(img.width(), img.height(), img.depth(), 3);
            cimg_forXYZ(img, x, y, z) {
                rgb_img(x, y, z, 0) = img(x, y, z, 0);  // R
                rgb_img(x, y, z, 1) = img(x, y, z, 0);  // G
                rgb_img(x, y, z, 2) = img(x, y, z, 0);  // B
            }
            img = rgb_img;
            
        } else if (current_channels == 3 && target_channels == 1) {
            // RGB转灰度：使用标准公式
            img = img.get_channel(0) * 0.299f + 
                  img.get_channel(1) * 0.587f + 
                  img.get_channel(2) * 0.114f;
                  
        } else if (current_channels == 4 && target_channels == 3) {
            // RGBA转RGB：移除alpha通道
            img.channels(0, 2);
            
        } else if (current_channels > target_channels) {
            // 保留前target_channels个通道
            img.channels(0, target_channels - 1);
            
        } else if (current_channels < target_channels) {
            // 重复最后一个通道来补足
            int channels_to_add = target_channels - current_channels;
            for (int i = 0; i < channels_to_add; i++) {
                img.append(img.get_channel(current_channels - 1), 'c');
            }
        }
    }
    
    // 调整图像尺寸
    void resize_image(cimg_library::CImg<unsigned char>& img) {
        if (img.width() != target_width || img.height() != target_height) {
            if (verbose) {
                std::cout << "Resizing from " << img.width() << "x" << img.height() 
                          << " to " << target_width << "x" << target_height << std::endl;
            }
            
            // 使用CImg的resize函数
            img.resize(target_width, target_height, -100, -100, 3); // 3 = 三次样条插值
        }
    }
    
    // 转换为浮点数
    std::vector<float> convert_to_float(const cimg_library::CImg<unsigned char>& img) {
        std::vector<float> float_data;
        float_data.reserve(img.width() * img.height() * img.spectrum());
        
        cimg_forC(img, c) {
            cimg_forXY(img, x, y) {
                float_data.push_back(static_cast<float>(img(x, y, 0, c)));
            }
        }
        
        return float_data;
    }
    
    // 重新排列维度为 [channels, height, width]
    std::vector<float> reorder_dimensions(const std::vector<float>& data, 
                                          const cimg_library::CImg<unsigned char>& img) {
        int channels = img.spectrum();
        int height = img.height();
        int width = img.width();
        
        std::vector<float> reordered(channels * height * width);
        
        // CImg默认布局: [width, height, depth, spectrum]
        // 我们需要: [channels, height, width]
        for (int c = 0; c < channels; c++) {
            for (int h = 0; h < height; h++) {
                for (int w = 0; w < width; w++) {
                    // CImg索引: (x, y, z, c) = (w, h, 0, c)
                    int src_idx = c * (height * width) + h * width + w;
                    int dst_idx = c * (height * width) + h * width + w;
                    reordered[dst_idx] = data[src_idx];
                }
            }
        }
        
        return reordered;
    }
    
    // 归一化到[0,1]
    void normalize_0_1(std::vector<float>& data) {
        for (auto& val : data) {
            val /= 255.0f;
        }
    }
    
    // 使用均值标准差归一化（逐通道）
    void normalize_mean_std_channels(std::vector<float>& data) {
        int pixels_per_channel = target_height * target_width;
        
        for (int c = 0; c < target_channels; c++) {
            float mean = auto_mean_std ? channel_means[c] : mean_val;
            float std = auto_mean_std ? channel_stds[c] : std_val;
            
            for (int i = 0; i < pixels_per_channel; i++) {
                int idx = c * pixels_per_channel + i;
                data[idx] = (data[idx] - mean) / std;
            }
        }
    }
};