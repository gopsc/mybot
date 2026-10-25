-- test_mpath.lua - 多模块路径解析回归（issue #19）
-- 验证 modules/lib/mpath.lua 的契约：
--   1) 未设置 BOT4CJ_MODULE_PATH 时回退默认 "./modules"；
--   2) 单路径用法与默认行为完全一致（向后兼容）；
--   3) ':' 分隔多路径正确拆分，去空段去重保序；
--   4) resolve 按序返回第一个存在的文件，全部不存在回退最后一个路径拼接；
--   5) mpath.dofile 经解析后执行，等价原 dofile(拼接)。
-- 用法（项目根目录）: lua5.4 test/test_mpath.lua（run_all.sh 自动纳入；纯 Lua，不依赖 ffi）
local tester = dofile("test/lib/tester.lua")
local mp = dofile((os.getenv("BOT4CJ_MODULE_PATH") or "./modules") .. "/lib/mpath.lua")

-- 1) 缺省回退 ./modules
do
	local ps = mp.paths(nil)
	tester.check("缺省 paths() == {./modules}", #ps == 1 and ps[1] == "./modules")
	tester.check("缺省 resolve 找到 lib/mpath.lua", mp.resolve("lib/mpath.lua") == "./modules/lib/mpath.lua")
end

-- 2) 单路径向后兼容
do
	local ps = mp.paths("./modules")
	tester.check("单路径 paths() == {./modules}", #ps == 1 and ps[1] == "./modules")
	tester.check("单路径 resolve 等价缺省", mp.resolve("lib/HAL.lua", "./modules") == "./modules/lib/HAL.lua")
end

-- 3) 多路径拆分：去空段、去重、保序
do
	local ps = mp.paths("a:b")
	tester.check("多路径拆分为 {a,b}", #ps == 2 and ps[1] == "a" and ps[2] == "b")
end
do
	local ps = mp.paths("a::b")
	tester.check("空段被丢弃 {a,b}", #ps == 2 and ps[1] == "a" and ps[2] == "b")
end
do
	local ps = mp.paths("a:a:b")
	tester.check("重复路径去重 {a,b}", #ps == 2 and ps[1] == "a" and ps[2] == "b")
end

-- 4) resolve 按序查找第一个存在；全不存在回退最后一个拼接
do
	local r = mp.resolve("lib/HAL.lua", "test/mpath_p2:./modules")
	tester.check("先命中第二个路径 ./modules/lib/HAL.lua", r == "./modules/lib/HAL.lua")
end
do
	local r = mp.resolve("no_such_file.lua", "a:b")
	tester.check("全不存在回退最后一个路径拼接", r == "b/no_such_file.lua")
end

-- 5) mpath.dofile 等价原语义：能解析出 lib/drv_common.lua 并返回其导出表
do
	local ok, v = pcall(mp.dofile, "lib/mpath.lua", "./modules")
	tester.check("mpath.dofile(lib/mpath.lua) 可执行", ok and type(v) == "table")
end

tester.summary("test_mpath")
return 0
