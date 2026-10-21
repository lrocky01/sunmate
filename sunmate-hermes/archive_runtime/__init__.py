"""Private archive; no model calls, relay, BLE commands or audio deletion."""

def register(ctx):
    from .plugin import register as register_tools
    register_tools(ctx)
