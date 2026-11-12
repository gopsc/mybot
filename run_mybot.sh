./build/mybot --robot=robots/relay-test.sql \
  --mcp-backend --mcp-socket /tmp/mybot.sock \
  --scripts-dir scripts \
  --fs-root . --agent-write-file \
  --agent-shell --agent-hot-sql \
  --read-var relay0 \
  --agent-policy mybot.policy.json \
  --audit-log -
