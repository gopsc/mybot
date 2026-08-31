/*
 *  机器人构成模块
 *  INFO(20260514-qing): 该模块确定机器人结构，为解耦考虑应该从解析出的矩阵对象中构建
 *  TODO(20260527-qing): 使脚本中的数值亦可从运行时确定
 */

package bot4cj
import std.io.*
import std.time.*
import std.random.*
import std.collection.*
import std.convert.*
import std.env.*
import stdx.encoding.json.*
import bot4cj.math.*
import bot4cj.hd.*
import ctype4cj.*
import iic4cj.*
import spi4cj.*
import lua4cj.*

/*
 * ---------------- 硬件变量基类 ----------------
 *  接收3个lambda表达式，在回调函数中定义行为（）
 *  通过JsonValue这种通用的数据结构进行传值
 *  
 *  INFO*(20260517-qing): 因为析构器（终结器）的调用时间不确定，需要手动构造RAII机制
 *  TODO(20260519-qing): 考虑将@Action矩阵对象置为硬件变量的一种
 *  TODO*(20260529-qing): 增加微调器机制，通过不同的微调器对@Action进行微调
 */
open class MatrixVars_Hardware {

	/*  ---------------- 主初始化器 ----------------
	 *   输入三个回调函数，用json参数能够为多种硬件提供同一接口
	 *   在@Action矩阵中的每一列都是一个输入参数
	 *  --------------------------------------------  */
	public init(
	things!: (JsonValue) -> JsonValue,	/* 运行硬件或传感器 */
	rise!: Option<() -> Unit>,		/* 可选的硬件构造函数 */
	free!: Option<() -> Unit>) {		/* 可选的硬件析构函数 */

		this.things = things
		this.rise   = rise
		this.free   = free
	}


	/*
	 *  --------------------------------
	 *  事件回调，接收和返回JsonValue 这是整个硬件的主要事件
	 */
	private let things: (JsonValue) -> JsonValue	

	/* 召集事件，不接受参数  即硬件获取资源  */
	private let rise: Option<() -> Unit>

	/* 遣返事件，不接受参数  即硬件释放资源*/
	private let free: Option<() -> Unit>

	/*
	 *  -------------------------------- *
	 *  事件发生器  该方法会调用硬件，需要传入1个JsonValue参数  它返回1个JsonValue值
	 *
	 *  TODO(20260612-qing): 使用某种方式记录变量是否经过了初始化 
	 */
	public func play(input: JsonValue): JsonValue {  return things(input)  }

	/*
	 *  -------------------------------- *
	 *  伪初始化器  该方法会打开硬件，什么也不传入和返回
	 */

	public func build() {

		if (let Some(callback) <- rise) {  callback()  }
	}

	/* 
	 *  -------------------------------- *
	 *  伪解构器   该方法会关闭硬件，什么也不传入和返回
	 */
	public func destroy() {

		if (let Some(callback) <- free) {  callback()  }
	}

	/*
	 *  ---------------------------------- 
	 *  获得项目值。如果矩阵单元的原始值是占位符且不为标题行，
	 *  不为首行， 就递归地获取上一行的值
	 */
	public static func getMt(obj: MatrixObject, row: Int64, col: Int64): String
	{
		let raw = obj[row, col]
		if (raw == "-" && row > 1) {
			return getMt(obj, row - 1, col)
		}
		return raw
	}

	/*
	 * ----------------------------------
	 * 解析项目值，先获取矩阵单元的项目值————解析过占位符的值）————然后解析为需要的类型
	 */
	public static func parseMt<T>(obj: MatrixObject, row: Int64, col: Int64): T  where T <: Parsable<T>
	{	
		/* 先获取矩阵单元的原始值 */
		let raw = obj[row, col]

		/* 如果原始值为占位符且（非首行的）非标题行 */
		if      (raw == "-" &&   row > 1)  { return  parseMt<T>(obj, row-1, col)  }

		/* 原始值为占位符且为（非标题行的）首行 */
		else if (raw == "-" && !(row > 1)) {  return T.parse("0")  }

		/* 原始值并非占位符  */
		// else if (!raw == "-")
		return T.parse(raw)
	}



	/* ---------------------------------- */
}


/*
 * ----------------------------------
 * 用于注册到Lua的I2C操作函数
 */

@C /* 打开一个I2C设备 */
func Lua_openI2c(L: lua_State): C_Int {
	unsafe {
		let filename: CString = Lua_checkstring(L, 1)	/* 第一个参数 */
		let fd = openI2cDev(filename)			/* 进行操作 */
		let val: lua_Integer = Int64(fd)		/* FIXME: 使用lua_Integer构造 */
		Lua_pushinteger(L, val) 			/* 向lua状态机中压入整数 */
		return 1					/* 返回1，表示有1个返回值 */
	}
}

@C /* 关闭I2C设备 */
func Lua_closeI2c(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))	/* FIXME: 使用C_Int直接构造 */
		closeI2cDev(fd)
		return 0
	}
}

@C /* 设置I2C地址 */
func Lua_setI2cAddr(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))		/* FIXME: 使用C_Int直接构造 */
		let addr = UInt8(Lua_checkinteger(L, 2))	/* 第二个参数 */
		setI2cAddr(fd, addr)
		return 0
	}
}


@C /* 写I2C寄存器 */
func Lua_writeI2cReg(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))		/* FIXME: 使用C_Int直接构造 */
		let reg = UInt8(Lua_checkinteger(L, 2))
		let val = UInt8(Lua_checkinteger(L, 3))
		writeI2cReg(fd, reg, val)
		return 0
	}
}


