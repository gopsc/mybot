
#include <iostream>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>
#include <vector>
#include <algorithm>
#include <mutex>

#include "../Dashun_linux.hpp"

//#define cimg_display 0 /* 不显示图像，只保存 */
//#include "CImg.h"
#include <jpeglib.h>
using namespace cimg_library;
static constexpr char* filename = "/dev/video0";
static int width = 0;
static int height = 0;

/* 为了在获取单帧中使用 */
struct v4l2_buffer buf;
enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;


#include <thread>
#include <atomic>
#include <mutex>
#include <sys/select.h>   // 用于 select, fd_set, timeval
#include <unistd.h>       // 用于 usleep
#include <cstdio>         // 用于 perror

/* 静态全局线程对象及相关同步原语 */
static std::thread camera_thread;
static std::atomic<bool> camera_running{false};
static std::mutex camera_mutex;


#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

static constexpr int TCP_PORT = 9202;
static int tcp_listen_fd = -1;

/* 客户端管理相关全局变量 */
static std::vector<int> client_sockets;      // 客户端套接字列表
static std::mutex client_mutex;              // 客户端列表的互斥锁
static constexpr size_t MAX_CLIENTS = 10;   // 最大客户端数量

/* device file */
static int fd = -1;





/*  */
void Camera_init(int w, int h) {

    if (!(fd < 0)) {
        throw std::runtime_error("Camera already opened.");
    }

    fd = open(filename, O_RDWR);
    if (fd < 0) {
        throw std::runtime_error("Failed to open device: " + std::string(strerror(errno)));
    }

    width = w;
    height = h;

}

/* */
void Camera_close() {
    close(fd);
    fd = -1;
}

/* check if this device support video capture (V4L2_CAP_VIDEO_CAPTURE) */
void Camera_check() {
    struct v4l2_capability cap;
    if (ioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        throw std::runtime_error("VIDIOC_QUERYCAP failed: " + std::string(strerror(errno)));
    }
    if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) {
        throw std::runtime_error("Device does not support video capture");
    }
}

/* Set Video Format */
void Camera_setVideoFormat() {
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = width;  /* */
    fmt.fmt.pix.height = height; /* */
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;  /* usually format: YUYV, MJPEG */ 
    fmt.fmt.pix.field = V4L2_FIELD_NONE;

    if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        throw std::runtime_error("VIDIOC_S_FMT failed: " + std::string(strerror(errno)));
    }   

}

/* Request Camera Buffer */
void Camera_reqBuf() {
    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = 4;                           /* the number of buffer */
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;           /* the mode of memory mapping */

    if (ioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
        throw std::runtime_error("VIDIOC_REQBUFS failed: " + std::string(strerror(errno)));
    }

}

/*------------------------------------------------------------------------------*/
/* TCP服务器启动 */


