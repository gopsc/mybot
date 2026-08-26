/* ----------------
 * MPU6050陀螺仪与加速度计模块
 * -
 * TODO(20260516-qing): 陀螺仪需要卡尔曼滤波、通过四元数等方式获取姿态角
 * -  所以应该使用一个C/C++线程来持续地采样，并且留一个接口进行获取
 */

package bot4cj.hd
import std.time.*
import std.math.*
import pthread4cj.*
import bot4cj.math.*
    
const ADDR_0:           UInt8 = 0x68  /* 默认地址 */
const ADDR_1:           UInt8 = 0x69  /* 地址2（AD0接高电平） */
const PWR_MGMT_1:       UInt8 = 0x6B  /* 电源管理寄存器1 */
const PWR_NOSLEEP:      UInt8 = 0x00  /* 电源管理 - 非睡眠模式 */
const GYRO_CONF_REG:    UInt8 = 0x1B  /* 陀螺仪配置寄存器 */
const GYRO_FS_500DPS:   UInt8 = 0x08  /* 陀螺仪量程 - 正负500度/秒 */
const GYRO_REG_X_HIGH:  UInt8 = 0x43  /* x - 陀螺仪横轴 高字节 */
const GYRO_REG_X_LOW:   UInt8 = 0x44
const GYRO_REG_Y_HIGH:  UInt8 = 0x45  /* y */
const GYRO_REG_Y_LOW:   UInt8 = 0x46
const GYRO_REG_Z_HIGH:  UInt8 = 0x47  /* z */
const GYRO_REG_Z_LOW:   UInt8 = 0x48
const ACCEL_CONF_REG:   UInt8 = 0x1C  /* 加速度计配置寄存器 */
const ACCEL_FS_8g:      UInt8 = 0x10  /* 加速度计量程 正负8g */
const ACCEL_REG_X_HIGH: UInt8 = 0x3B
const ACCEL_REG_X_LOW:  UInt8 = 0x3C
const ACCEL_REG_Y_HIGH: UInt8 = 0x3D
const ACCEL_REG_Y_LOW:  UInt8 = 0x3E
const ACCEL_REG_Z_HIGH: UInt8 = 0x3F
const ACCEL_REG_Z_LOW:  UInt8 = 0x40

/* -------- MPU6050传感器数据 -------- */
@C
public struct MPU6050_sensorData {
	public var accel_x: Int16 = 0 /* 加速度计 */
	public var accel_y: Int16 = 0
	public var accel_z: Int16 = 0
	public var gyro_x:  Int16 = 0 /* 陀螺仪 */
	public var gyro_y:  Int16 = 0
	public var gyro_z:  Int16 = 0
	public func print() {  /* 格式化打印 */
		println("[accel x, y, z] ${accel_x}, ${accel_y}, ${accel_z}")
		println("[gyro  x, y, z] ${gyro_x},  ${gyro_y},  ${gyro_z}")
		println("--------------------")
	}
}


/* -------- 设置MPU6050 -------- */
@C
func mpu6050_setup(i2c_fd: Int32, addr: UInt8) {
	unsafe {
		I2cLock_lock(i2c_fd)
		setI2cAddr(i2c_fd, addr);
		sleep(Duration.millisecond * 1)
		writeI2cReg(i2c_fd, PWR_MGMT_1, PWR_NOSLEEP);		/* 退出睡眠 */
		writeI2cReg(i2c_fd, GYRO_CONF_REG, GYRO_FS_500DPS);	/* ±500°/s */
		writeI2cReg(i2c_fd, ACCEL_CONF_REG, ACCEL_FS_8g);	/*  ±8g */
		I2cLock_unlock(i2c_fd)
		sleep(Duration.millisecond * 100);			/* 等待稳定 */
	}
}

@C
/* -------- 读取 16 位传感器数据（带符号）--------
 * INFO(20260826): 高低字节先掩码拼接为无符号16位，再截断为Int16按补码解释 */
func read16BitReg(i2c_fd: Int32, high: UInt8, low: UInt8): Int16 {
	unsafe {
		let h: Int32 = Int32(readI2cReg(i2c_fd, high)) & 0xFF
		let l: Int32 = Int32(readI2cReg(i2c_fd, low)) & 0xFF
		return Int16((h << 8) | l)
	}
}

/* -------- 读取传感器数据 -------- */
@C
func mpu6050_readSensor(i2c_fd: Int32, addr: UInt8) {
		var data = MPU6050_sensorData()
		
		unsafe {
			I2cLock_lock(i2c_fd)
			setI2cAddr(i2c_fd, addr) 
			data.accel_x = read16BitReg(i2c_fd, ACCEL_REG_X_HIGH, ACCEL_REG_X_LOW);
			data.accel_y = read16BitReg(i2c_fd, ACCEL_REG_Y_HIGH, ACCEL_REG_Y_LOW);
			data.accel_z = read16BitReg(i2c_fd, ACCEL_REG_Z_HIGH, ACCEL_REG_Z_LOW);
			data.gyro_x  = read16BitReg(i2c_fd, GYRO_REG_X_HIGH, GYRO_REG_X_LOW);
			data.gyro_y  = read16BitReg(i2c_fd, GYRO_REG_Y_HIGH, GYRO_REG_Y_LOW);
			data.gyro_z  = read16BitReg(i2c_fd, GYRO_REG_Z_HIGH, GYRO_REG_Z_LOW);
			I2cLock_unlock(i2c_fd)
		}
		return data 
}


/* -------- 计算PITCH角 -------- */
//@C
//func mpu6050_calcPitch()