@C /* 读I2C寄存器 */
func Lua_readI2cReg(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))		/* FIXME: 使用C_Int直接构造 */
		let reg = UInt8(Lua_checkinteger(L, 2))
		let res = Int64(readI2cReg(fd, reg))		/* FIXME: 使用lua_Integer直接构造 */
		Lua_pushinteger(L, res)
		return 1
	}
}

@C /* 写I2C寄存器多个字节（burst 写：reg + 2 字节数据）
 * 用于 ADS1115 等 16 位寄存器设备。
 *
 * Lua 调用示例（见 modules/ADS1115.lua）：
 *   i2c_set_addr(fd, 0x48)
 *   -- 写 CONFIG 寄存器(0x01)：高字节 0x84、低字节 0x83
 *   i2c_write_multi(fd, 0x01, 0x84, 0x83)
 *   返回值：0 = 成功，-1 = 失败 */
func Lua_i2cWriteMulti(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))
		let reg = UInt8(Lua_checkinteger(L, 2))
		let b1 = UInt8(Lua_checkinteger(L, 3))
		let b2 = UInt8(Lua_checkinteger(L, 4))
		let buf = LibC.malloc<UInt8>(count: 3)
		(buf + 0).write(reg)
		(buf + 1).write(b1)
		(buf + 2).write(b2)
		let res = libc_write(fd, CPointer<Unit>(buf), 3)
		LibC.free(buf)
		if (res == 3) { Lua_pushinteger(L, 0) }
		else { Lua_pushinteger(L, -1) }
		return 1
	}
}

@C /* 读I2C寄存器多个字节（burst 读：写指针 + 读 n 字节）
 * 返回大端合并后的整数值，失败返回 -1。
 *
 * Lua 调用示例（见 modules/ADS1115.lua）：
 *   i2c_set_addr(fd, 0x48)
 *   local raw = i2c_read_multi(fd, 0x00, 2)  -- 读 16 位转换结果(大端)
 *   local hi  = math.floor(raw / 256) % 256  -- 拆高字节
 *   local lo  = raw % 256                    -- 拆低字节 */
func Lua_i2cReadMulti(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))
		let reg = UInt8(Lua_checkinteger(L, 2))
		var n = Int64(Lua_checkinteger(L, 3))
		if (n < 1 || n > 8) { n = 1 }
		var ptr = reg
		if (1 != libc_write(fd, CPointer<Unit>(inout ptr), 1)) {
			Lua_pushinteger(L, -1)
			return 1
		}
		let buf = LibC.malloc<UInt8>(count: n)
		let ret = libc_read(fd, CPointer<Unit>(buf), UIntNative(n))
		if (ret != IntNative(n)) {
			LibC.free(buf)
			Lua_pushinteger(L, -1)
			return 1
		}
		var v: Int64 = 0
		for (i in 0..n) {
			v = (v << 8) | Int64((buf + i).read())
		}
		LibC.free(buf)
		Lua_pushinteger(L, v)
		return 1
	}
}


@C /* 毫秒级延时 */
func Lua_milliSleep(L: lua_State): C_Int {
	unsafe {
		let n = Int64(Lua_checkinteger(L, 1))
		sleep(Duration.millisecond * n)
		return 0
	}
}


@C /* 打开一个SPI设备 */
func Lua_openSPI(L: lua_State): C_Int {
	unsafe {
		let filename: CString = Lua_checkstring(L, 1)
		let fd = open_spi(filename)
		let val: lua_Integer = Int64(fd)		/* FIXME: 直接使用lua_Integer构造 */
		Lua_pushinteger(L, val) 
		return 1
	}
}


@C  /* 关闭一个SPI设备 */
func Lua_closeSPI(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))		/* FIXME: 直接使用C_Int进行构造 */
		close_spi(fd)
		return 0
	}
}

@C /* 设置一个SPI设备 */
func Lua_setupSPI(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))	/* FIXME: 直接使用C_Int进行构造1 */
		let mode = UInt8(Lua_checkinteger(L, 2))
		let bits = UInt8(Lua_checkinteger(L, 3))
		let speed = UInt32(Lua_checkinteger(L, 4))
		let delay = UInt16(Lua_checkinteger(L, 5))
		let res: lua_Integer = Int64(setup_spi(fd, mode, bits, speed, delay))	/* FIXME: lua_Integer */
		Lua_pushinteger(L, res)
		return 1
	}
}


@C /* 写SPI设备 */
func Lua_writeSPI(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))			/* FIXME: C_Int */
		let val = UInt8(Lua_checkinteger(L, 2))
		let res: lua_Integer = Int64(write_spi(fd, val))	/* FIXME: lua_Integer */
		Lua_pushinteger(L, res)
		return 1
	}
}


@C /* 读SPI设备 */
func Lua_readSPI(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))		/* FIXME: C_Int */
		let res: lua_Integer = Int64(read_spi(fd))	/* FIXME: lua_Integer */
		Lua_pushinteger(L, res)
		return 1
	}
}

@C /* SPI 一次写 3 字节（单次传输，CS 保持低）
 * 用于 ADS1256 等需要命令序列连续发送的设备。
 *
 * Lua 调用示例（见 modules/ADS1256.lua）：
 *   spi_write3(fd, 0x50, 0x00, 0x03)  -- WREG 写 STATUS 寄存器(0x00) = 0x03
 *   返回值：0 = 成功，-1 = 失败 */
