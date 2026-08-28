
/* TODO(20260518-qing):  稍后我们专门做一个i2c代码仓库，这样就能够区分不同架构上面的int的大小
 * TODO(20260615-qing):  有没有可能只做一个简单的封装不引入异常机制  */

package bot4cj.hd
import pthread4cj.*
import ctype4cj.*

/* -------- 我们将直接调用glibc中的一些函数 -------- */
foreign func ioctl(fd: C_Int, addr: C_ULong, ...): C_Int				/* -------- 成功返回非负整数，失败返回-1 -------- */

const I2C_FAILED = -1i32	/* -------- I2C关闭文件失败 -------- */
const I2C_SUCCESS = 0i32	/* -------- I2C关闭文件成功 -------- */
const I2C_SLAVE = 0x0703u64	/* -------- at least on arm64 -------- */

/* -------- OPEN I2C DEVICE 打开I2C设备  -------- */
@C
public func openI2cDev(path: CString): Int32 {
	unsafe {
		let fd =  libc_open(path, O_RDWR)
		if (fd >= 0) { 
			I2cLock_create(fd)	/* -------- 为I2C设备创建锁 -------- */
			return  fd
		}
		else {
			throw I2cOpenedFailed("?")
		}
	}
}

/* ---- 简化版，判断在外部实现 ---- */
@C
public func openI2cDev1(path: CString): C_Int {
	unsafe {
		let fd = libc_open(path, O_RDWR)
		I2cLock_create(fd)
		return fd
	}
}

/* -------- CLOSE I2C DEVICE 关闭I2C设备 -------- */
@C
public func closeI2cDev(fd: Int32): Unit {
	unsafe {
		I2cLock_destroy(fd)	/* -------- 销毁I2C设备的锁 -------- */
		let ret = libc_close(fd)
		if (ret == I2C_FAILED) {
			throw I2cClosedFailed("?") }
		else if (ret == I2C_SUCCESS) { ;  }
		else {
			throw I2cUnknowExp(
				"?", "$function returned: {ret.toString()}")
		}
	}
}

@C
public func closeI2cDev1(fd: C_Int): Unit {
	unsafe {
		I2cLock_destroy(fd)
		libc_close(fd)
	}
}

/* -------- SET I2C ADDR 设置I2C地址 -------- */
@C
public func setI2cAddr(fd: Int32, addr: UInt8): Unit {
	unsafe {
		let ret = ioctl(fd, I2C_SLAVE, addr)
		if (ret < 0) {
			throw I2cSetAddressFailed("?") }
	}
}

@C
public func setI2cAddr1(fd: C_Int, addr: UInt8): C_Int {
	unsafe {
		return ioctl(fd, I2C_SLAVE, addr)
	}
}

/* -------- WRITE I2C REG 写I2C寄存器 -------- */
@C
public func writeI2cReg(fd: Int32, reg: UInt8, val:UInt8): Unit {
	var a: VArray<UInt8, $2> = [reg, val]
	var p: CPointer<Unit> = unsafe { CPointer<Unit>(inout a) }
	if (2 !=  unsafe { libc_write(fd, p, 2) }) {
		throw I2cWriteRegFailed("?")
	}
}

/* -------- READ I2C REG 读I2C寄存器 --------
 * INFO(20260522-qing): 读取寄存器之前要先写寄存器地址
 * INFO(20260616-qing): 这个函数只读取一个字节的数据
 * -------- */
@C
public func readI2cReg(fd: Int32, reg: UInt8): Int8 {
	var ptr = reg
	if (1 != unsafe { libc_write(fd, CPointer<Unit>(inout ptr), 1) }) {
		throw I2cReadRegFailed("?")
	}
	var value: Int8 = 0
	var p = unsafe { CPointer<Unit>(inout value) }
	let ret = unsafe { libc_read(fd, p, 1) }
	if (ret != 1) { throw I2cReadRegFailed("?") }
	return value
}


/* -------- I2C锁具 --------
 * INFO(20260521-qing): 因为每个I2C接口在通信时具有原子化的需求
 * - 需要一个互斥锁集合，在打开第一个I2C设备时被初始化，
 * - 释放最后一个I2C设备时，将锁具释放
 * - **每次进行I2C通信时，进行上锁操作**   */
@C
struct I2C_Lock {
	var i2c_fd: Int32 = 0		/* -------- 这个锁绑定的I2C设备文件句柄 -------- */
	var lock = CPointer<UInt8>()	/* -------- phread_mutex_t 锁对象 -------- */
	var is_active = false		/* -------- 该锁具是否被激活 --------*/
}


var MAIN_LOCK = CPointer<UInt8>()	/* -------- 主锁，操作锁具时使用 -------- */
var LOCKS = CPointer<I2C_Lock>()	/* -------- 指向锁具内存的指针 -------- */
const LOCKS_SIZE: Int64 = 20		/* -------- 锁具的容量 --------*/