void Camera_TCPServer_init() {
    tcp_listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (tcp_listen_fd < 0) {
        perror("TCP socket create failed");
        return;
    }

    int opt = 1;
    if (setsockopt(tcp_listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        perror("setsockopt failed");
        close(tcp_listen_fd);
        tcp_listen_fd = -1;
        return;
    }

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(TCP_PORT);

    if (bind(tcp_listen_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("TCP bind failed");
        close(tcp_listen_fd);
        tcp_listen_fd = -1;
        return;
    }

    if (listen(tcp_listen_fd, 5) < 0) {
        perror("TCP listen failed");
        close(tcp_listen_fd);
        tcp_listen_fd = -1;
        return;
    }

    std::cout << "TCP server listening on port " << TCP_PORT << std::endl;
}

static void close_all_clients() {
    std::lock_guard<std::mutex> client_lock(client_mutex);
    for (int client_fd : client_sockets) {
        close(client_fd);
    }
    client_sockets.clear();
}

/* TCP服务器停止 */
void Camera_TCPServer_stop() {
    close_all_clients();
    /* 关闭监听套接字 */
    if (tcp_listen_fd >= 0) {
        close(tcp_listen_fd);
        tcp_listen_fd = -1;
    }   
}
/*------------------------------------------------------------------------------*/


/* 全局变量用于存储映射的内存 */
struct {
    void* start;
    size_t length;
} buffer_info;

/* 

mapping buffer and data collection loop

FIXME: 将该函数改为图传主函数，并且加锁以在本进程中也能获取

*/
void Camera_setup() {
    /* mapping buffer (It is needed to handle every buffer in loop) */
    memset(&buf, 0, sizeof(buf));
    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = V4L2_MEMORY_MMAP;
    buf.index = 0;  /* Index of the buffer */

    /* 查询缓冲区信息 */
    if (ioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
        throw std::runtime_error("VIDIOC_QUERYBUF failed: " + std::string(strerror(errno)));
    }

    /* 将缓冲区加入队列 */
    if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) {
        throw std::runtime_error("VIDIOC_QBUF failed: " + std::string(strerror(errno)));
    }

    /* 开始采集 */
    if (ioctl(fd, VIDIOC_STREAMON, &buf.type) < 0) { /* start collection */
        throw std::runtime_error("VIDIOC_STREAMON failed: " + std::string(strerror(errno)));
    }

}

void Camera_unsetup() {
    /* 停止采集流 */
    ioctl(fd, VIDIOC_STREAMOFF, &type);
}


std::vector<unsigned char> compress_to_jpeg(const CImg<unsigned char>& image, int quality = 75) {
    std::cout << "compress_to_jpeg called with CImg: width=" << image.width() 
              << ", height=" << image.height() 
              << ", spectrum=" << image.spectrum()
              << ", quality=" << quality << std::endl;
    
    // 检查图像的有效性
    if (image.width() == 0 || image.height() == 0) {
        std::cerr << "Error: Invalid image dimensions!" << std::endl;
        return std::vector<unsigned char>();
    }
    
    // 检查频谱（通道数）
    int channels = image.spectrum();
    std::cout << "Image has " << channels << " channel(s)" << std::endl;
    
    // CImg数据布局：默认是平面格式 [plane1, plane2, plane3]
    // 但我们需要交错的RGB格式用于JPEG压缩
    
    unsigned char* buffer = nullptr;
    unsigned long buffer_size = 0;
    
    struct jpeg_compress_struct cinfo;
    struct jpeg_error_mgr jerr;
    
    cinfo.err = jpeg_std_error(&jerr);
    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, &buffer, &buffer_size);
    
    int width = image.width();
    int height = image.height();
    
    cinfo.image_width = width;
    cinfo.image_height = height;
    cinfo.input_components = 3;  // 总是使用3通道RGB
    cinfo.in_color_space = JCS_RGB;
    
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, quality, TRUE);
    
    // 开始压缩
    jpeg_start_compress(&cinfo, TRUE);
    
    JSAMPROW row_pointer[1];
    std::vector<unsigned char> row_buffer(width * 3);  // 用于存储一行交错的RGB数据
    
    // 处理每一行
    for (int y = 0; y < height; y++) {
        // 将CImg的平面格式转换为交错的RGB格式
        if (channels == 3) {
            // RGB图像：CImg存储为平面格式 [R平面, G平面, B平面]
            for (int x = 0; x < width; x++) {
                row_buffer[x * 3] = image(x, y, 0, 0);     // R
                row_buffer[x * 3 + 1] = image(x, y, 0, 1); // G
                row_buffer[x * 3 + 2] = image(x, y, 0, 2); // B
            }
        }
        else if (channels == 1) {
            // 灰度图像：重复到三个通道
            for (int x = 0; x < width; x++) {
                unsigned char gray = image(x, y, 0, 0);
                row_buffer[x * 3] = gray;     // R
                row_buffer[x * 3 + 1] = gray; // G
                row_buffer[x * 3 + 2] = gray; // B
            }
        }
        else if (channels == 4) {
            // RGBA图像：忽略Alpha通道
            for (int x = 0; x < width; x++) {
                row_buffer[x * 3] = image(x, y, 0, 0);     // R
                row_buffer[x * 3 + 1] = image(x, y, 0, 1); // G
                row_buffer[x * 3 + 2] = image(x, y, 0, 2); // B
                // 忽略Alpha通道：image(x, y, 0, 3)
            }
        }
        else {
            // 其他通道数：使用前3个通道
            std::cout << "Warning: Using first 3 channels of " << channels << "-channel image" << std::endl;
            for (int x = 0; x < width; x++) {
                for (int c = 0; c < 3 && c < channels; c++) {
                    row_buffer[x * 3 + c] = image(x, y, 0, c);
                }
                // 如果通道数不足3，用0填充
                for (int c = channels; c < 3; c++) {
                    row_buffer[x * 3 + c] = 0;
                }
            }
        }
        
        row_pointer[0] = row_buffer.data();
        jpeg_write_scanlines(&cinfo, row_pointer, 1);
        
        // 显示进度
        if (y % 100 == 0) {
            std::cout << "Processing row " << y << "/" << height << std::endl;
        }
    }
    
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    
    std::cout << "JPEG compression finished, buffer_size=" << buffer_size << std::endl;
    
    // 将JPEG数据复制到vector
    std::vector<unsigned char> jpeg_data(buffer, buffer + buffer_size);
    
    // 释放libjpeg分配的内存
    free(buffer);
    
    // 验证JPEG数据
    if (jpeg_data.size() >= 2) {
        bool has_soi = (jpeg_data[0] == 0xFF && jpeg_data[1] == 0xD8);
        bool has_eoi = (jpeg_data.size() >= 2 && 
                       jpeg_data[jpeg_data.size()-2] == 0xFF && 
                       jpeg_data[jpeg_data.size()-1] == 0xD9);
        
        std::cout << "Generated JPEG: size=" << jpeg_data.size() 
                  << " bytes, has SOI: " << has_soi 
                  << ", has EOI: " << has_eoi << std::endl;
        
        if (!has_soi || !has_eoi) {
            std::cerr << "Warning: Generated JPEG may be corrupted!" << std::endl;
        }
    }
    
    return jpeg_data;
}




