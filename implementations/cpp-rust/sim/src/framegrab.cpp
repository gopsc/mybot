#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <glad/glad.h>

#include <cstring>

#include "framegrab.h"

namespace {

// stb 的写回调：把编码出的 JPEG 分块追加进 vector（一块通常是整个文件，但协议
// 允许分多次回调，故用 insert 累加而不假设一次到位）。
void appendChunk(void* ctx, void* data, int size) {
    auto* out = static_cast<std::vector<unsigned char>*>(ctx);
    const auto* p = static_cast<const unsigned char*>(data);
    out->insert(out->end(), p, p + size);
}

}  // namespace

std::vector<unsigned char> grabFrameJpeg(int quality, int& outW, int& outH) {
    outW = 0;
    outH = 0;

    GLint vp[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_VIEWPORT, vp);
    const int w = vp[2];
    const int h = vp[3];
    if (w <= 0 || h <= 0) {
        return {};
    }
    outW = w;
    outH = h;

    const std::size_t rowBytes = static_cast<std::size_t>(w) * 3;
    std::vector<unsigned char> rgb(rowBytes * static_cast<std::size_t>(h));

    // RGB 每行 3*w 字节，默认 GL_PACK_ALIGNMENT=4 会给行尾补 padding，导致按
    // w*3 连续读时错位；显式设 1 消除补白。
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadBuffer(GL_BACK);
    glReadPixels(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, rgb.data());

    // glReadPixels 原点在左下（首行是画面最底行），JPEG 期望首行是顶行，翻转。
    std::vector<unsigned char> flipped(rgb.size());
    for (int y = 0; y < h; ++y) {
        std::memcpy(flipped.data() + static_cast<std::size_t>(y) * rowBytes,
                    rgb.data() + static_cast<std::size_t>(h - 1 - y) * rowBytes, rowBytes);
    }

    int q = quality;
    if (q < 1) q = 1;
    if (q > 100) q = 100;

    std::vector<unsigned char> jpeg;
    if (stbi_write_jpg_to_func(appendChunk, &jpeg, w, h, 3, flipped.data(), q) == 0) {
        return {};
    }
    return jpeg;
}