/* -------- mpu6050主线程 -------- 
 * TODO(20260525-qing): 使用互补滤波就够用了  */
const RAD_TO_DEG = 57.2956f32	/* ---- 弧度转换为角度的系数（180/π ≈ 57.2956） ---- */
//foreign func pthread_testcancel(): Unit
@C
func mpu6050_main(args: CPointer<Unit>): CPointer<Unit> {

	/* -------- 获取传入线程的参数 -------- */
	let param  =  unsafe{ CPointer<mpu6050_th_param>(args).read() }

	/* -------- 为加速度计准备滤波器组 -------- */
	var kalman_accel_x = extKalman(20.0f32, 200.0f32)
	var kalman_accel_y = extKalman(20.0f32, 200.0f32)
	var kalman_accel_z = extKalman(20.0f32, 200.0f32)

	/* -------- 为陀螺仪准备滤波器组 -------- */
	var kalman_gyro_x = extKalman(20.0f32, 200.0f32)
	var kalman_gyro_y = extKalman(20.0f32, 200.0f32)
	var kalman_gyro_z = extKalman(20.0f32, 200.0f32)


	while(true) {

		//unsafe { _mutex_lock(mutex) }

		/* -------- 获取传感器数据 -------- */
		var data = unsafe { mpu6050_readSensor(param.i2c_fd, param.addr) }

		/* -------- 为加速度计执行滤波操作 -------- */
		let filtered_accel_x = kalman_accel_x.filter(Float32(data.accel_x))
		let filtered_accel_y = kalman_accel_y.filter(Float32(data.accel_y))
		let filtered_accel_z = kalman_accel_z.filter(Float32(data.accel_z))

		/* -------- 为陀螺仪执行滤波操作 -------- */
		let filtered_gyro_x = kalman_gyro_x.filter(Float32(data.gyro_x))
		let filtered_gyro_y = kalman_gyro_y.filter(Float32(data.gyro_y))
		let filtered_gyro_z = kalman_gyro_z.filter(Float32(data.gyro_z))


		/* -------- 计算Pitch（俯仰角）和Roll（翻滚角） -------- */
		let roll = atan2(filtered_accel_y, filtered_accel_z) * RAD_TO_DEG
		let pitch = atan(-filtered_accel_x / sqrt(filtered_accel_y * filtered_accel_y + filtered_accel_z * filtered_accel_z)) * RAD_TO_DEG

		print("roll: ${roll}\t")
		println("pitch: ${pitch}")

		//unsafe { _mutex_unlock(mutex) }
		sleep(Duration.millisecond * 10)

	}

	/* -------- 返回NULL指针以占位 -------- */
	return CPointer<Unit>()
}

/* -------- mpu6050线程参数 --------
 * INFO(20260522-qing): mutex字段是一个锁的指针，需要在MPU6050的构造函数中获取资源
 * -  用于辅助别的线程获取值。  */
@C
struct mpu6050_th_param {
	public var i2c_fd: Int32 = 0		/* i2c文件句柄 */
	public var addr: UInt8 = 0		/* i2c设备地址 */
	public var mutex = CPointer<UInt8>()	/* 用于辅助别的线程获取值的锁 */
}



/* -------- MPU6050陀螺仪、加速度计 --------
 * - 输入并持有一个I2C文件句柄  */
public class MPU6050 {

	/* -------- 主初始化器 --------
	 * FIXME(20260517-qing): 由于gc的原因，我们可能会手动构造RAII，
	 * - 将一部分初始化移动到别的函数  */
	public init(i2c_fd: Int32, addr: UInt8)  {
		this.i2c_fd = i2c_fd
		this.addr = addr
		unsafe {
			param  = LibC.malloc<mpu6050_th_param>()
			var tmp = mpu6050_th_param()
			tmp.i2c_fd = i2c_fd
			tmp.addr = addr
			tmp.mutex = LibC.malloc<UInt8>()
			param.write(tmp)
		}
	}

	/* -------- 终结器 -------- */
	~init() {
		/* -------- 清除构造时申请的线程参数和锁 -------- */
		unsafe {
			var tmp = param.read()
			LibC.free(tmp.mutex)
			LibC.free(param) 
		}
	}

	/* -------- 初始化该模块 -------- */
	public func setup() {
		unsafe { mpu6050_setup(i2c_fd, addr) }
	}
    
	/*----------------*/
	private var i2c_fd: Int32	/* -------- I2C设备文件句柄 -------- */
	private var addr: UInt8		/* -------- I2C设备地址 -------- */


	/* -------- 获取原始MPU6050传感器数据 -------- */
	public func readSensor(): MPU6050_sensorData {
		return unsafe { mpu6050_readSensor(i2c_fd, addr) }
	}

	/* -------- mpu6050启动守护 -------- 
	 * TODO(20260520-qing): 放进类中
	 * --------------------------------- */
	var param: CPointer<mpu6050_th_param>	/* -------- 线程参数必须能够持久保存 -------- */
	var pth: Option<Pth> = None		/* -------- 线程对象 -------- */
	public func startDaemon() {		/* -------- 启动线程 -------- */
		pth = Pth(mpu6050_main, CPointer<Unit>(param))
	}

	/* -------- 停止线程 -------- */
	public func stopDaemon() {
		if (let Some(P) <- pth) {
			P.close()  }
	}

	/* -------- 等待线程终止 -------- */
	public func waitDaemon() {
		if (let Some(P) <- pth) {
			var ptr: CPointer<Unit> = CPointer<Unit>()
			P.join(CPointer<CPointer<Unit>>(CPointer<CPointer<Unit>>(ptr)))  }
	}

}