static int Camera_main() {


    std::cout << "Starting Camera_main function..." << std::endl;

    /* 初始化TCP服务器 */
    std::cout << "Initializing TCP server..." << std::endl;
    Camera_TCPServer_init();

    std::cout << "TCP server initialized successfully" << std::endl;

    /* the loop of data capture */
    bool flag = true;
    std::cout << "Entering main loop..." << std::endl;

    int loop_count = 0;
    while (flag) {
        loop_count++;
        if (loop_count % 100 == 0) {
            std::cout << "Main loop iteration: " << loop_count << std::endl;
            std::cout << "Camera running: " << camera_running.load() << std::endl;
            std::cout << "Number of clients: " << client_sockets.size() << std::endl;
        }

        
        /* 使用非阻塞 select 检查是否有数据可读 */
        fd_set fds;
        FD_ZERO(&fds);
        
        // 添加相机文件描述符
        FD_SET(fd, &fds);
        
        // 添加TCP监听套接字（如果已初始化）
        int max_fd = fd;
        if (tcp_listen_fd >= 0) {
            FD_SET(tcp_listen_fd, &fds);
            if (tcp_listen_fd > max_fd) {
                max_fd = tcp_listen_fd;
            }
        }
        
        // 添加所有客户端套接字
        std::vector<int> current_clients;
        {
            std::lock_guard<std::mutex> client_lock(client_mutex);
            current_clients = client_sockets;
        }
        for (int client_fd : current_clients) {
            FD_SET(client_fd, &fds);
            if (client_fd > max_fd) {
                max_fd = client_fd;
            }
        }
        
        struct timeval tv{};
        tv.tv_sec  = 1;
        tv.tv_usec = 0;          // 非阻塞：立即返回

        int ret = select(max_fd + 1, &fds, NULL, NULL, &tv);
        if (ret < 0) {
            perror("select failed");
            break;
        }
        if (ret == 0) {
            usleep(10000);
            continue;
        }
    
        // 处理新的TCP连接请求
        if (tcp_listen_fd >= 0 && FD_ISSET(tcp_listen_fd, &fds)) {
            struct sockaddr_in client_addr{};
            socklen_t client_addr_len = sizeof(client_addr);
            int new_client_fd = accept(tcp_listen_fd, (struct sockaddr*)&client_addr, &client_addr_len);
            if (new_client_fd < 0) {
                throw std::runtime_error("accept failed: " + std::string(strerror(errno)));
            } else {
                std::lock_guard<std::mutex> client_lock(client_mutex);
                if (client_sockets.size() < MAX_CLIENTS) {
                    client_sockets.push_back(new_client_fd);
                    char client_ip[INET_ADDRSTRLEN];
                    inet_ntop(AF_INET, &client_addr.sin_addr, client_ip, INET_ADDRSTRLEN);
                    std::cout << "New client connected: " << client_ip << ":" << ntohs(client_addr.sin_port) << std::endl;
                } else {
                    std::cout << "Too many clients, rejecting connection" << std::endl;
                    close(new_client_fd);
                }
            }
        }
        
        // 处理客户端数据和断开连接
        std::vector<int> clients_to_remove;
        {
            std::lock_guard<std::mutex> client_lock(client_mutex);
            for (int client_fd : client_sockets) {
                if (FD_ISSET(client_fd, &fds)) {
                    // 检查客户端是否断开
                    char buffer[1];
                    int recv_ret = recv(client_fd, buffer, 1, MSG_PEEK | MSG_DONTWAIT);
                    if (recv_ret <= 0) {
                        // 客户端断开连接
                        close(client_fd);
                        clients_to_remove.push_back(client_fd);
                        std::cout << "Client disconnected: " << client_fd << std::endl;
                    }
                }
            }
            
            // 移除断开的客户端
            for (int client_fd : clients_to_remove) {
                client_sockets.erase(
                    std::remove(client_sockets.begin(), client_sockets.end(), client_fd),
                    client_sockets.end()
                );
            }
        }

        /* 如果没有客户端连接，跳过数据处理 */
        if (client_sockets.empty()) {
            usleep(10000);
            continue;
        }

        try {
            /* 从相机获取一帧图像，并且更新flag */
            auto image = get_frame_from_camera(flag); 
            
            /* 压缩为JPEG格式 */
<<<<<<< HEAD
            auto compressed_jpeg_buffer = compress_to_jpeg(
                image.data(), image.width(), image.height(), 75
            );

            /* 发送数据给所有客户端 */
            for (int client_fd : client_sockets) {
                if (send(client_fd, compressed_jpeg_buffer.data(), compressed_jpeg_buffer.size(), 0) < 0) {   
                    perror("send failed");
                    close(client_fd);
                    clients_to_remove.push_back(client_fd);
                }
            }
=======
            auto compressed_jpeg_buffer = compress_to_jpeg(image, 20);

	    /* 调试：检查JPEG数据是否包含SOI标记 */
            bool has_soi = false;
            if (compressed_jpeg_buffer.size() >= 2) {
                has_soi = (compressed_jpeg_buffer[0] == 0xFF && compressed_jpeg_buffer[1] == 0xD8);
            }
            std::cout << "Generated JPEG: size=" << compressed_jpeg_buffer.size() << " bytes, has SOI: " << has_soi << std::endl;


            /* 发送数据给所有客户端 */
            for (int client_fd : client_sockets) {
                if (send(client_fd, compressed_jpeg_buffer.data(), compressed_jpeg_buffer.size(), 0) < 0) {   
                    perror("send failed");
                    close(client_fd);
                    clients_to_remove.push_back(client_fd);
                }
            }
>>>>>>> 286ea51 (TEST(qing))
        } catch (const std::exception& e) {
            perror("Error processing frame");
            continue;
        }
    }

    /* 关闭TCP服务器 */
    Camera_TCPServer_stop();
    
    return 0;
}

