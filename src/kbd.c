/* HID to Mac keyboard scancode mapping
 *
 * FIXME: This doesn't do capslock (needs to track toggle), and arrow
 * keys don't work.
 *
 * Copyright 2024 Matt Evans
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation files
 * (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge,
 * publish, distribute, sublicense, and/or sell copies of the Software,
 * and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 * BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
 * ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include <stdio.h>
#include "kbd.h"

#include "class/hid/hid.h"
#include "keymap.h"

#define KQ_SIZE         32
#define KQ_MASK         (KQ_SIZE-1)

static uint16_t kbd_queue[KQ_SIZE];
static unsigned int kbd_queue_prod = 0;
static unsigned int kbd_queue_cons = 0;

static bool     kbd_queue_full()
{
        return ((kbd_queue_prod + 1) & KQ_MASK) == kbd_queue_cons;
}


bool            kbd_queue_empty()
{
        return kbd_queue_prod == kbd_queue_cons;
}

/* If empty, return 0, else return a mac keycode in [7:0] and [15] set if a press (else release) */
uint16_t        kbd_queue_pop()
{
        if (kbd_queue_empty())
                return 0;
        uint16_t v = kbd_queue[kbd_queue_cons];
        kbd_queue_cons = (kbd_queue_cons + 1) & KQ_MASK;
        return v;
}

