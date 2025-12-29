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
import io


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
        
        # OpenCV窗口
        cv2.namedWindow("Compressed Camera Stream", cv2.WINDOW_AUTOSIZE)
        
        frame_count = 0
        buffer = b''  # 用于累积数据的缓冲区
        
        while True:
            # 接收数据（使用较小的缓冲区，因为JPEG大小可变）
            data = sockfd.recv(8192)
            if not data:
                print("Server closed connection")
                return 0
            
            # 将新数据添加到缓冲区
            buffer += data
            
            try:
                # 尝试从缓冲区解码JPEG
                # 使用numpy将字节数据转换为OpenCV可用的格式
                np_data = np.frombuffer(buffer, dtype=np.uint8)
                
                # 尝试解码JPEG
                frame = cv2.imdecode(np_data, cv2.IMREAD_COLOR)
                
                if frame is not None:
                    # 解码成功，显示帧
                    print(f"Frame {frame_count + 1} decoded successfully")
                    frame_count += 1
                    
                    cv2.imshow("Compressed Camera Stream", frame)
                    
                    # 清空缓冲区，准备接收下一帧
                    buffer = b''
            except Exception as e:
                # 解码失败，继续累积数据
                # 这可能是因为数据不完整
                pass
            
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
