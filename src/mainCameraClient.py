#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
相机客户端Python实现
功能：连接服务器接收YUYV格式视频流，转换为RGB并显示
"""

import socket
import cv2
import numpy as np
import sys


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <server_ip> <port>")
        return 1
    
    server_ip = sys.argv[1]
    port = int(sys.argv[2])
    
    # 创建TCP套接字
    sockfd = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    
    try:
        # 连接到服务器
        sockfd.connect((server_ip, port))
        print(f"Connected to server: {server_ip}:{port}")
        
        # 图像参数
        WIDTH = 640
        HEIGHT = 480
        FRAME_BUFFER_SIZE = WIDTH * HEIGHT * 2  # YUYV格式：640x480，每个像素2字节
        
        # OpenCV窗口
        cv2.namedWindow("Camera Stream", cv2.WINDOW_AUTOSIZE)
        
        frame_count = 0
        while True:
            # 接收帧数据
            frame_buffer = b''
            while len(frame_buffer) < FRAME_BUFFER_SIZE:
                data = sockfd.recv(FRAME_BUFFER_SIZE - len(frame_buffer))
                if not data:
                    print("Server closed connection")
                    return 0
                frame_buffer += data
            
            print(f"Frame {frame_count + 1} received: {len(frame_buffer)} bytes")
            frame_count += 1
            
            # 使用OpenCV处理YUYV帧
            yuyv_frame = np.frombuffer(frame_buffer, dtype=np.uint8).reshape((HEIGHT, WIDTH, 2))
            rgb_frame = cv2.cvtColor(yuyv_frame, cv2.COLOR_YUV2BGR_YUYV)
            
            # 显示帧
            cv2.imshow("Camera Stream", rgb_frame)
            
            # 等待1ms，允许窗口刷新，同时检查是否按下ESC键退出
            if cv2.waitKey(1) == 27:
                print("ESC key pressed, exiting...")
                break
        
    except Exception as e:
        print(f"Error: {e}")
        return 1
    finally:
        # 清理资源
        sockfd.close()
        cv2.destroyAllWindows()
        print("Client exiting")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
