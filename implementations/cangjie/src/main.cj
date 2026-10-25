package bot4cj

/* 
 * 机器人脚本解析器 - 仓颉语言
 *
 */

import std.argopt.*
import std.env.*
import std.fs.*
//import ctype4cj.*
//import nn4cj.*

/* ---- 神经网络输出路径 ---- */
//var NNS_OUT: Option<String> = None	
main(args: Array<String>): Int64 {
	
	/* ---- 解析命令行参数 ---- */
	let specs = [
		ArgumentSpec.Long("help", ArgumentMode.NoValue),	/* ---- 拉起帮助 ---- */
		ArgumentSpec.Long("robot", ArgumentMode.RequiredValue),	/* ---- 结构脚本 ---- */
		ArgumentSpec.Long("tcp", ArgumentMode.RequiredValue),	/* ---- TCP 端口（长驻模式）---- */
		ArgumentSpec.Long("input", ArgumentMode.RequiredValue)	/* ---- 动作脚本文件路径 ---- */
//		ArgumentSpec.Short(r'i', ArgumentMode.RequiredValue),	/* ---- 输入模型 ---- */
//		ArgumentSpec.Short(r'o', ArgumentMode.RequiredValue),	/* ---- 输出模型 ---- */
//		ArgumentSpec.Long("test", ArgumentMode.RequiredValue)	/* ---- 输入一个测试 ---- */
	]

	/* ---- 执行解析 ---- */
	let parsed = parseArguments(args, specs)
	let options = parsed.options

	//---------------------------
	/* 读取设置项 */

	/*
	 *  初始化神经网络 （init nn）。
	 *  注意：以下 NN/DRL 相关代码为历史实现，当前版本注释保留。
	 *  TODO: 可以去掉内部初始化参数，使用矩阵式模板进行初始化
	 *  NOTE(20260830-qing): 更换nn4cj库之后，我的开发机器无法编译神经网络部分了，所以注释掉了
	 *  （计划结合 nn4cj 重新接入，见 README「待实现功能」）
	 */
	//var nns: ArrayList<Nn> = 
	//if (options.keys().contains("i")) {
	//	let filename = options['i']
	//	load_nns(filename)  }
	//else {
	//	let nn_in = ArrayList<Nn>()
	//	nn_in.add(Nn(41, 80, ActivationFuncs.Leaky_ReLU, 0.2f32))
	//	nn_in.add(Nn(80, 80, ActivationFuncs.Leaky_ReLU, 0.2f32))
	//	nn_in.add(Nn(80, 40, ActivationFuncs.Leaky_ReLU, 0.2f32))
	//	nn_in.add(Nn(40, 17, ActivationFuncs.Sigmoid, 0.2f32)) // 16个舵机加1个时延
	//	nn_in  }

	/* ---- 使用-o选项进行输出路径的选择 ---- */
	//if (options.contains("o")) {
	//	NNS_OUT = Option<String>.Some(options['o'])
	//}

	/*---------------------------*/
	/* 分支选择 */


	/* -------- 拉起帮助手册 -------- */
	if  (options.contains("help")) {
		print_help()
		return 0
	}

	/* -------- 启动一个测试分支 -------- */
	//else if (options.contains("test")) {
	//	run_test(options["test"])
	//	return 0
	//}

	/*
	 *  缺省行为：从标准输入获取动作脚本
	 * 
	 *  TODO(20260519-qing): 进行脚本引入（相对路径也可，从**环境变量**的路径中搜寻也可）
	 */
	else if (options.contains("robot")) {

		let rpath = options["robot"]

		/* ---- 友好报错：结构脚本打不开/解析失败时给人话提示，不裸栈回溯 ---- */
		var fstreamOpt: Option<File> = None
		try {
			fstreamOpt = Option<File>.Some(File(rpath, OpenMode.Read))
		} catch (e: Exception) {
			println("无法打开结构脚本 '${rpath}': ${e.message}")
			println("请确认 --robot 指向存在的结构脚本，示例：cat scripts/std.mt | ./bot --robot=robots/spider1.sql")
			return 1
		}
		let fstream = fstreamOpt.getOrThrow()

		var robotOpt: Option<RobotStruct> = None
		try {
			robotOpt = Option<RobotStruct>.Some(RobotStruct(fstream))
		} catch (e: Exception) {
			println("结构脚本解析失败 '${rpath}': ${e.message}")
			println("无硬件自检链路：cat scripts/relay-test.mt | ./bot --robot=robots/relay-test.sql")
			return 1
		} finally {
			/* 解析成败均关闭文件流（原实现异常路径不 close 泄漏 fd） */
			fstream.close()
		}
		let robot = robotOpt.getOrThrow()

		try {
			robot.active()

			/* ---- ActionSource：可替换动作输入源（stdin / TCP / 文件）---- */
			let inputOpt = openActionSource(options)
			if (let Some(input) <- inputOpt) {
				robot.run(input)
			} else {
				println("动作输入源打开失败，退出")
				return 1
			}
		}

		/* 硬件创建/激活/动作调用出错：停止执行并友好退出（错误码 1）；
		 * finally 的 deactivate 按声明序倒序回收已创建资源（两阶段构造） */
		catch (e: Exception) {
			println("Aborted: ${e}")
			return 1
		}

		/* 无论有没有成功激活，都进行清理 */
		finally {  robot.deactivate()  }

		/* 以下 NN/DRL 路径注释保留（历史上用于微调网络模型，未来配合 nn4cj 重新接入） */
//		let consoleReader = getStdIn()
//		run_action_drl(consoleReader, nns)
//		if (options.contains("o")) {
//			save_nns(nns, options['o'])  }
	}

	/* 没有输入机器人结构脚本，打印帮助文档 */
	else {

		print_help()
	}


	return 0
}

/* -------- 打印帮助手册 -------- */
func print_help()
{
	println("这是一个机器人动作脚本解析器。")
	println("使用--robot选项指定结构脚本，然后使用管道输入动作脚本，示例：")
	println("cat scripts/std.mt | ./bot --robot=./robots/spider1.sql")
	println("")
	println("动作输入源（优先级从高到低）：")
	println("  --tcp <port>    TCP 长驻模式：监听端口等待客户端下发 .mt")
	println("  --input <path>  从文件读取动作脚本")
	println("  （缺省）        从 stdin 管道读取")
}

/* -------- 集成多种常规测试、临时测试 --------
 * 以下 run_test 为历史代码，注释保留（其中 matrix_* 分支已过期——robot.run()
 * 现需 InputStream 实参；nn1 分支待 nn4cj 重新接入时激活） */
//func run_test(key: String) {
//
//	/*  神经网络门测试  */
//	if (key == "nn1") {  /*testNn()*/  }
//
//	/* -------- 测试反序列化矩阵，并且序列化输出 -------- */
//	else if (key == "matrix_o") {
//		let file = File("ss/test.mt", OpenMode.Read)
//		let robot = RobotStruct(file)
//		file.close()
//		let outf = File("ss/output.mt", OpenMode.Write)
//		robot.save(outf)
//		outf.close()
//	}
//
//	/* -------- 解析反序列化之前输出的矩阵 -------- */
//	else if (key == "matrix_2") {
//		let file = File("ss/output.mt", OpenMode.Read)
//		let robot = RobotStruct(file)
//		file.close()
//		robot.active()
//		robot.run()
//		robot.deactivate()
//		let outf = File("ss/output_1.mt", OpenMode.Write)
//		robot.save(outf)
//		outf.close()
//	}
//
//}
