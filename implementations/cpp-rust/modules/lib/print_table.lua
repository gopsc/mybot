-- print_table.lua - 调试打印辅助（modules/lib/）
-- bot4cj 仓颉语言机器人框架
--
-- 递归打印一张 Lua 表（原各驱动内联复制的同名函数收敛于此）。
-- 驱动顶部 dofile 加载；print 在调用时才查全局，故 sensor_daemon 沉默
-- print 后本函数的输出随之静默，行为与原内联版一致。

-- dbg_table - 驱动层调试横幅+表打印：仅 BOT4CJ_DEBUG=1 时输出
-- （与仓颉侧 MatrixVars.logD 同一开关），缺省静默，解决 @Action 逐行逐舵机
-- 的横幅刷屏；HAL/守护的错误诊断不经本函数，始终可见
if dbg_table == nil then
    function dbg_table(title, data)
        if os.getenv("BOT4CJ_DEBUG") ~= "1" then return end
        print(title)
        print_table(data)
        print(string.rep("-", string.len(title)))
    end
end

-- 重复加载保护：同一状态机内只定义一次
if print_table ~= nil then return end

function print_table(t, indent)
    indent = indent or 0
    for k, v in pairs(t) do
        if type(v) == 'table' then
            print(string.rep(' ', indent) .. k .. ":")
            print_table(v, indent + 2)
        else
            print(string.rep(' ', indent) .. k .. ": " .. tostring(v))
        end
    end
end