/*------------------------------------------------------------------------------*/


/* 启动相机线程 */
void Camera_run() {
    std::lock_guard<std::mutex> lock(camera_mutex);
    if (camera_running.load()) return;          // 已在运行
    camera_running.store(true);
    camera_thread = std::thread(Camera_main);   // 创建并启动线程
}

/* 停止相机线程 */
void Camera_stop() {
    std::lock_guard<std::mutex> lock(camera_mutex);
    if (!camera_running.load()) return;         // 已停止
    camera_running.store(false);                // 通知线程退出
    if (camera_thread.joinable())
        camera_thread.join();                   // 等待线程结束
}

/*------------------------------------------------------------------------------*/



/* 
 * Convert YUYV pixel at position (x, y) in frame to RGB
 * YUYV format: [Y0 U0 Y1 V0] [Y2 U2 Y3 V2] ...
 * Each 4 bytes contain 2 pixels (Y0,U0,V0 for pixel0, Y1,U0,V0 for pixel1)
 */
void YUYV_to_RGB(uint8_t* frameData, int width, int height, int x, int y, 
                 uint8_t& r, uint8_t& g, uint8_t& b) {
    // 计算像素在YUYV数据中的索引
    int pixel_index = y * width + x;
    
    // YUYV中每2个像素共享4字节：Y0 U Y1 V
    int byte_offset = (pixel_index / 2) * 4;
    
    // 确定是第一个像素还是第二个像素
    bool is_first_pixel = (pixel_index % 2 == 0);
    
    uint8_t Y, U, V;
    
    if (is_first_pixel) {
        // 第一个像素：Y0, U, V
        Y = frameData[byte_offset];     // Y0
        U = frameData[byte_offset + 1]; // U
        V = frameData[byte_offset + 3]; // V
    } else {
        // 第二个像素：Y1, U, V (与第一个像素共享U和V)
        Y = frameData[byte_offset + 2]; // Y1
        U = frameData[byte_offset + 1]; // U (共享)
        V = frameData[byte_offset + 3]; // V (共享)
    }
    
    // YUV to RGB conversion formula (integer approximation)
    // 注意：YUV值通常范围是Y:16-235, UV:16-240
    // 这里先转换为0-255范围
    int Y_adj = Y - 16;
    int U_adj = U - 128;
    int V_adj = V - 128;
    
    // 计算RGB值
    int R = (298 * Y_adj + 409 * V_adj + 128) >> 8;
    int G = (298 * Y_adj - 100 * U_adj - 208 * V_adj + 128) >> 8;
    int B = (298 * Y_adj + 516 * U_adj + 128) >> 8;
    
    // 限制范围到0-255
    r = (R < 0) ? 0 : ((R > 255) ? 255 : static_cast<uint8_t>(R));
    g = (G < 0) ? 0 : ((G > 255) ? 255 : static_cast<uint8_t>(G));
    b = (B < 0) ? 0 : ((B > 255) ? 255 : static_cast<uint8_t>(B));
}

