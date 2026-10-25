/* Camera.lua 硬编码 V4L2 ioctl 编号与结构尺寸的一致性自检（F-24 同族）
 * 全部为编译期断言：常量漂移（换内核/换架构）在构建期即失败，不再依赖人工比对。
 * 期望值出处：modules/Camera.lua 的 ffi 声明段与加载期 assert。
 * 用 _Static_assert 而非 #if：_IOW/_IOWR 宏展开含 sizeof，#if 表达式不支持。 */
#include <stdio.h>
#include <time.h>		/* v4l2_event 用到 struct timespec（严格 c11 下需显式包含） */
#include <sys/time.h>		/* v4l2_buffer 用到 struct timeval */
#include <linux/videodev2.h>

#include "const_lua.h"		/* A2：配置期由 gen_const_check.cmake 从 Camera.lua 抽取 */

/* A2：先钉住 Camera.lua 里的实际值（此前 C 手抄、从不读 Lua）。 */
_Static_assert(V4L2_CONST_VIDIOC_QUERYCAP == 0x80685600,
	"Camera.lua VIDIOC_QUERYCAP drifted (expected 0x80685600)");
_Static_assert(V4L2_CONST_VIDIOC_S_FMT == 0xc0d05605,
	"Camera.lua VIDIOC_S_FMT drifted (expected 0xc0d05605)");
_Static_assert(V4L2_CONST_VIDIOC_REQBUFS == 0xc0145608,
	"Camera.lua VIDIOC_REQBUFS drifted (expected 0xc0145608)");
_Static_assert(V4L2_CONST_VIDIOC_QUERYBUF == 0xc0585609,
	"Camera.lua VIDIOC_QUERYBUF drifted (expected 0xc0585609)");
_Static_assert(V4L2_CONST_VIDIOC_QBUF == 0xc058560f,
	"Camera.lua VIDIOC_QBUF drifted (expected 0xc058560f)");
_Static_assert(V4L2_CONST_VIDIOC_DQBUF == 0xc0585611,
	"Camera.lua VIDIOC_DQBUF drifted (expected 0xc0585611)");
_Static_assert(V4L2_CONST_VIDIOC_STREAMON == 0x40045612,
	"Camera.lua VIDIOC_STREAMON drifted (expected 0x40045612)");
_Static_assert(V4L2_CONST_VIDIOC_STREAMOFF == 0x40045613,
	"Camera.lua VIDIOC_STREAMOFF drifted (expected 0x40045613)");

_Static_assert(VIDIOC_QUERYCAP == 0x80685600, "VIDIOC_QUERYCAP != 0x80685600");
_Static_assert(VIDIOC_S_FMT == 0xc0d05605, "VIDIOC_S_FMT != 0xc0d05605");
_Static_assert(VIDIOC_REQBUFS == 0xc0145608, "VIDIOC_REQBUFS != 0xc0145608");
_Static_assert(VIDIOC_QUERYBUF == 0xc0585609, "VIDIOC_QUERYBUF != 0xc0585609");
_Static_assert(VIDIOC_QBUF == 0xc058560f, "VIDIOC_QBUF != 0xc058560f");
_Static_assert(VIDIOC_DQBUF == 0xc0585611, "VIDIOC_DQBUF != 0xc0585611");
_Static_assert(VIDIOC_STREAMON == 0x40045612, "VIDIOC_STREAMON != 0x40045612");
_Static_assert(VIDIOC_STREAMOFF == 0x40045613, "VIDIOC_STREAMOFF != 0x40045613");

/* 结构尺寸是 _IOWR 里编码的那个长度：ffi 声明比内核小 → ioctl 时越界读写内存。
 * A2：Camera.lua 的 ABI 尺寸表（ffi 声明对应的期望值）也一并抽出钉住。 */
_Static_assert(V4L2_ABI_cam_buffer == 88, "Camera.lua ABI 表 cam_buffer drifted (expected 88)");
_Static_assert(V4L2_ABI_cam_format == 208, "Camera.lua ABI 表 cam_format drifted (expected 208)");
_Static_assert(V4L2_ABI_cam_pix_format == 48, "Camera.lua ABI 表 cam_pix_format drifted (expected 48)");
_Static_assert(V4L2_ABI_cam_capability == 104, "Camera.lua ABI 表 cam_capability drifted (expected 104)");
_Static_assert(V4L2_ABI_cam_requestbuffers == 20, "Camera.lua ABI 表 cam_requestbuffers drifted (expected 20)");
_Static_assert(V4L2_ABI_cam_timecode == 16, "Camera.lua ABI 表 cam_timecode drifted (expected 16)");

_Static_assert(sizeof(struct v4l2_buffer) == 88, "sizeof(v4l2_buffer) != 88");
_Static_assert(sizeof(struct v4l2_format) == 208, "sizeof(v4l2_format) != 208");
_Static_assert(sizeof(struct v4l2_pix_format) == 48, "sizeof(v4l2_pix_format) != 48");
_Static_assert(sizeof(struct v4l2_capability) == 104, "sizeof(v4l2_capability) != 104");
_Static_assert(sizeof(struct v4l2_requestbuffers) == 20, "sizeof(v4l2_requestbuffers) != 20");
_Static_assert(sizeof(struct v4l2_timecode) == 16, "sizeof(v4l2_timecode) != 16");

/* A2：语义常量也钉住 Camera.lua 的取值 */
_Static_assert(V4L2_CONST_BUF_TYPE_VIDEO_CAPTURE == 1, "Camera.lua BUF_TYPE_VIDEO_CAPTURE drifted");
_Static_assert(V4L2_CONST_MEMORY_MMAP == 1, "Camera.lua MEMORY_MMAP drifted");
_Static_assert(V4L2_CONST_CAP_VIDEO_CAPTURE == 0x00000001, "Camera.lua CAP_VIDEO_CAPTURE drifted");
_Static_assert(V4L2_CONST_PIX_FMT_MJPEG == 0x47504a4d, "Camera.lua PIX_FMT_MJPEG drifted");

_Static_assert(V4L2_BUF_TYPE_VIDEO_CAPTURE == 1, "V4L2_BUF_TYPE_VIDEO_CAPTURE != 1");
_Static_assert(V4L2_MEMORY_MMAP == 1, "V4L2_MEMORY_MMAP != 1");
_Static_assert(V4L2_CAP_VIDEO_CAPTURE == 0x00000001, "V4L2_CAP_VIDEO_CAPTURE != 1");
_Static_assert(V4L2_PIX_FMT_MJPEG == 0x47504a4d, "V4L2_PIX_FMT_MJPEG != 0x47504a4d");

int main(void) {
	printf("V4L2 常量自检通过：Camera.lua 抽取值 == 预期值 == 内核头（ioctl + 结构尺寸）\n");
	return 0;
}
