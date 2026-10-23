import sys, json
log = open("/tmp/n109-results/hostmcp-calls.jsonl", "a")  # host sees the full payload
TOOLS = [{"name": "propose_edit", "description": "Propose a change to a note. The host app applies it after user approval.",
  "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}, "new_content": {"type": "string"}}, "required": ["path", "new_content"]}}]
for line in sys.stdin:
    m = json.loads(line)
    mid = m.get("id"); meth = m.get("method")
    if mid is None: continue
    if meth == "initialize":
        r = {"protocolVersion": m["params"].get("protocolVersion", "2024-11-05"), "capabilities": {"tools": {}}, "serverInfo": {"name": "notess-host", "version": "0"}}
    elif meth == "tools/list":
        r = {"tools": TOOLS}
    elif meth == "tools/call":
        log.write(json.dumps(m["params"]) + "\n"); log.flush()
        r = {"content": [{"type": "text", "text": "Proposal queued for user review in the editor (id P1)."}]}
    else:
        r = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": r}) + "\n"); sys.stdout.flush()