/*
 * Convert YUYV frame to CImg object and save as image
 *
 * FIXME(20251229): 每次处理一个像素都要调用YUYV_to_RGB函数，重新计算索引和转换，而YUYV格式中每两个相邻像素共享U和V值
 */
bool save_YUYV_as_image(uint8_t* frameData, int width, int height, 
                         const char* filename, int frame_num = 0) {
    try {
        // 创建CImg图像对象 (width, height, depth=1, spectrum=3 for RGB)
        CImg<unsigned char> img(width, height, 1, 3);
        
        // 转换为RGB并填充到CImg
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                uint8_t r, g, b;
                YUYV_to_RGB(frameData, width, height, x, y, r, g, b);
                
                // CImg存储顺序是平面：首先所有R，然后所有G，最后所有B
                // 或者使用(x, y, 0, channel)访问
                img(x, y, 0, 0) = r;  // Red channel
                img(x, y, 0, 1) = g;  // Green channel
                img(x, y, 0, 2) = b;  // Blue channel
            }
        }
        
        // 生成带帧编号的文件名
        char full_filename[256];
        if (frame_num > 0) {
            snprintf(full_filename, sizeof(full_filename), 
                    "%s_frame%03d.bmp", filename, frame_num);
        } else {
            snprintf(full_filename, sizeof(full_filename), "%s.bmp", filename);
        }
        
        // 保存为BMP格式（也支持PNG、JPEG等）
        img.save(full_filename);
        std::cout << "Image saved as: " << full_filename << std::endl;
        
        return true;
    } catch (CImgException& e) {
        std::cerr << "Error saving image: " << e.what() << std::endl;
        return false;
    }
}


