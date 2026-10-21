"""Mount on Hermes' native aiohttp listener; never create a listener or patch core."""
import asyncio
from .service import ArchiveAPI, MAX_BODY, ROUTES


def mount(app, root, profile, scope_check=None):
    # Imported only when the api_server adapter supplies its native application.
    from aiohttp import web
    if app.router.frozen:
        raise ValueError('native_router_already_started')
    existing = {resource.canonical for resource in app.router.resources()}
    if any(path in existing for _, path in ROUTES):
        raise ValueError('existing_native_route_preserved')
    api = ArchiveAPI(root, profile)

    def reply(status, value):
        return web.json_response(value, status=status, headers={'Cache-Control': 'no-store'})

    async def handle(request):
        try:
            if scope_check is not None and not scope_check():
                return reply(409, {'error': 'profile_mismatch'})
            # Authenticate before reading content. The actual transaction rechecks
            # authorization so revocation during an upload also takes effect.
            _, client = await asyncio.to_thread(api.authorize, request.headers)
            if not client:
                return reply(401, {'error': 'authentication_required'})
            body = bytearray()
            if request.method == 'POST':
                if request.content_length is not None and request.content_length > MAX_BODY:
                    return reply(400, {'error': 'invalid_request'})
                async def read_body():
                    async for chunk in request.content.iter_chunked(65536):
                        body.extend(chunk)
                        if len(body) > MAX_BODY:
                            raise ValueError('request_too_large')
                await asyncio.wait_for(read_body(), timeout=10)
            # SQLite and filesystem operations must not block chat/SSE callbacks.
            status, value = await asyncio.to_thread(api.handle, request.method,
                request.raw_path, request.headers, bytes(body))
            return reply(status, value)
        except (ValueError, asyncio.TimeoutError):
            return reply(400, {'error': 'invalid_request'})
        except Exception:
            return reply(503, {'error': 'archive_unavailable'})

    for method, path in ROUTES:
        app.router.add_route(method, path, handle)