func Lua_spiWrite3(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))
		let b0 = UInt8(Lua_checkinteger(L, 2))
		let b1 = UInt8(Lua_checkinteger(L, 3))
		let b2 = UInt8(Lua_checkinteger(L, 4))
		let buf = LibC.malloc<UInt8>(count: 3)
		(buf + 0).write(b0)
		(buf + 1).write(b1)
		(buf + 2).write(b2)
		let res = libc_write(fd, CPointer<Unit>(buf), 3)
		LibC.free(buf)
		if (res == 3) { Lua_pushinteger(L, 0) }
		else { Lua_pushinteger(L, -1) }
		return 1
	}
}

@C /* SPI 一次读 n 字节（单次传输），返回大端合并值，失败返回 -1。
 *
 * Lua 调用示例（见 modules/ADS1256.lua）：
 *   -- RDATAC 连续模式：CS 拉低即输出当前样本，读 4 字节取前 3（24 位）
 *   local raw = spi_read_multi(fd, 4)
 *   local val = math.floor(raw / 256)  -- 丢弃最后一个填充字节 */
func Lua_spiReadMulti(L: lua_State): C_Int {
	unsafe {
		let fd = Int32(Lua_checkinteger(L, 1))
		var n = Int64(Lua_checkinteger(L, 2))
		if (n < 1 || n > 8) { n = 1 }
		let buf = LibC.malloc<UInt8>(count: n)
		let ret = libc_read(fd, CPointer<Unit>(buf), UIntNative(n))
		if (ret != IntNative(n)) {
			LibC.free(buf)
			Lua_pushinteger(L, -1)
			return 1
		}
		var v: Int64 = 0
		for (i in 0..n) {
			v = (v << 8) | Int64((buf + i).read())
		}
		LibC.free(buf)
		Lua_pushinteger(L, v)
		return 1
	}
}


/*
 * Lua状态机 - 硬件变量
 *
 * TODO(20260612-qing): 提前创建Lua状态机，利用闭包进行引用储存
 *      在rise中申请的资源将在free中被释放。
 *
 *      我们将Lua状态机做成类成员存储，在原本的召集函数中进行初始化
 *      在解构函数中释放资源。
 * 
 */
class MtVars_Lua <: MatrixVars_Hardware {

	/*
	 *  构造函数 => 传入事件函数，硬件构造函数以及硬件解构函数
	 *
	 *  FIXME: 将构造函数设置为 private
	 */
	public init(things!: (JsonValue) -> JsonValue,
			rise!: Option<() -> Unit> = None,
			free!: Option<() -> Unit> = None

	) {  super(things: things, rise: rise, free: free)  }
	

	/* 工厂函数 => 运行指定Lua脚本，传入矩阵中的所有参数（元数据） */
	public static func Factory(luapath: String, getMetadata: ()->JsonObject): MtVars_Lua
	{

		/* 创建LUA状态机对象 */
		let L: lua_State = unsafe {  Lua_init()  }

		/* 检查有没有创建成功？ */
		if ( unsafe { Lua_check(L) } == LUA_ERR) {
			throw IllegalMemoryException("Lua_check()")  }


		let mtVars_Lua = MtVars_Lua(

			/*
			 *  主要事件：调用该硬件的驱动脚本
			 *  合并两张表（json_obj），一张来自创建该硬件时的矩阵（元数据）
			 *  另一张是调用该硬件事件时传入的参数（ @Action ）
			 * 
			 *  其中前者是一些诸如I2C地址、SPI速率的硬件参数
			 *  后者是一些类似舵机旋转角度的实时参数
			 *
			 * TODO(20260825): 事先创建完所有ACTION的行，创建好每一步的参数
			 */
			things: { json: JsonValue =>

				/* 获取元数据 */
				let metadata = getMetadata()

				/*  从元数据（json_obj）进行深拷贝  */
				//let obj = JsonValue.fromStr(metadata.toJsonString()).asObject()
				let obj = metadata
				obj.put("mode", JsonString("call"))

				/*  合并两张（json_obj）表（元数据和参数）  */
				let fields: HashMap<String, JsonValue> = json.asObject().getFields()
				for (k in fields.keys()) {
					let val = fields.get(k).getOrThrow()
					obj.put(k, val)
				}
				println("Lua scripts call parameters: ${obj.toString()}")

				/* 调用Lua解释器 */
				let res = call_lua(L, obj)

				println("Lua script call result: ${res.toString()}")
				return res

			},

			/* 硬件构造方法：提供元数据（json_obj）  对该硬件进行初始化 */
			rise: { =>

				/*  在这里构建Lua状态机   TODO: 使用专用的异常  */
				if (build_lua(L, luapath) == false) {
					throw Exception("Failed to build Lua state from script: '${luapath}'. Please check if the file exists and is valid Lua code.")
				}


				/* 获取元数据 */
				let metadata = getMetadata()

				/* 从元数据进行深拷贝 */
				//let obj = JsonValue.fromStr(metadata.toJsonString()).asObject()
				let obj = metadata

				/* 插入模式指令 （告知lua脚本这是在构建） */
				obj.put("mode", JsonString("build"))
				println("Lua scripts build parameters: ${obj.toString()}")

				/* 开始构建 */
				let res = call_lua(L, obj)

				println("Lua script build result: ${res.toString()}")
			},

			/*
			 *  硬件解构方法：传入元数据（json_obj|json_data）
			 *  然后使用Lua状态机对设备进行关闭（或者重置）
			 */
			free: { =>

				/* 获取元数据 */
				let metadata = getMetadata()

				/*  从元数据进行深拷贝  */
				//let obj = JsonValue.fromStr(metadata.toJsonString()).asObject()
				let obj = metadata

				/*  插入模式指令  */
				obj.put("mode", JsonString("destroy"))
				println("Lua scripts destroy parameters: ${obj.toString()}")

				let res = call_lua(L, obj)

				println("Lua script destroy result: ${res.toString()}")
				/* ---- 在这里写就Lua状态机的解构 ---- */
				destroy_lua(L)

			}

		)


		/*
		 * --------------------------------
		 * 返回构造的硬件变量本体
		 */
		return mtVars_Lua
	}


