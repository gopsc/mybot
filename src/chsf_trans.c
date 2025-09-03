#include "chsf.c"


#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <iconv.h>

// 转换函数：将GBK编码转换为UTF-8
// 参数：
//   gbk_str: 输入的GBK编码字符串
//   gbk_len: 输入字符串的长度（字节数）
//   utf8_buf: 输出的UTF-8缓冲区
//   utf8_buf_len: 输出缓冲区的大小
// 返回值：成功返回转换后的UTF-8长度，失败返回-1
int gbk_to_utf8(const char *gbk_str, size_t gbk_len, 
                char *utf8_buf, size_t utf8_buf_len) {
    if (gbk_str == NULL || utf8_buf == NULL || gbk_len == 0 || utf8_buf_len == 0) {
        return -1;
    }

    // 创建转换描述符：从GBK到UTF-8
    iconv_t cd = iconv_open("UTF-8", "GB18030");
    if (cd == (iconv_t)-1) {
        perror("iconv_open failed");
        return -1;
    }

    // 注意：iconv函数会修改指针，所以需要使用临时变量
    char *in_buf = (char *)gbk_str;
    size_t in_left = gbk_len;
    char *out_buf = utf8_buf;
    size_t out_left = utf8_buf_len;

    // 执行转换
    size_t result = iconv(cd, &in_buf, &in_left, &out_buf, &out_left);
    if (result == (size_t)-1) {
        perror("iconv failed");
        iconv_close(cd);
        return -1;
    }

    // 确保输出字符串以'\0'结尾
    if (out_left > 0) {
        *out_buf = '\0';
    }

    // 关闭转换描述符
    iconv_close(cd);

    // 返回转换后的字节数（不包括结尾的'\0'）
    return utf8_buf_len - out_left - 1;
}

// 将UTF-8字符串转换为UTF-32宽字符（32位）
// 参数：
//   utf8_str: 输入的UTF-8字符串
//   utf8_len: 输入字符串长度（字节，不含终止符）
//   utf32_buf: 输出的UTF-32缓冲区（需预先分配）
//   buf_size: 输出缓冲区大小（最大可存储的UTF-32字符数）
// 返回值：成功返回转换后的字符数，失败返回-1
int utf8_to_utf32(const char *utf8_str, size_t utf8_len,
                  uint32_t *utf32_buf, size_t buf_size) {
    if (utf8_str == NULL || utf32_buf == NULL || buf_size == 0) {
        return -1;
    }

    // 创建转换描述符：从UTF-8到UTF-32（根据系统字节序选择，这里用通用UTF-32）
    // 若需指定字节序，可改为"UTF-32BE"（大端）或"UTF-32LE"（小端）
    iconv_t cd = iconv_open("UTF-32", "UTF-8");
    if (cd == (iconv_t)-1) {
        perror("iconv_open failed");
        return -1;
    }

    // 准备输入输出缓冲区（iconv会修改指针，需用临时变量）
    char *in_buf = (char *)utf8_str;
    size_t in_left = utf8_len;
    char *out_buf = (char *)utf32_buf;
    size_t out_left = buf_size * sizeof(uint32_t); // 总字节数

    // 执行转换
    size_t result = iconv(cd, &in_buf, &in_left, &out_buf, &out_left);
    if (result == (size_t)-1) {
        perror("iconv failed");
        iconv_close(cd);
        return -1;
    }

    // 关闭转换描述符
    iconv_close(cd);

    // 计算转换后的字符数（总输出字节数 / 每个UTF-32字符的字节数）
    size_t converted = (buf_size * sizeof(uint32_t) - out_left) / sizeof(uint32_t);

    // 添加UTF-32字符串终止符（U+0000）
    if (converted < buf_size) {
        utf32_buf[converted] = 0;
    }

    return converted;
}

int main() {
    FILE* f = fopen("./chsf_output.csv", "w");
    for (int i=0; i<sizeof(zzhi); i+=2) {

        // 示例：GBK编码的字符串（"测试ANSI转UTF-8"的GBK编码）
        char gbk_str[3] = {zzhi[i], zzhi[i+1], '\0'};
        size_t gbk_len = 2;

        // 分配UTF-8缓冲区（GBK转UTF-8最大会膨胀到原来的3倍）
        size_t utf8_buf_size = gbk_len * 3 + 1; // +1用于存放终止符
        char *utf8_buf = (char *)malloc(utf8_buf_size);
        if (utf8_buf == NULL) {
            perror("malloc failed");
            return 1;
        }
        memset(utf8_buf, 0, utf8_buf_size);

        // 执行转换
        int utf8_len = gbk_to_utf8(gbk_str, gbk_len, utf8_buf, utf8_buf_size);
        if (utf8_len < 0) {
            printf("转换失败: %d, %d\n", zzhi[i], zzhi[i+1]);
            fputc('0', f);
            fputc(',', f);
            fputc('0', f);
            fputc(',', f);
            fputc('0', f);
            fputc(',', f);
            fputc('0', f);
            fputc(',', f);
            //free(utf8_buf);
            //return 1;
        }

        else {
            // 输出结果
            //printf("GBK字符串: %s (长度: %zu字节)\n", gbk_str, gbk_len);
            //printf("UTF-8字符串: %s (长度: %d字节)\n", utf8_buf, utf8_len);
            
    // 输入的UTF-8字符串（示例："Hello, 世界"）
    const char *utf8_str = utf8_buf;
    size_t utf8_len = strlen(utf8_str);

    // 计算所需UTF-32缓冲区大小（每个字符4字节，预留1个终止符）
    size_t utf32_buf_size = utf8_len + 1; // 保守估计，实际可能更少
    uint32_t *utf32_buf = (uint32_t *)malloc(utf32_buf_size * sizeof(uint32_t));
    if (utf32_buf == NULL) {
        perror("malloc failed");
        return 1;
    }

    // 执行转换
    int converted = utf8_to_utf32(utf8_str, utf8_len, utf32_buf, utf32_buf_size);
    if (converted < 0) {
        printf("转换失败\n");
        free(utf32_buf);
        return 1;
    }

    // 输出结果（打印每个UTF-32字符的十六进制值）
    //printf("UTF-8字符串: %s\n", utf8_str);
    //printf("转换后的UTF-32字符（十六进制）: ");
    //for (int i = 0; i < converted; i++) {
    //    printf("0x%08X ", utf32_buf[i]);
    //}
    //printf("\n");

    // 写入csv文件
    uint8_t *p = (uint8_t *)(utf32_buf+1);
    for (int i=0; i<sizeof(uint32_t); i++) {
        fprintf(f, "%d", *(p++));
        fputc(',', f);
    }

    free(utf32_buf);


        }

        // 释放资源
        free(utf8_buf);

    }
    return 0;
}

