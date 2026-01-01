cmake_minimum_required(VERSION 3.20)
project(TxL)

set(CMAKE_CXX_STANDARD 23)

add_Executable(botd src/mainParserNet.cpp src/hd/I2C.cpp src/hd/PCA9685.cpp src/hd/MPU6050.cpp)
add_Executable(txl src/main.cpp src/hd/Camera.cpp)

target_link_libraries(botd pthread cpp-httplib)
target_link_libraries(txl jpeg) 