	/*  构造Lua状态机  申请资源
	 *
	 *  NOTE(20260618-qing): 构建完毕会运行一次 */
	private static func build_lua(L: lua_State, luapath: String): Bool {
		unsafe {
			let filename_c = LibC.mallocCString(luapath)
			if (filename_c.isEmpty()) { throw IllegalMemoryException("LibC.mallocCString()")  }

			/*  加载Lua库、注册Lua函数  */
			Lua_loadlib(L)

			/*  -------- 进程相关 -------- */

			/*  milli_sleep()  */
			var cstr = LibC.mallocCString("milli_sleep")
			Lua_register(L, cstr, Lua_milliSleep)
			LibC.free(cstr)

			/*  -------- I2C设备 -------- */

			/*  i2c_open()  */
			cstr = LibC.mallocCString("i2c_open")
			Lua_register(L, cstr, Lua_openI2c)
			LibC.free(cstr)

			/*  i2c_close()  */
			cstr = LibC.mallocCString("i2c_close")
			Lua_register(L, cstr, Lua_closeI2c)
			LibC.free(cstr)

			/*  i2c_set_addr()  */
			cstr = LibC.mallocCString("i2c_set_addr")
			Lua_register(L, cstr, Lua_setI2cAddr)
			LibC.free(cstr)

			/*  i2c_write_reg()  */
			cstr = LibC.mallocCString("i2c_write_reg")
			Lua_register(L, cstr, Lua_writeI2cReg)
			LibC.free(cstr)

			/*  i2c_read_reg()  */
			cstr = LibC.mallocCString("i2c_read_reg")
			Lua_register(L, cstr, Lua_readI2cReg)
			LibC.free(cstr)

			/*  i2c_write_multi()  */
			cstr = LibC.mallocCString("i2c_write_multi")
			Lua_register(L, cstr, Lua_i2cWriteMulti)
			LibC.free(cstr)

			/*  i2c_read_multi()  */
			cstr = LibC.mallocCString("i2c_read_multi")
			Lua_register(L, cstr, Lua_i2cReadMulti)
			LibC.free(cstr)

			/* -------- SPI --------*/

			/*  spi_open()  */
			cstr = LibC.mallocCString("spi_open")
			Lua_register(L, cstr, Lua_openSPI)
			LibC.free(cstr)

			/*  spi_close()  */
			cstr = LibC.mallocCString("spi_close")
			Lua_register(L, cstr, Lua_closeSPI)
			LibC.free(cstr)

			/*  spi_setsup()  */
			cstr = LibC.mallocCString("spi_setup")
			Lua_register(L, cstr, Lua_setupSPI)
			LibC.free(cstr)

			/*  spi_write()  */
			cstr = LibC.mallocCString("spi_write")
			Lua_register(L, cstr, Lua_writeSPI)
			LibC.free(cstr)

			/*  spi_read()  */
			cstr = LibC.mallocCString("spi_read")
			Lua_register(L, cstr, Lua_readSPI)
			LibC.free(cstr)

			/*  spi_write3()  */
			cstr = LibC.mallocCString("spi_write3")
			Lua_register(L, cstr, Lua_spiWrite3)
			LibC.free(cstr)

			/*  spi_read_multi()  */
			cstr = LibC.mallocCString("spi_read_multi")
			Lua_register(L, cstr, Lua_spiReadMulti)
			LibC.free(cstr)


			/* -------- 设置Lua状态机 -------- */
			var status =  Lua_loadfilex(L, filename_c, CPointer<C_Char>())
			LibC.free(filename_c)			

			if (status == LUA_OK) {
				var status = Lua_pcallk(L, 0, LUA_MULTRET, 0, 0, CPointer<Unit>())
				println("lua build status: ${status}")
				if (status == LUA_OK) { return true  }
			}

			/* -------- 从栈顶获取错误信息 -------- */
			let error_msg = Lua_tostring(L, -1);
			println(error_msg.toString());



			return false
		}
	}

	/*
	 *  释放LUA状态机
	 *
	 *  NOTE(20260618-qing): 销毁之后该变量即废弃
	 */
	private static func destroy_lua(L: lua_State) {
		unsafe { Lua_free(L) }
	}

