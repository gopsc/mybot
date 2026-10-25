#pragma once

#include <vector>

// 抓当前 OpenGL 后缓冲（GL_BACK），垂直翻转后编码成 JPEG 返回；失败返回空 vector。
// outW/outH 回填实际帧尺寸（取自 GL_VIEWPORT）。quality 取 1..100。
// 必须在渲染完、glfwSwapBuffers 之前调用（那时 GL_BACK 才是刚画好的这一帧）。
std::vector<unsigned char> grabFrameJpeg(int quality, int& outW, int& outH);