/* -------- 为一个I2C设备注册锁具 -------- */
@C
func I2cLock_create(fd: Int32): Unit {
	unsafe {
		/* -------- 初始化主要的锁 -------- */
		if (MAIN_LOCK.isNull()) {
			MAIN_LOCK = _mutex_create()
			_mutex_init(MAIN_LOCK)	/* -------- 主锁必须先初始化再使用 -------- */
			LOCKS = LibC.malloc<I2C_Lock>(count: LOCKS_SIZE)
			for (i in 0..LOCKS_SIZE) {
				let tmp = I2C_Lock()
				(LOCKS+i).write(tmp)
			}
		}

		/* -------- 获取主锁 --------*/
		_mutex_lock(MAIN_LOCK)
		var flag = false

		for (idx in 0..LOCKS_SIZE) {
			var lock = (LOCKS+idx).read()
			if (lock.is_active == false) {
				lock.is_active = true
				lock.i2c_fd = fd
				lock.lock = _mutex_create()
				_mutex_init(lock.lock)
				(LOCKS+idx).write(lock)
				flag = true
				break
			}
		}

		_mutex_unlock(MAIN_LOCK)
		if (flag ) { return }	/* -------- 出口 -------- */
		throw OverflowException("LOCKS is over.")
	}
}
/* -------- 为一个I2C设备注销锁具 -------- */
@C
func I2cLock_destroy(fd: Int32): Unit {
	unsafe {
		/* -------- 检查锁具有没有被初始化 --------*/
		if (MAIN_LOCK.isNull()) {
			throw NoneValueException("no i2c lock")
		}
		_mutex_lock(MAIN_LOCK)

		var flag_any = false
		var flag_target = false
		for (idx in 0..LOCKS_SIZE) {
			var lock = (LOCKS+idx).read()
			if (lock.is_active == true && lock.i2c_fd == fd) {
				lock.is_active = false
				_mutex_destroy(lock.lock)
				_mutex_free(lock.lock)
				(LOCKS+idx).write(lock)
				flag_target = true
				/* -------- NOTE: 扫描整个锁具不终止 -------- */
			}
			else if (lock.is_active == true && lock.i2c_fd != fd) {
				flag_any = true
			}
		}


		_mutex_unlock(MAIN_LOCK)

		/* -------- 如果锁具里已经没有I2C锁， 就释放整个锁具 --------  */
		if (!flag_any) {
			LibC.free(LOCKS)
			_mutex_destroy(MAIN_LOCK)	/* -------- 与 _mutex_init 成对 -------- */
			_mutex_free(MAIN_LOCK)
			MAIN_LOCK = CPointer<UInt8>()
		}

		/* -------- 出口  -------- */
		if (flag_target) {
			return  }


		throw NoneValueException("i2c lock not found")
	}
}

/* -------- 为一个I2C锁具加锁 -------- */
@C
func I2cLock_lock(fd: Int32): Unit {
	unsafe {
		if (MAIN_LOCK.isNull()) {
			throw NoneValueException("no i2c lock")
		}

		_mutex_lock(MAIN_LOCK)

		var flag = false
		for (idx in 0..LOCKS_SIZE) {
			var lock = (LOCKS+idx).read()
			if (lock.is_active == true && lock.i2c_fd == fd) {
				_mutex_lock(lock.lock)
				(LOCKS+idx).write(lock)
				flag = true
				break
			}
		}

		_mutex_unlock(MAIN_LOCK)
		if (flag) { return } 
		throw NoneValueException("i2c lock not found")
	}
}

/* -------- 为一个I2C锁具解锁 -------- */
@C
func I2cLock_unlock(fd: Int32): Unit {
	unsafe {
		if (MAIN_LOCK.isNull()) {
			throw NoneValueException("no i2c lock")
		}
		_mutex_lock(MAIN_LOCK)

		var flag = false
		for (idx in 0..LOCKS_SIZE) {
			var lock = (LOCKS+idx).read()
			if (lock.is_active == true && lock.i2c_fd == fd) {
				_mutex_unlock(lock.lock)
				(LOCKS+idx).write(lock)
				flag = true
				break
			}
		}
		_mutex_unlock(MAIN_LOCK)
		if (flag) {return}
		throw NoneValueException("i2c lock not found")
	}
}


/* -------- 原生I2C通信类--------
 * INFO(20260521-qing): 直接调用glibc的接口 */
public class I2C_Orig {
	private var fd: Int32 = -1
	private var path: String
	public init (path: String) {
		this.path = path
		let s1 = unsafe { 
			LibC.mallocCString(path) }
		fd = unsafe { openI2cDev(s1) }
	}

	public func _close(): Unit {
		unsafe { closeI2cDev(fd) }
	}

	public func setAddr(addr: UInt8) {
		unsafe {  setI2cAddr(fd, addr)  }
	}

	public func writeReg(reg: UInt8, val:UInt8): Unit {
		unsafe { writeI2cReg(fd, reg, val) }
	}

	public func readReg(reg: UInt8): Int8 {
		var value = unsafe { readI2cReg(fd, reg) }
		return value
	}

	/*--------获取文件句柄--------*/
	public func getFd(): Int32 {
		return fd
	}

}


/* -------- I2C设备异常 -------- */
open private class I2cExcept <: Exception {
	public I2cExcept(dev: String, msg: String) {
		super('${dev}: ${msg}')  }
}

/* -------- 打开I2C设备失败 -------- */
private class I2cOpenedFailed <: I2cExcept {
	public I2cOpenedFailed(dev: String) {
		super(dev, "failed to open i2c device")  }
}

/* -------- 关闭I2C设备失败 -------- */
private class I2cClosedFailed <: I2cExcept {
	public I2cClosedFailed(dev: String) {
		super(dev, "failed to close i2c device")  }
}

/* -------- I2C设置地址失败 -------- */
private class I2cSetAddressFailed <: I2cExcept {
	public I2cSetAddressFailed(dev: String) {
		super(dev, "failed to set i2c address")  }
}

/* -------- I2C写从机I2C失败 -------- */
private class I2cWriteRegFailed <: I2cExcept {
	public I2cWriteRegFailed(dev: String) {
		super(dev, "failed to write i2c reg")  }
}

/* -------- I2C读从机I2C失败 -------- */
private class I2cReadRegFailed <: I2cExcept {
	public I2cReadRegFailed(dev: String) {
		super(dev, "failed to read i2c reg")  }
}

/* -------- 未知I2C异常 -------- */
private class I2cUnknowExp <: I2cExcept {
	public I2cUnknowExp(dev: String, msg: String) {
		super(dev, msg)  }
}