	/*
	 *  调用Lua脚本的方法
	 *
	 *  NOTE(20260618-qing): 每次调用之后会重置栈指针
	 */
	private static func call_lua(L: lua_State, json: JsonValue): JsonValue {
		let obj = json.asObject()
		let ret = JsonObject()
		unsafe {

			/* ---- 获取栈顶指针  ----*/
			let top  = Lua_gettop(L)

			/* ---- ---- */
			let mode = obj.get("mode").getOrThrow().asString().getValue()
			let cstr = LibC.mallocCString(mode)
			Lua_getglobal(L, cstr)
			LibC.free(cstr)

			/* ----在Lua状态机里 创建Lua表 ---- */				
			Lua_createtable(L, 0, 0)
			

			/* ---- 向Lua表中推入数据 ---- */
			let fields: HashMap<String, JsonValue> = obj.getFields()
			for (k in fields.keys()) {
				let val = fields.get(k).getOrThrow()
				if (val is JsonString) {
					let v = val.asString().getValue()
					let sk = LibC.mallocCString(k)
					let sv = LibC.mallocCString(v)
					Lua_pushstring(L, sv)
					Lua_setfield(L, -2, sk)
					LibC.free(sk)
					LibC.free(sv)
				}
				else if (val is JsonInt) {
					let v = val.asInt().getValue()
					let sk = LibC.mallocCString(k)
					let sv = Int64(v)
					Lua_pushinteger(L, sv)
					Lua_setfield(L, -2, sk)
					LibC.free(sk)
				}
				else if (val is JsonFloat) {
					let v = val.asFloat().getValue()
					let sk = LibC.mallocCString(k)
					Lua_pushnumber(L, v)
					Lua_setfield(L, -2, sk)
					LibC.free(sk)
				}
			}

			var status = Lua_pcallk(L, 1, LUA_MULTRET, 0, 0, CPointer<Unit>())
			println("lua status: ${status}")
			if (status == LUA_OK) {
				if (Lua_type(L, -1) == LUA_TTABLE) {
					/* ---- 栈顶是表  压入 nil 作为遍历的起始键 ---- */
					Lua_pushnil(L)
					while(Lua_next(L, -2) != 0) {
						/* ---- 此时栈：[表, 键, 值]  检查键值是否为空指针 */
						let key = Lua_tostring(L, -2)
						let val = Lua_tostring(L, -1)
						if (key.isEmpty() || val.isEmpty()) {
							throw NoneValueException("Lua_tostring()")
						}
						println("${key}: ${val}")
						ret.put(key.toString(), JsonString(val.toString()))
						Lua_pop(L, 1)
					}
				}
				//Lua_pop(L, 1)
			}

			else if (status != LUA_OK) {
				let err  = Lua_tostring(L, -1)
				if (!err.isEmpty()) { println("Lua 错误详情: ${err.toString()}") }
				//Lua_pop(L, 1)
			}

			/* -------- 恢复Lua状态机 -------- */
			Lua_settop(L, top)
			//Lua_pop(L, 1)
		}
		return ret
	}
}

/*  别名变量（硬件类型）
 *  这种变量用于给某个参数取一个更简单的别名  它的事件返回（JsonString）将作为新的矩阵项目值
 */
class MtVars_Alias <: MatrixVars_Hardware {
	public init(things!: (JsonValue) -> JsonValue,
			rise!: Option<() -> Unit> = None,
			free!: Option<() -> Unit> = None  )
	{  super(things: things, rise: rise, free: free)  }

	public static func Factory(AliasDefs: MatrixObject, i: Int64,
			_: HashMap<String, MatrixVars_Hardware>): MtVars_Alias
	{
		let idxName = AliasDefs.indexOfCol(0, "name")
		let idxAlias= AliasDefs.indexOfCol(0, "alias")

		let name = AliasDefs[i, idxName]
		let alias= getMt(AliasDefs, i, idxAlias)

		println("Create a Alias vars: ${name}, witch means ${alias}")
		let mtvars_alias = MtVars_Alias(things: {_: JsonValue =>
			let str = JsonString(alias)	/*  直接返回JsonString（alias）*/
			return str
		})

		return mtvars_alias
	}
}

/*
 *  I2C变量类 这种硬件变量是特殊且固定的
 *  TODO(20260617-qing): 等LUA状态机被闭包保存之后，将其优化为Lua驱动
 */
//class MtVars_I2C <: MatrixVars_Hardware {
//	public init(things!: (JsonValue) -> JsonValue,
//			rise!: Option<() -> Unit> = None,
//			free!: Option<() -> Unit> = None  )
//
//	{  super(things: things, rise: rise, free: free)  }
//
//	/*  @I2C
//	 *   name        path;
//	 *  i2c-0  /dev/i2c-0;
//	 *  @
//	 */
//	public static func Factory(	/*  工厂模式，根据矩阵对象构造  */
//		I2CDefs: MatrixObject, i: Int64, _: HashMap<String, MatrixVars_Hardware>): MtVars_I2C
//	{
//		let idxName  = I2CDefs.indexOfCol(0, "name")
//		let idxPath  = I2CDefs.indexOfCol(0, "path")
//
//		let name = I2CDefs[i, idxName]
//		let path = getMt(I2CDefs, i, idxPath)
//
//		println("Create a I2C hard-Var: ${name},\tpath: ${path}")	/* ---- debug ---- */
//		let i2c = I2C_Orig(path)	/*  在这里创建传统I2C类对象，通过闭包保存在MtVars_I2C里  */
//		let mtvars_i2c = MtVars_I2C(
//			things: { json: JsonValue =>
//				let fd = i2c.getFd()
//				let ret = JsonObject()
//				ret.put("fd",JsonInt(Int64(fd)))
//				return ret
//			},
//
//			free: {=>
//				println("I2C HVar: ${name} is closing now")
//				i2c._close()
//			})
//
//		return mtvars_i2c
//	}
//}

/*  MPU6050_BIND硬件变量
 *  INFO(20260612-qing): 自从引入了Lua状态机扩展硬件，该硬件变量不知道何去何从。
 *  TODO(20260612-qing): 在Lua脚本中定义好BIND函数后，在pthread线程中反复调用
 * -------- */
