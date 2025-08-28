/* hw_config.c
Copyright 2021 Carl John Kugler III

Licensed under the Apache License, Version 2.0 (the License); you may not use 
this file except in compliance with the License. You may obtain a copy of the 
License at

   http://www.apache.org/licenses/LICENSE-2.0 
Unless required by applicable law or agreed to in writing, software distributed 
under the License is distributed on an AS IS BASIS, WITHOUT WARRANTIES OR 
CONDITIONS OF ANY KIND, either express or implied. See the License for the 
specific language governing permissions and limitations under the License.
*/
 
/* 该作品源于 Apache 协议的原始项目，且已进行修改
 * 修改记录：
 * 
 * 202508029(qing): 增加了中文注释与开源许可的提示
 */

/*
核心权利：使用者可做什么？
基于 Apache 2.0 协议，任何获得授权的使用者（个人 / 企业）均享有以下无附加条件的自由：

    自由使用（Use）：可将开源代码用于任何场景（商业、非商业、个人、企业），无需向基金会或原作者申请额外许可；
    自由修改（Modify）：可根据自身需求修改代码（如新增功能、修复漏洞），修改后的代码可保留私有或公开；
    自由分发（Distribute）：可将原始代码或修改后的代码以 “源代码” 或 “二进制可执行文件” 形式分发（如打包进自己的软件、单独出售代码包）；
    自由再许可（Sublicense）：可将代码与其他协议（如 MIT、BSD 等宽松协议）的代码混合，或嵌入商业闭源软件中再分发，无需强制公开自身代码。

核心义务：使用者必须做什么？
宽松协议不代表 “无约束”，Apache 2.0 要求使用者在分发代码时履行以下义务，核心是 “透明化来源与修改”：

    保留版权声明与许可文本
        必须在所有分发的 “源代码副本” 或 “二进制文件附属文档”（如 README、LICENSE 文件）中，完整保留原始代码的版权声明（如 Copyright (c) 20XX The Apache Software Foundation）和 Apache 2.0 协议全文；
        若修改了代码，需在修改部分的文档中明确标注 “修改记录”（如 “此文件基于 Apache 项目 X 版本修改，修改内容包括：XXX”），但无需单独开源修改部分（除非主动选择）。
    明确专利授权义务
        这是 Apache 2.0 区别于其他宽松协议（如 MIT、BSD）的核心特性：代码贡献者需自动授予使用者 “非独占、全球范围、免专利费” 的专利许可，允许使用者使用代码中涉及的专利技术；
        若使用者指控开源代码侵犯自身专利，将自动丧失该协议下的专利授权（“专利报复条款”），避免 “使用者用专利攻击开源项目” 的情况。
    声明修改与衍生关系
        若分发的是 “修改后的代码” 或 “基于原代码的衍生作品”，需明确标注 “该作品源于 Apache 协议的原始项目，且已进行修改”，不得误导用户认为 “修改部分是原项目的官方功能”。
    不滥用商标
        禁止使用 Apache 软件基金会或原项目的商标、Logo（如 Apache 的羽毛标志、Spring 的叶子标志）进行商业宣传，除非获得基金会的单独商标授权（避免 “借开源品牌背书” 的不当竞争）。

 */
  
/*

This file should be tailored to match the hardware design.

There should be one element of the spi[] array for each hardware SPI used.

There should be one element of the sd_cards[] array for each SD card slot.
The name is should correspond to the FatFs "logical drive" identifier.
(See http://elm-chan.org/fsw/ff/doc/filename.html#vol)
The rest of the constants will depend on the type of
socket, which SPI it is driven by, and how it is wired.

*/
#include <string.h>
//
#include "my_debug.h"
//
#include "hw_config.h"
//
#include "ff.h" /* Obtains integer types */
                /* 包括整数类型 */
#include "diskio.h" /* Declarations of disk functions */
                    /* 包括硬盘文件的声明 */
// Hardware Configuration of SPI "objects"
// Note: multiple SD cards can be driven by one SPI if they use different slave
// selects.
static spi_t spis[] = {  // One for each SPI.
    {
        .hw_inst = spi0,  // SPI component
        .miso_gpio = SD_RX, // GPIO number (not pin number)
        .mosi_gpio = SD_TX,
        .sck_gpio = SD_SCK,

        .set_drive_strength = true,
        .mosi_gpio_drive_strength = GPIO_DRIVE_STRENGTH_8MA,
        .sck_gpio_drive_strength = GPIO_DRIVE_STRENGTH_8MA,

        // One of my cards doesn't seem to work beyond 5MHz :(
        .baud_rate = SD_MHZ * 1000 * 1000,
    }
};

// Hardware Configuration of the SD Card "objects"
static sd_card_t sd_cards[] = {  // One for each SD card
    {
        .pcName = "0:",   // Name used to mount device
        .spi = &spis[0],  // Pointer to the SPI driving this card
        .ss_gpio = SD_CS, // The SPI slave select GPIO for this SD card
        .set_drive_strength = true,
        .ss_gpio_drive_strength = GPIO_DRIVE_STRENGTH_8MA,
        .use_card_detect = false,
        .card_detected_true = -1  // What the GPIO read returns when a card is
                                  // present. Use -1 if there is no card detect.
    }};

/* ********************************************************************** */
size_t sd_get_num() { return count_of(sd_cards); }
sd_card_t *sd_get_by_num(size_t num) {
    if (num <= sd_get_num()) {
        return &sd_cards[num];
    } else {
        return NULL;
    }
}
size_t spi_get_num() { return count_of(spis); }
spi_t *spi_get_by_num(size_t num) {
    if (num <= sd_get_num()) {
        return &spis[num];
    } else {
        return NULL;
    }
}

/* [] END OF FILE */