/* TODO: 无论如何，保留这一抽象层 */
static const uint8_t hid_to_mac[256] = {
        [HID_KEY_NONE] = 0,
        [HID_KEY_A] = 'a',
        [HID_KEY_B] = 'b',
        [HID_KEY_C] = 'c',
        [HID_KEY_D] = 'd',
        [HID_KEY_E] = 'e',
        [HID_KEY_F] = 'f',
        [HID_KEY_G] = 'g',
        [HID_KEY_H] = 'h',
        [HID_KEY_I] = 'i',
        [HID_KEY_J] = 'j',
        [HID_KEY_K] = 'k',
        [HID_KEY_L] = 'l',
        [HID_KEY_M] = 'm',
        [HID_KEY_N] = 'n',
        [HID_KEY_O] = 'o',
        [HID_KEY_P] = 'p',
        [HID_KEY_Q] = 'q',
        [HID_KEY_R] = 'r',
        [HID_KEY_S] = 's',
        [HID_KEY_T] = 't',
        [HID_KEY_U] = 'u',
        [HID_KEY_V] = 'v',
        [HID_KEY_W] = 'w',
        [HID_KEY_X] = 'x',
        [HID_KEY_Y] = 'y',
        [HID_KEY_Z] = 'z',
        [HID_KEY_1] = '1',
        [HID_KEY_2] = '2',
        [HID_KEY_3] = '3',
        [HID_KEY_4] = '4',
        [HID_KEY_5] = '5',
        [HID_KEY_6] = '6',
        [HID_KEY_7] = '7',
        [HID_KEY_8] = '8',
        [HID_KEY_9] = '9',
        [HID_KEY_0] = '0',
        [HID_KEY_ENTER] = '\r',
        [HID_KEY_BACKSPACE] = '\b',
        [HID_KEY_TAB] = '\t',
        [HID_KEY_SPACE] = ' ',
        [HID_KEY_COMMA] = ',',
        [HID_KEY_EQUAL] = '=',
	[HID_KEY_MINUS] = '-',
        [HID_KEY_SLASH] = '/',
        /* 控制台命令历史：这两个值只作为方向键事件使用。 */
        [HID_KEY_ARROW_UP] = 0x11,
        [HID_KEY_ARROW_DOWN] = 0x12,
        //[HID_KEY_A] = 255, // Hack for MKC_A,
        //[HID_KEY_ESCAPE] = MKC_Escape,
        //[HID_KEY_MINUS] = MKC_Minus,
        //[HID_KEY_EQUAL] = MKC_Equal,
        //[HID_KEY_BRACKET_LEFT] = MKC_LeftBracket,
        //[HID_KEY_BRACKET_RIGHT] = MKC_RightBracket,
        //[HID_KEY_BACKSLASH] = MKC_BackSlash,
        //[HID_KEY_SEMICOLON] = MKC_SemiColon,
        //[HID_KEY_APOSTROPHE] = MKC_SingleQuote,
        //[HID_KEY_GRAVE] = MKC_Grave,
        //[HID_KEY_PERIOD] = MKC_Period,
        //[HID_KEY_SLASH] = MKC_Slash,
        //[HID_KEY_CAPS_LOCK] = MKC_CapsLock,
        //[HID_KEY_F1] = MKC_F1,
        //[HID_KEY_F2] = MKC_F2,
        //[HID_KEY_F3] = MKC_F3,
        //[HID_KEY_F4] = MKC_F4,
        //[HID_KEY_F5] = MKC_F5,
        //[HID_KEY_F6] = MKC_F6,
        //[HID_KEY_F7] = MKC_F7,
        //[HID_KEY_F8] = MKC_F8,
        //[HID_KEY_F9] = MKC_F9,
        //[HID_KEY_F10] = MKC_F10,
        //[HID_KEY_F11] = MKC_F11,
        //[HID_KEY_F12] = MKC_F12,
        //[HID_KEY_PRINT_SCREEN] = MKC_Print,
        //[HID_KEY_SCROLL_LOCK] = MKC_ScrollLock,
        //[HID_KEY_PAUSE] = MKC_Pause,
        //[HID_KEY_INSERT] = MKC_Help,
        //[HID_KEY_HOME] = MKC_Home,
        //[HID_KEY_PAGE_UP] = MKC_PageUp,
        //[HID_KEY_DELETE] = MKC_BackSpace,
        //[HID_KEY_END] = MKC_End,
        //[HID_KEY_PAGE_DOWN] = MKC_PageDown,
        //[HID_KEY_ARROW_RIGHT] = MKC_Right,
        //[HID_KEY_ARROW_LEFT] = MKC_Left,
        //[HID_KEY_ARROW_DOWN] = MKC_Down,
        //[HID_KEY_ARROW_UP] = MKC_Up,
        /* [HID_KEY_NUM_LOCK] = MKC_, */
        //[HID_KEY_KEYPAD_DIVIDE] = MKC_KPDevide,
        //[HID_KEY_KEYPAD_MULTIPLY] = MKC_KPMultiply,
        //[HID_KEY_KEYPAD_SUBTRACT] = MKC_KPSubtract,
        //[HID_KEY_KEYPAD_ADD] = MKC_KPAdd,
        //[HID_KEY_KEYPAD_ENTER] = MKC_Enter,
        //[HID_KEY_KEYPAD_1] = MKC_KP1,
        //[HID_KEY_KEYPAD_2] = MKC_KP2,
        //[HID_KEY_KEYPAD_3] = MKC_KP3,
        //[HID_KEY_KEYPAD_4] = MKC_KP4,
        //[HID_KEY_KEYPAD_5] = MKC_KP5,
        //[HID_KEY_KEYPAD_6] = MKC_KP6,
        //[HID_KEY_KEYPAD_7] = MKC_KP7,
        //[HID_KEY_KEYPAD_8] = MKC_KP8,
        //[HID_KEY_KEYPAD_9] = MKC_KP9,
        //[HID_KEY_KEYPAD_0] = MKC_KP0,
        //[HID_KEY_KEYPAD_DECIMAL] = MKC_Decimal,
        //[HID_KEY_KEYPAD_EQUAL] = MKC_Equal,
        //[HID_KEY_RETURN] = MKC_Return,
        /* [HID_KEY_POWER] = MKC_, */
        /* [HID_KEY_KEYPAD_COMMA] = MKC_, */
        /* [HID_KEY_KEYPAD_EQUAL_SIGN] = MKC_, */
        //[HID_KEY_CONTROL_LEFT] = MKC_Control,
        //[HID_KEY_SHIFT_LEFT] = MKC_Shift,
        //[HID_KEY_ALT_LEFT] = MKC_Option,
        //[HID_KEY_GUI_LEFT] = MKC_Command,
        //[HID_KEY_CONTROL_RIGHT] = MKC_Control,
        //[HID_KEY_SHIFT_RIGHT] = MKC_Shift,
        //[HID_KEY_ALT_RIGHT] = MKC_Option,
        //[HID_KEY_GUI_RIGHT] = MKC_Command,
};

static bool     kbd_map(uint8_t hid_keycode, bool pressed, uint16_t *key_out)
{
        uint8_t k = hid_to_mac[hid_keycode];
        if (!k)
                return false;
        //if (k == 255)
        //        k = MKC_A; // Hack, this is zero
        //k = (k << 1) | 1; // FIXME just do this in the #defines
        *key_out = k | (pressed ? 0x8000 : 0); /* Convention w.r.t. main */
        return true;
}

bool            kbd_queue_push(uint8_t hid_keycode, bool pressed)
{
        if (kbd_queue_full())
                return false;

        uint16_t v;
        if (!kbd_map(hid_keycode, pressed, &v))
                return false;

        kbd_queue[kbd_queue_prod] = v;
        kbd_queue_prod = (kbd_queue_prod + 1) & KQ_MASK;
        return true;
}