//class MtVars_MPU6050_BIND <: MatrixVars_Hardware {
//	public init(things!: (JsonValue) -> JsonValue,
//			rise!: Option<() -> Unit> = None,
//			free!: Option<() -> Unit> = None) {
//		super(things: things, rise: rise, free: free)  }
//
//	/* 工厂函数，通过矩阵对象构建硬件变量
//	 * @MPU6050_BIND
//	 *      name    I2C   addr;
//	 * mpu6050-0  i2c-1   0x69;
//	 */
//	public static func Factory (
//			MPU6050_BIND_Defs: MatrixObject, i: Int64,
//			map: HashMap<String, MatrixVars_Hardware>)//: MtVars_MPU6050_BIND
//	{
//		let idxName = MPU6050_BIND_Defs.indexOfCol(0, "name")
//		let idxI2c  = MPU6050_BIND_Defs.indexOfCol(0, "I2C")
//		let idxAddr = MPU6050_BIND_Defs.indexOfCol(0, "addr")
//
//		let name = MPU6050_BIND_Defs[i, idxName]
//		let i2c  = getMt(MPU6050_BIND_Defs, i, idxI2c)
//		let addr = getMt(MPU6050_BIND_Defs, i, idxAddr)
//
//		println("Create a MPU6050_BIND HVar: ${name}, use i2c interf: ${i2c}, i2c addr: ${addr}")
//		let i2c_HardVar = map[i2c]
//		let param = JsonObject()
//		param.put("mode", JsonString("get_fd"))
//		let ret = i2c_HardVar.play(param)
//		let fd = Int32(ret.asObject().get("fd").getOrThrow().asInt().getValue())
//		let _addr = UInt8.parse(addr)
//
//		let mpu6050 = MPU6050(fd, _addr)		
//
//		let mtvars_mpu6050bind = MtVars_MPU6050_BIND(
//			things: {json: JsonValue => 
//				let ret = JsonObject()
//				ret.put("status", JsonString("OK"))
//				return ret
//			},
//			rise: {=>
//				println("MPU6050_BIND HVar: ${name} is starting now")
//				mpu6050.setup()
//				mpu6050.startDaemon()
//			},
//			free: {=>
//				println("MPU6050_BIND HVar: ${name} is closing now")
//				mpu6050.stopDaemon()
//				mpu6050.waitDaemon()
//			}
//		)
//
//		return mtvars_mpu6050bind
//	}
//}

/*  舵机变量类
 *  
 *  TODO(20260515-qing): 现在普通的舵机类也是传入回调函数的，
 *  但是我们考虑到该硬件变量调用别的硬件变量，所以还是要专门做一个舵机硬件变量
 * 
 *  TODO（20260612-qing): 根据Lua硬件脚本的返回结果，调用别的硬件变量
 */
class MtVars_Servo <: MatrixVars_Hardware {
	public init(things!: (JsonValue) -> JsonValue,
			rise!: Option<() -> Unit> = None,
			free!: Option<() -> Unit> = None  )
		{  super(things: things, rise: rise, free: free)  }

	/*
	 *  @Servo
	 *  name   max  min  offset  controller  channel;
	 *    s1    90    -       -   pca9685-0        0;
	 *  @
	 */
	public static func Factory(	/* 工厂模式：使用矩阵对象构造 */
		ServoDefs: MatrixObject, i: Int64, map: HashMap<String, MatrixVars_Hardware>)//: MtVars_Servo
	{
		let idxName = ServoDefs.indexOfCol(0, "name")
		let idxMax = ServoDefs.indexOfCol(0, "max")
		let idxMin = ServoDefs.indexOfCol(0, "min")
		let idxOffset = ServoDefs.indexOfCol(0,"offset")
		let idxCtrl = ServoDefs.indexOfCol(0, "controller")
		let idxChannel = ServoDefs.indexOfCol(0, "channel")

		let name = ServoDefs[i, idxName]
		let max = parseMt<Float32>(ServoDefs, i, idxMax)
		let min = parseMt<Float32> (ServoDefs,i, idxMin)
		let offset = parseMt<Float32>(ServoDefs, i, idxOffset)
		let ctrl = getMt(ServoDefs, i, idxCtrl)
		let channel = parseMt<UInt8>(ServoDefs, i, idxChannel)

		print("Create a Servo hard-Var: ${name}, max: ${max}, min: ${min}, offset: ${offset}")
		println(", controller: ${ctrl}, channel: ${channel}")

		let controller = map[ctrl]	/* like pca9685 */
		let servo = Servo(max: max, min: min, offset: offset,
			callback_setAngle: {angle: Float32 =>
				let obj = JsonObject()
				obj.put("channel", JsonInt(Int64(channel)))
				//obj.put("angle", JsonFloat(Float64(angle)))
				obj.put("angle", JsonInt(Int64(angle)))
				controller.play(obj)
		})

		/*
		 * {"angle": 180.0}
		 */
		let mtvars_servo = MtVars_Servo(things: {json=>
				let angle = json.asObject().get("angle").getOrThrow().asFloat().getValue()
				servo.setAngle(Float32(angle))
				let ret = JsonObject()
				ret.put("status", JsonString("OK"))
				return ret
		})
		return mtvars_servo
	}
}

/*
 * 扬声器类
 * 
 * 使用工厂函数
 * 
 * TODO: 输入扬声器设备名，扬声器又是一个复杂的功能
 * 
 */
class MtVars_Speaker <: MatrixVars_Hardware {
	public init(things!: (JsonValue) -> JsonValue,
			rise!: Option<() -> Unit> = None,
			free!: Option<() -> Unit> = None  )
		{  super(things: things, rise: rise, free: free)  }