/*
 * Convert YUYV frame to CImg object and return it
 */
CImg<unsigned char> YUYV_to_CImg(uint8_t* frameData, int width, int height) {
    // 创建CImg图像对象 (width, height, depth=1, spectrum=3 for RGB)
    CImg<unsigned char> img(width, height, 1, 3);

    // 遍历图像的每一行和每一列
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x += 2) {
            // YUYV格式：每两个像素占用4个字节
            int yuyv_index = (y * width + x) * 2;

            // 提取YUV值
            uint8_t Y0 = frameData[yuyv_index];
            uint8_t U = frameData[yuyv_index + 1];
            uint8_t Y1 = frameData[yuyv_index + 2];
            uint8_t V = frameData[yuyv_index + 3];

            // 转换第一个像素（x, y）
            int R0 = Y0 + (V - 128) * 1.402;
            int G0 = Y0 - (U - 128) * 0.34414 - (V - 128) * 0.71414;
            int B0 = Y0 + (U - 128) * 1.772;

            // 转换第二个像素（x+1, y）
            int R1 = Y1 + (V - 128) * 1.402;
            int G1 = Y1 - (U - 128) * 0.34414 - (V - 128) * 0.71414;
            int B1 = Y1 + (U - 128) * 1.772;

            // 限制范围到0-255
            R0 = std::max(0, std::min(255, R0));
            G0 = std::max(0, std::min(255, G0));
            B0 = std::max(0, std::min(255, B0));

            R1 = std::max(0, std::min(255, R1));
            G1 = std::max(0, std::min(255, G1));
            B1 = std::max(0, std::min(255, B1));

            // 设置第一个像素值
            img(x, y, 0, 0) = static_cast<uint8_t>(R0);
            img(x, y, 0, 1) = static_cast<uint8_t>(G0);
            img(x, y, 0, 2) = static_cast<uint8_t>(B0);

            // 设置第二个像素值（如果在图像范围内）
            if (x + 1 < width) {
                img(x + 1, y, 0, 0) = static_cast<uint8_t>(R1);
                img(x + 1, y, 0, 1) = static_cast<uint8_t>(G1);
                img(x + 1, y, 0, 2) = static_cast<uint8_t>(B1);
            }
        }
    }

    return img;
}

/* 在线程安全的情况下取得一帧图像 */
CImg<unsigned char> get_frame_from_camera(bool& flag) {

    std::lock_guard<std::mutex> lock(camera_mutex);
    if (!camera_running.load()) throw std::runtime_error("Camera not running");
    
    /* Dequeue to get data */
    memset(&buf, 0, sizeof(buf));
    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = V4L2_MEMORY_MMAP;
    
    if (ioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
        perror("dequeue failed");
        throw std::runtime_error("dequeue failed");
    }

    /* 获取当前缓冲区的数据指针 */
    uint8_t *frameData = static_cast<uint8_t*>(mmap(NULL, buf.length, 
                                        PROT_READ | PROT_WRITE, MAP_SHARED, 
                                        fd, buf.m.offset));
    
    if (frameData == MAP_FAILED) {
        ioctl(fd, VIDIOC_QBUF, &buf);
        throw std::runtime_error("mmap failed in get_frame_from_camera");
    }

    /* process frameData */
    std::cout << "Got length: " << buf.length << std::endl;
    auto img = YUYV_to_CImg(frameData, width, height);
    
    /* 解除内存映射 */
    munmap(frameData, buf.length);

    if (ioctl(fd, VIDIOC_QBUF, &buf)<0){  /* join the queue again */
        perror("requeue failed");
        throw std::runtime_error("requeue failed");
    }

    
    flag = camera_running.load(); /* 检查下一次是否需要退出 */
    return img; /* 返回图像 */
}
