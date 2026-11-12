# C-1 守门：CRLF 行尾 + 单换行分隔。修复前 CRLF 恰好能工作（被丢弃的是 \r），
# 修复后必须继续工作，防止只按 LF 语义修而破坏 CRLF。
@Alias
name  alias;
   A  angle;
@
@Action
s1.A;
   45;
@