	/*
	 *  工厂函数，根据矩阵对象进行构造
	 *  @Speaker
	 *  name  channels  sample_rate  volumn  max_f  min_f;
	 *   spk         2        48000     0.6   5000      -;
	 *  @
	 */
	public static func Factory(
		SpeakerDefs: MatrixObject, i: Int64, map: HashMap<String, MatrixVars_Hardware>): MtVars_Speaker {

		let idxName = SpeakerDefs.indexOfCol(0, "name")
		let idxChannels = SpeakerDefs.indexOfCol(0, "channels")
		let idxSampleRate = SpeakerDefs.indexOfCol(0, "sample_rate")
		let idxVolumn = SpeakerDefs.indexOfCol(0, "volumn")
		let idxMax_f = SpeakerDefs.indexOfCol(0, "max_f")
		let idxMin_f = SpeakerDefs.indexOfCol(0, "min_f")

		let name = SpeakerDefs[i, idxName]
		let channels = parseMt<Int32>(SpeakerDefs, i, idxChannels)
		let sample_rate = parseMt<Int32>(SpeakerDefs, i, idxSampleRate)
		let volume = parseMt<Float64>(SpeakerDefs, i, idxVolumn)
		let max_f = parseMt<Float32>(SpeakerDefs, i, idxMax_f)
		let min_f = parseMt<Float32>(SpeakerDefs, i, idxMin_f)

		println("Create a Speaker: ${name}, channels: ${channels}, sample_rate: ${sample_rate}, volume: $(volume), max_f: ${max_f}, min_f: ${min_f}")		
		let spk = Spk(channels: channels, sample_rate: sample_rate)
		let mtvar_spk = MtVars_Speaker(things: {json =>		// {"frequency": 1000.0, "delay": 400}
			let json_obj = json.asObject()
			var freq  = Float32(json_obj.get("frequency").getOrThrow().asFloat().getValue())
			if (freq > max_f) { freq = max_f }
			if (freq < min_f) { freq = min_f }
			let delay  = Int32(json_obj.get("delay").getOrThrow().asFloat().getValue())
			spk.play(freq, volume, delay)
			let ret = JsonObject()	/* ---- FIXME: 处理异常情况 */
			ret.put("status", JsonString("OK"))
			return ret
		})

		return mtvar_spk
	}
}



/* 机器人结构类
 * 
 * 机器人结构是动态的，从脚本中解析的 
 * TODO(20260514-qing): 调整为输入MatrixObject
 * TODO(20260515-qing): 需要重写一遍硬件类
 * TODO(20260518-qing): 使用神经网络RNN直接根据动作+传感器脚本生成下一步动作
 * TODO(20260527-qing): 增加硬件模块行为脚本
 * TODO*(20260527-qing): 为@Action表演矩阵对象增加位置指示器，以增量行动
 *
 * INFO(20260826-qing): 机器人结构类对象，接受输入流，随后逐个解析存入链表
 */
class RobotStruct {

	/* -------- 存放解析结果和创建的变量 -------- */
	private let C = LinkedList<MatrixObject>()
	private let M = HashMap<String, MatrixVars_Hardware>() 

	/*
	 *  使用矩阵脚本驱动机器人
	 * 
	 *  不行就将矩阵脚本转化为bot脚本吧
	 */
	public init(input: InputStream) {
		readMatrix(input)
		createHardVars()
	}

	/* -------- 激活所有硬件变量 -------- */
	public func  active() {
		for (item in M.values()) {
			item.build()
		}
	}

	/*
	 *  消除所有硬件变量
	 * 
	 *  INFO(20260517-qing): 它需要以倒序方式进行清除
	 */
	public func deactive() {
		let items = M.values().toArray()
		for (i in items.size-1..=0:-1) {
			items[i].destroy()
		}
	}

	/* -------- 执行@Action矩阵中的内容 -------- */
	public func run() {
		run_drl_action()
	}

	/*
	 *  储存整个矩阵变量表
	 * 
	 *  NOTE(20260517-qing): 使用完毕要关闭输出流
	 */
	public func save(out: OutputStream) {
		let ms = MatrixSaver(out)
		ms.save(C)
	}

	/*
	 *  阅读矩阵脚本
	 * 
	 *  TODO(20260504-qing): 使用矩阵脚本存储神经网络模型
	 */
	private func readMatrix(file: InputStream){
		let sr = StringReader<InputStream>(file)
		let parser =  MatrixParser(sr)
		while (true) {
			if (let Some(O) <- parser.parse()) {
				let n = O.getName();
				println(n)
				C.addLast(O)  }
			else { break }
		}
	}

