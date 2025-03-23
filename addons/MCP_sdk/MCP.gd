@tool
extends EditorPlugin


func _enter_tree():
	add_autoload_singleton("ToolBox", "res://addons/MCP_sdk/ToolBox.gd")
	add_custom_type("MCPClient", "Node", preload("res://addons/MCP_sdk/MCPClient.gd"),\
		preload("res://addons/MCP_sdk/mcp.png"))
	add_custom_type("MCPServer", "Resource", preload("res://addons/MCP_sdk/MCPServer.gd"),\
		preload("res://addons/MCP_sdk/mcp.png"))
	add_custom_type("MCPStdioServer", "Resource", preload("res://addons/MCP_sdk/MCPStdioServer.gd"),\
		preload("res://addons/MCP_sdk/mcp.png"))

func _exit_tree():
	remove_autoload_singleton("ToolBox")
	remove_custom_type("MCPClient")
	remove_custom_type("MCPServer")
	remove_custom_type("MCPStdioServer")
