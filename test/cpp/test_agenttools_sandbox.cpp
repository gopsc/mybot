/* test_agenttools_sandbox.cpp —— resolveUnderRoot 的直接锚点（Phase 1，2026-10-07）
 *
 * agent_sandbox.hpp 是新加的通用「canonical 根目录包含性」判据，供未来的
 * read_file/write_file/list_dir 等通用 host 工具复用（现状：resolveActionScriptPath
 * 只做词法校验，capture_image 的白名单其实在 Lua 侧，两者都不是可直接复用的通用
 * 单点，见该头文件头注）。本文件只测这一个函数，不碰任何工具装配。
 */

#include "fixtures.hpp"
#include "harness.hpp"

#include "agentview.hpp"	/* resolveActionScriptPath 归位后经此引用（2026-10-10） */

using fx::TempDir;

#include <filesystem>
#include <fstream>
#include <system_error>
#include <unistd.h>

#include "agent_sandbox.hpp"

namespace fs = std::filesystem;

using bot::agent::resolveUnderRoot;
using bot::agent::SandboxCheck;

TH_TEST(agenttools_sandbox_accepts_plain_nested_path) {
	TempDir root("sandbox_ok");
	fs::create_directories(root.path() / "sub");
	{ std::ofstream f(root.path() / "sub" / "a.txt"); f << "x"; }

	auto r = resolveUnderRoot(root.path().string(), "sub/a.txt");
	TH_CHECK(r.check == SandboxCheck::OK);
	/* resolved 必须真的指向同一个文件（canonical 根 + 原样相对段拼接） */
	std::error_code ec;
	TH_CHECK(fs::equivalent(r.resolved, root.path() / "sub" / "a.txt", ec));
}

TH_TEST(agenttools_sandbox_allows_not_yet_existing_target) {
	/* 写文件场景：目标文件本身还不存在，但其祖先目录都是真的——必须放行,
	 * 否则 write_file 永远创建不了新文件。 */
	TempDir root("sandbox_new");
	fs::create_directories(root.path() / "sub");

	auto r = resolveUnderRoot(root.path().string(), "sub/brand_new.txt");
	TH_CHECK(r.check == SandboxCheck::OK);

	/* 连祖先目录都还不存在也要放行（调用方自己决定要不要 mkdir -p） */
	auto r2 = resolveUnderRoot(root.path().string(), "new_dir/new_file.txt");
	TH_CHECK(r2.check == SandboxCheck::OK);
}

TH_TEST(agenttools_sandbox_rejects_lexical_violations) {
	TempDir root("sandbox_lex");

	TH_CHECK(resolveUnderRoot(root.path().string(), "/etc/passwd").check
		== SandboxCheck::ABSOLUTE);
	TH_CHECK(resolveUnderRoot(root.path().string(), "../x.txt").check
		== SandboxCheck::DOTDOT);
	TH_CHECK(resolveUnderRoot(root.path().string(), "a/../../b.txt").check
		== SandboxCheck::DOTDOT);
	TH_CHECK(resolveUnderRoot(root.path().string(), "").check
		== SandboxCheck::EMPTY_OR_DOT);
	TH_CHECK(resolveUnderRoot(root.path().string(), ".").check
		== SandboxCheck::EMPTY_OR_DOT);
	TH_CHECK(resolveUnderRoot(root.path().string(), "a//b.txt").check
		== SandboxCheck::EMPTY_OR_DOT);
	TH_CHECK(resolveUnderRoot(root.path().string(), std::string("a\0b.txt", 7)).check
		== SandboxCheck::NUL);
}

TH_TEST(agenttools_sandbox_rejects_missing_or_non_dir_root) {
	TempDir parent("sandbox_root_missing");
	/* 根本不存在 */
	TH_CHECK(resolveUnderRoot((parent.path() / "nope").string(), "a.txt").check
		== SandboxCheck::ROOT_MISSING);
	/* 存在但不是目录（是个文件） */
	fs::path f = parent.path() / "notadir";
	{ std::ofstream of(f); of << "x"; }
	TH_CHECK(resolveUnderRoot(f.string(), "a.txt").check == SandboxCheck::ROOT_MISSING);
}

TH_TEST(agenttools_sandbox_rejects_symlinked_directory_escape) {
	/* root/evil 是指向 root 外部目录的符号链接；即便 evil/foo.txt 本身尚不存在
	 * （写文件场景），escape 也必须在 evil 这一级被拦下，不等到 open() 才发现。 */
	TempDir root("sandbox_escape_dir");
	TempDir outside("sandbox_escape_dir_target");
	fs::create_directories(outside.path() / "secret_dir");

	fs::path link = root.path() / "evil";
	TH_CHECK(::symlink((outside.path() / "secret_dir").c_str(), link.c_str()) == 0);

	auto r = resolveUnderRoot(root.path().string(), "evil/foo.txt");
	TH_CHECK(r.check == SandboxCheck::ESCAPES_ROOT);
}

TH_TEST(agenttools_sandbox_rejects_symlinked_file_escape) {
	/* root/link.txt 本身是指向 root 外部文件的符号链接（目标已存在）。 */
	TempDir root("sandbox_escape_file");
	TempDir outside("sandbox_escape_file_target");
	{ std::ofstream of(outside.path() / "secret.txt"); of << "机密"; }

	fs::path link = root.path() / "link.txt";
	TH_CHECK(::symlink((outside.path() / "secret.txt").c_str(), link.c_str()) == 0);

	auto r = resolveUnderRoot(root.path().string(), "link.txt");
	TH_CHECK(r.check == SandboxCheck::ESCAPES_ROOT);
}

TH_TEST(agenttools_sandbox_root_itself_as_dot) {
	TempDir root("sandbox_dot_root");
	fs::create_directories(root.path() / "sub");
	{ std::ofstream f(root.path() / "sub" / "a.txt"); f << "x"; }

	/* root 路径带尾斜杠 / "./" 等形态都应等价 */
	auto r = resolveUnderRoot(root.path().string() + "/", "sub/a.txt");
	TH_CHECK(r.check == SandboxCheck::OK);
}