	/*
	 *  创建硬件变量字典
	 * 
	 *  TODO(20260515-qing): 解耦合  
	 *  FIXME(20260518-qing): 在插入哈希表之前如果有已经存在的键值，要释放它的资源
	 */
	private func createHardVars()
	{

		for (matrix in C) {
			let MtName = matrix.getName()

			/* ---- 【特殊的】I2C硬件
			 * ---- */
			//if (MtName == "I2C") {
			//	let idxName = matrix.indexOfCol(0,"name")
			//	for (i in 1..matrix.size) {
			//		let name = matrix[i, idxName]
			//		M[name] = MtVars_I2C.Factory(matrix, i, M)
			//	}
			//}

			/* ---- 【特殊的】Alias别名硬件
			 * ---- */
			if (MtName == "Alias") {
				let idxName =  matrix.indexOfCol(0, "name")
				for (i in 1..matrix.size) {
					let name =  matrix[i, idxName]
					M[name] = MtVars_Alias.Factory(matrix, i, M)
				}
			}

			/* ---- 【特殊的】Servo舵机硬件
			 * ---- */
			else if (MtName == "Servo") {
				let idxName = matrix.indexOfCol(0, "name")
				for (i in 1..matrix.size) {
					let name = matrix[i, idxName]
					M[name] = MtVars_Servo.Factory(matrix, i, M)
				}
			}

			/* ---- [特殊的] Action矩阵
			 * ---- */
			else if (MtName == "Action") {
				;
			}

			/* ---- [特殊的] Speaker扬声器硬件 ---- */
			else if (MtName == "Speaker") {
				let idxName = matrix.indexOfCol(0, "name")
				for (i in 1..matrix.size) {
					let name = matrix[i, idxName]
					M[name] = MtVars_Speaker.Factory(matrix, i, M)
				}
			}

			/* ---- 【通用的】Lua脚本硬件 ---- */
			else if (matrix.size > 0) {
				let idxName = matrix.indexOfCol(0, "name")
				for (i in 1..matrix.size ) {
					let name = matrix[i, idxName]
					/* ---- 从环境变量 BOT4CJ_MODULE_PATH 获取模块路径，默认为 ./modules ---- */
					let modulePath = std.env.getEnv("BOT4CJ_MODULE_PATH").getOr("./modules")
					let scriptPath = "${modulePath}/${MtName}.lua"
					M[name] = MtVars_Lua.Factory(scriptPath, {=>
							this._getMetadata(matrix, i)
					})
				}
		}
		}
	}


	/* -------- 在矩阵对象的容器中寻找目标 -------- */
	private static func findMt(ll: LinkedList<MatrixObject>, name: String): Option<MatrixObject>
	{
		for (item in ll) {
			var target  = item.getName()
			target = target.trimAscii() // ???
			if (name == target) {
				return item  }
		}

		return None
	}

	/* -------- 使用drl微调动作，使用RNN生成动作流 -------- */
	private func run_drl_action() {
		let ActionDefsOpt = findMt(C, "Action")
		if (let None <- ActionDefsOpt) {
			throw IllegalArgumentException("No @Action matrix found in script. Please define action matrix in your .mt file.")
		}
		let ActionDefs = ActionDefsOpt.getOrThrow()
		for (i in 1..ActionDefs.size) {
			let set =JsonObject()		/* 每个硬件变量的参数集合 */
			for (j in 0..ActionDefs.col) {
				parse_action_matrixObject(set, ActionDefs, i, j)
			}

			/* -------- 执行一行 -------- */
			let keys = set.getFields().keys()
			for (name_dev in keys) {
				let hvOpt = M.get(name_dev)
				if (let None <- hvOpt) {
					throw IllegalArgumentException("Hardware variable '${name_dev}' is used in @Action but not defined in hardware declaration section.")
				}
				let hv = hvOpt.getOrThrow()
				let paramsOpt = set.get(name_dev)
				if (let None <- paramsOpt) {
					throw IllegalArgumentException("Parameter for hardware variable '${name_dev}' is missing in action row ${i}.")
				}
				let params: JsonValue = paramsOpt.getOrThrow()
				let _: JsonValue = hv.play(params)
			}


		}
	}

	/* -------- 解析@Action矩阵对象 -------- */
	private func parse_action_matrixObject(set: JsonObject, ActionDefs: MatrixObject,
			i: Int64, j: Int64) {
		let name_HV = ActionDefs[0, j]	/* 获取硬件变量名 FIXME:  该名称不得使用占位符 且不重复 */
		let arr = name_HV.split(".")
		if (arr.size != 2) {
			throw IllegalArgumentException("Action column is not valid")  }
		let name_dev = arr[0]
		var name_param = arr[1]

		var val_fp64 = MatrixVars_Hardware.parseMt<Float64>(ActionDefs, i, j)

		let AliasHV = M.get(name_param)		/* 可能的参数别名转换 */
		if (let Some(aliasHV) <- AliasHV) {
			let ret = aliasHV.play(JsonObject())
			let alias = ret.asString().getValue()
			name_param = alias
		}

		var set_params: JsonObject	/* 设置或者取得属于该硬件变量的参数 */
		if (let Some(obj_) <- set.get(name_dev)) {
			set_params = obj_.asObject()  }
		else {
			set_params = JsonObject()
			set.put(name_dev, set_params)  }

		set_params.put(name_param, JsonFloat(val_fp64))	/* 设置一个该硬件变量的参数 */
	}

	private func _getMetadata(matrix: MatrixObject, i: Int64): JsonObject {
		let obj = JsonObject()
		let idxName = matrix.indexOfCol(0, "name")
		let name = matrix[i, idxName]
		for (j in 0..matrix.col) {
			let colName = matrix[0, j]
			let value = MatrixVars_Hardware.getMt(matrix, i, j)
			/* ---- ----
			 * ---- FIXME: 加入点号别名的检索逻辑 ----
			 * ---- ---- */
			if (j == idxName) { continue  } /* 自身调用警告 */
			if (let Some(mt) <- M.get(value)) {
				/* ---- ----
				 * ---- 存在该名称的变量，传入空对象参数，并求取返回值
				 * ---- ---- */
				let json = JsonObject()
				let res = mt.play(json).asObject()
				let fields: HashMap<String, JsonValue> = res.getFields()
				for (k in fields.keys()) {
					let val = fields.get(k).getOrThrow()
					obj.put(k, val)
				}
					
			}
			else {
				obj.put(colName, JsonString(value))
			}
		}

		return obj
		
	}


}


