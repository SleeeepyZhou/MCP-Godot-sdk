@tool
extends Node
class_name MCPClient

# Config
@export var server : MCPStdioServer = MCPStdioServer.new()
@export var auto_connect : bool = false
@export var auto_reconnect : bool = false
@export var max_reconnect_attempts : int = 3
@export_range(0, 300, 0.5) var request_timeout : float = 0

@export_tool_button("Connect server") var _connect = connect_to_server
@export_tool_button("Close server") var _close = stop
@export_tool_button("Tool list") var _print_tools = tool_list

signal connection(is_connect: bool)
signal log_record(log: String)

var _running := false
var _pid: int
var _stdio: FileAccess
var _stderr: FileAccess

var _stdout_buffer := ""
var _stderr_buffer := ""

func _ready() -> void:
	if auto_connect:
		connect_to_server()

# Send JSON-RPC
var _rpc : JSONRPC = JSONRPC.new()
func _send_message(message: Dictionary) -> bool:
	var json_str := JSON.stringify(message)
	_stdio.store_line(json_str)
	return _stdio.get_error() == OK

signal response_received(id: int, response: Dictionary)
var _wait_response : bool = false
func _get_response(request_id : int):
	_wait_response = true
	# request timer
	var _is_timeout : bool = false
	if request_timeout > 0:
		var timer = func (time : float): \
			await get_tree().create_timer(time).timeout \
			_is_timeout = true
		timer.call(request_timeout)
	var response = await _message_received
	while int(response["id"]) != request_id:
		response = await _message_received
		if _is_timeout:
			push_error("MCP server timeout, use ", request_timeout, "s.")
			response["result"] = {}
			break
	_wait_response = false
	response_received.emit(request_id, response["result"])
func _mcp_request(method: String, params: Dictionary = {}) -> Array: # [success:bool,id:int]
	if !_running or !_stdio:
		push_error("MCP server has not been started yet.")
		return [false, 0]
	var _request_id = Time.get_ticks_msec()
	var request := _rpc.make_request(method, params, _request_id)
	# message send
	if _send_message(request):
		_get_response(_request_id)
		return [true, _request_id]
	else:
		push_error("Failed to write IO.")
		return [false, 0]

func _mcp_notification(method: String, params: Dictionary = {}):
	_send_message(_rpc.make_notification(method,params))

## Run server
var _retry : int = 0
func connect_to_server() -> bool:
	# run server
	var server_run : String = server._command
	var arguments : PackedStringArray = [server.server_path]
	arguments.append_array(server.args)
	assert(server_run,"MCP server script has not been set up yet.")
	if !server.env.is_empty():
		for key in server.env.keys():
			OS.set_environment(key,server.env[key])
	var result := OS.execute_with_pipe(server_run, arguments, false)
	
	# reconnect
	if result.is_empty() and auto_reconnect and _retry < max_reconnect_attempts:
		push_error("Failed to start MCP server. Wait 1s retry.")
		await get_tree().create_timer(1.0).timeout
		_retry += 1
		return await connect_to_server()
	#assert(!result.is_empty(), "Failed to start MCP server")
	
	_stdio = result["stdio"]
	_stderr = result["stderr"]
	_pid = result["pid"]
	_running = true
	
	print("MCP server connect on pid: ", _pid)
	var send = _mcp_request("initialize", ToolBox.mcp_initialize)
	if send[0]:
		var connection_info = await response_received
		while connection_info[0] != send[1]:
			connection_info = await response_received
		if connection_info[1].is_empty():
			push_error("Failed to initialize MCP server.")
			stop()
			return false
		var server_name = str(connection_info[1]["serverInfo"])
		var protocol_version = str(connection_info[1]["protocolVersion"])
		if !ToolBox.SUPPORTED_PROTOCOL_VERSIONS.has(protocol_version):
			push_error("Unsupported protocol version.")
			stop()
			return false
		var server_info : String = "[color=green][b]Connected to server:[/b][/color]" + \
			server_name.substr(1,len(server_name)-2) + \
			"\n[color=green][b]Protocol version: [/b][/color]" + \
			protocol_version
		print_rich(str(server_info))
		_mcp_notification("notifications/initialized")
		_retry = 0
		connection.emit(true)
		return true
	else:
		push_error("Failed to initialize MCP server.")
		stop()
		return false

## Get tools list
func tool_list():
	var send = _mcp_request("tools/list")
	if send[0]:
		var tools_request = await response_received
		while tools_request[0] != send[1]:
			tools_request = await response_received
		if tools_request[1].is_empty():
			push_error("Unable to retrieve the tools list.")
			return []
		var tools = tools_request[1]["tools"]
		print(tools)
		return tools

## Use tool
func call_tool(tool_name : String, arguments : Dictionary = {}):
	var tool : Dictionary = {
		"name" : tool_name,
		"arguments" : arguments
	}
	var send = _mcp_request("tools/call",tool)
	if send[0]:
		var call_request = await response_received
		while call_request[0] != send[1]:
			call_request = await response_received
		if call_request[1].is_empty():
			push_error("Unable to use tool: ", tool_name)
			return []
		elif call_request[1]["isError"]:
			push_error("An error occurred while calling tool: ", tool_name)
			return []
		return call_request[1]["content"]

## Close server
func stop() -> void:
	if _running:
		_running = false
		connection.emit(false)
		if _stdio:
			_stdio.close()
		if _stderr:
			_stderr.close()
		if OS.is_process_running(_pid):
			OS.kill(_pid)
		print("MCP server closed on pid: ", _pid)
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		stop()

# Process IO
func _process(delta: float) -> void:
	if !_running:
		return
	
	_process_stdout()
	_process_stderr()
	
	if !OS.is_process_running(_pid):
		stop()
		if auto_reconnect:
			_retry = 0
			push_warning("Connect closed. Wait retry.")
			connect_to_server()

# Std Out
signal _message_received(message: Dictionary)
func _process_stdout() -> void:
	if !_stdio and !_wait_response:
		return
	var chunk := _stdio.get_as_text()
	while chunk != "":
		_stdout_buffer += chunk
		chunk = _stdio.get_as_text()
	
	#if !_stdout_buffer.is_empty():
		#print("New out: ", _stdout_buffer)
	
	var newline_pos := _stdout_buffer.find("\n")
	while newline_pos != -1:
		var message_str := _stdout_buffer.substr(0, newline_pos)
		_stdout_buffer = _stdout_buffer.substr(newline_pos + 1)
		
		var message = JSON.parse_string(message_str)
		if message:
			_message_received.emit(message)
		else:
			push_error("Failed to parse message: ", message_str)
		
		newline_pos = _stdout_buffer.find("\n")

# Std Err
func _process_stderr() -> void:
	if !_stderr:
		return
	
	var chunk := _stderr.get_as_text()
	while chunk != "":
		_stderr_buffer += chunk
		chunk = _stderr.get_as_text()
	
	#if !_stderr_buffer.is_empty():
		#print("New err: ", _stdout_buffer)
	
	var newline_pos := _stderr_buffer.find("\n")
	while newline_pos != -1:
		var log_line := _stderr_buffer.substr(0, newline_pos)
		_stderr_buffer = _stderr_buffer.substr(newline_pos + 1)
		log_record.emit(log_line)
		newline_pos = _stderr_buffer.find("\n")


#@export_tool_button("Test") var _test = test
#func test():
	#print(await call_tool("example_func",{"example_arg": "testtest"}))
	
