#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
压缩相机客户端Python实现
功能：连接服务器接收JPEG压缩视频流，解码并显示
"""

import socket
import cv2
import numpy as np
import sys
import time
from PIL import Image
import io


def main():
    print("Starting Compressed Camera Client...")
    
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <server_ip> <port>")
        return 1
    
    server_ip = sys.argv[1]
    port = int(sys.argv[2])
    
    print(f"Configuration: Server IP={server_ip}, Port={port}")
    
    # 创建TCP套接字
    print("Creating TCP socket...")
    sockfd = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    
    # 设置套接字超时
    sockfd.settimeout(5.0)
    print("TCP socket created successfully")
    
    try:
        # 连接到服务器
        print(f"Connecting to server {server_ip}:{port}...")
        sockfd.connect((server_ip, port))
        print(f"Connected to server: {server_ip}:{port}")
        
        # 关闭超时，改为非阻塞模式
        sockfd.setblocking(True)
        print("Socket set to blocking mode")
        
        # OpenCV窗口
        print("Creating OpenCV window...")
        # 尝试使用不同的窗口参数
        cv2.namedWindow("Compressed Camera Stream", cv2.WINDOW_GUI_NORMAL)
        # 设置固定的窗口大小
        cv2.resizeWindow("Compressed Camera Stream", 640, 480)
        # 确保窗口大小是固定的
        cv2.setWindowProperty("Compressed Camera Stream", cv2.WND_PROP_ASPECT_RATIO, cv2.WINDOW_KEEPRATIO)
        cv2.setWindowProperty("Compressed Camera Stream", cv2.WND_PROP_AUTOSIZE, cv2.WINDOW_AUTOSIZE)
        
        # 显示初始信息
        info_frame = np.zeros((480, 640, 3), dtype=np.uint8)
        cv2.putText(info_frame, "Connecting to server...", (50, 240), 
                    cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
        cv2.imshow("Compressed Camera Stream", info_frame)
        cv2.waitKey(100)
        
        frame_count = 0
        buffer = b''  # 用于累积数据的缓冲区
        total_bytes_received = 0
        jpeg_found_count = 0
        
        # 上次收到数据的时间
        last_receive_time = time.time()
        
        while True:
            try:
                # 接收数据
                data = sockfd.recv(8192)
                if not data:
                    print("Server closed connection")
                    return 0
                
                last_receive_time = time.time()
                total_bytes_received += len(data)
                print(f"Received {len(data)} bytes, total: {total_bytes_received} bytes")
                
                # 将新数据添加到缓冲区
                buffer += data
                
                # 仅保留最近的500KB数据，防止内存溢出
                if len(buffer) > 500 * 1024:
                    print(f"Buffer size exceeded 500KB, trimming to 500KB")
                    buffer = buffer[-500 * 1024:]
                
                # 检查缓冲区中是否有JPEG标记
                has_jpeg = b'\xff\xd8' in buffer
                print(f"Buffer contains JPEG SOI: {has_jpeg}, buffer size: {len(buffer)}")
                
                # JPEG文件格式标记
                JPEG_START = b'\xff\xd8'  # SOI (Start of Image)
                JPEG_END = b'\xff\xd9'    # EOI (End of Image)
                
                # 查找所有完整的JPEG帧
                while True:
                    # 查找JPEG开始标记
                    start_idx = buffer.find(JPEG_START)
                    if start_idx == -1:
                        # 没有找到开始标记
                        print(f"No JPEG SOI found, buffer size: {len(buffer)}")
                        # 清空大部分缓冲区，只保留末尾可能包含部分JPEG头的数据
                        if len(buffer) > 1024:
                            buffer = buffer[-1024:]
                            print(f"Trimmed buffer to {len(buffer)} bytes")
                        break
                    
                    # 查找当前开始标记后的结束标记
                    end_idx = buffer.find(JPEG_END, start_idx + 2)
                    if end_idx == -1:
                        # 没有找到完整的结束标记
                        print(f"Found JPEG SOI but no EOI, buffer size from SOI: {len(buffer) - start_idx}")
                        # 保留从开始标记到缓冲区末尾的数据
                        buffer = buffer[start_idx:]
                        break
                    
                    # 提取完整的JPEG帧（包括结束标记）
                    jpeg_frame = buffer[start_idx:end_idx + 2]
                    jpeg_found_count += 1
                    print(f"Extracted JPEG frame {jpeg_found_count}, size: {len(jpeg_frame)} bytes")
                    
                    # 从缓冲区中移除已处理的JPEG帧
                    buffer = buffer[end_idx + 2:]
                    print(f"Buffer remaining after extraction: {len(buffer)} bytes")
                    
                    # 只处理合理大小的JPEG帧（1KB到500KB）
                    if 1024 <= len(jpeg_frame) <= 500 * 1024:
                        try:
                            # 使用PIL库来解码和显示图像
                            image_stream = io.BytesIO(jpeg_frame)
                            pil_image = Image.open(image_stream)
                            
                            if pil_image is not None:
                                # 解码成功，显示帧
                                frame_count += 1
                                print(f"Frame {frame_count} decoded successfully, size: {pil_image.width}x{pil_image.height}")
                                
                                # 转换为OpenCV格式
                                opencv_image = cv2.cvtColor(np.array(pil_image), cv2.COLOR_RGB2BGR)
                                
                                # 检查图像是否有重复的模式
                                # 从截图来看，图像被分割成了3x3的网格
                                # 这可能是因为图像高度是正常的3倍
                                if opencv_image.shape[0] == 1440 and opencv_image.shape[1] == 640:
                                    # 高度是1440，是正常的3倍
                                    # 只显示图像的前480行
                                    fixed_image = opencv_image[:480, :, :]
                                    cv2.imshow("Compressed Camera Stream", fixed_image)
                                    print(f"Fixed frame by cropping to 640x480")
                                elif opencv_image.shape[0] == 640 and opencv_image.shape[1] == 1920:
                                    # 宽度是1920，是正常的3倍
                                    # 只显示图像的前640列
                                    fixed_image = opencv_image[:, :640, :]
                                    cv2.imshow("Compressed Camera Stream", fixed_image)
                                    print(f"Fixed frame by cropping to 640x480")
                                else:
                                    # 直接显示原始大小的图像
                                    cv2.imshow("Compressed Camera Stream", opencv_image)
                                
                                # 只在显示新帧后调用一次waitKey，确保图像刷新
                                key = cv2.waitKey(1)
                                if key == 27:
                                    print("ESC key pressed, exiting...")
                                    return 1
                            else:
                                print(f"Failed to decode JPEG frame {jpeg_found_count}")
                        except Exception as e:
                            print(f"Error decoding JPEG frame {jpeg_found_count}: {e}")
                            # 尝试使用OpenCV的方式解码
                            try:
                                np_data = np.frombuffer(jpeg_frame, dtype=np.uint8)
                                frame = cv2.imdecode(np_data, cv2.IMREAD_COLOR)
                                if frame is not None:
                                    frame_count += 1
                                    print(f"Frame {frame_count} decoded with OpenCV, size: {frame.shape[1]}x{frame.shape[0]}")
                                    # 检查是否是3x3网格
                                    if frame.shape[0] > 480 and frame.shape[1] == 640:
                                        # 只显示前480行
                                        cv2.imshow("Compressed Camera Stream", frame[:480, :, :])
                                    else:
                                        cv2.imshow("Compressed Camera Stream", frame)
                                    key = cv2.waitKey(1)
                                    if key == 27:
                                        print("ESC key pressed, exiting...")
                                        return 1
                            except Exception as e2:
                                print(f"Failed with OpenCV too: {e2}")
                    else:
                        print(f"Invalid JPEG frame size: {len(jpeg_frame)} bytes, skipped")
                
            except socket.timeout:
                print("Socket timeout, no data received")
            except Exception as e:
                print(f"Error in receive loop: {e}")
            
            # 检查连接是否超时
            if time.time() - last_receive_time > 10:
                print("Connection timeout: No data received for 10 seconds")
                return 1
            
            # 检查是否按下ESC键退出
            key = cv2.waitKey(1)
            if key == 27:
                print("ESC key pressed, exiting...")
                break
        
    except socket.timeout as e:
        print(f"Connection timeout: {e}")
        return 1
    except Exception as e:
        print(f"Error: {e}")
        return 1
    finally:
        # 清理资源
        print("Cleaning up resources...")
        sockfd.close()
        cv2.destroyAllWindows()
        print(f"Client exiting. Total bytes received: {total_bytes_received}, JPEG frames found: {jpeg_found_count}, Successful frames: {frame_count}")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
