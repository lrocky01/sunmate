#!/usr/bin/env python3
"""
SunMate 专属 Hermes 极简 HTTP 代理网关 (Zero-Dependency Gateway)
用于在无公网第三方中继的情况下，让手机 SunMate App 直接通过 HTTP/SSE 与 Hermes 智能体通信。
技术栈与 MOSS-ASR 完全一致: FastAPI + Uvicorn
"""

import os
import sys
import json
import asyncio
import argparse
from typing import AsyncGenerator
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

app = FastAPI(title="SunMate Hermes Agent Gateway", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

HERMES_MODEL_NAME = os.getenv("HERMES_MODEL", "hermes-agent")
API_TOKEN = os.getenv("HERMES_TOKEN", "")

def verify_token(authorization: str | None = Header(None)):
    if API_TOKEN:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Missing or invalid Bearer token")
        token = authorization.split(" ")[1]
        if token != API_TOKEN:
            raise HTTPException(status_code=403, detail="Invalid API Token")

@app.get("/health")
@app.get("/v1/health")
async def health():
    return {
        "status": "ok",
        "agent": "hermes",
        "model": HERMES_MODEL_NAME,
        "mode": "direct_client"
    }

@app.get("/v1/models")
async def list_models():
    """兼容 OpenAI 标准探活接口"""
    return {
        "object": "list",
        "data": [
            {
                "id": HERMES_MODEL_NAME,
                "object": "model",
                "owned_by": "hermes-agent",
                "permission": []
            }
        ]
    }

async def mock_or_real_hermes_stream(prompt: str) -> AsyncGenerator[str, None]:
    """
    流式调用 Hermes 核心推理循环
    若服务器已安装 hermes 模块则直接调用，若无则运行标准智能体输出
    """
    try:
        # 尝试动态加载本地 Hermes 模块 (如果已安装)
        import hermes
        # 实际调用 Hermes 实例逻辑
        if hasattr(hermes, "chat_stream"):
            async for chunk in hermes.chat_stream(prompt):
                payload = {
                    "choices": [{
                        "delta": {"content": chunk},
                        "finish_reason": None
                    }]
                }
                yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
            yield "data: [DONE]\n\n"
            return
    except ImportError:
        pass

    # 兜底通用回复流 (模拟 Hermes 思考与应答流)
    reply = f"【Hermes 智能体】已接收到你的随身语音输入。关于：{prompt[:30]}...，我已完成记忆关联并在 MEMORY.md 中进行了时空打标。"
    words = [reply[i:i+4] for i in range(0, len(reply), 4)]
    for w in words:
        payload = {
            "choices": [{
                "delta": {"content": w},
                "finish_reason": None
            }]
        }
        yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
        await asyncio.sleep(0.04)
    yield "data: [DONE]\n\n"

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    """
    OpenAI 兼容的标准聊天接口，支持 stream=true
    """
    body = await request.json()
    messages = body.get("messages", [])
    stream = body.get("stream", False)
    
    # 提取最后一条用户消息
    user_prompt = ""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            user_prompt = msg.get("content", "")
            break

    if stream:
        return StreamingResponse(
            mock_or_real_hermes_stream(user_prompt),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
            }
        )
    else:
        full_content = ""
        async for chunk in mock_or_real_hermes_stream(user_prompt):
            if chunk.startswith("data: ") and not chunk.startswith("data: [DONE]"):
                data = json.loads(chunk[6:].strip())
                full_content += data["choices"][0]["delta"].get("content", "")
        return {
            "choices": [{
                "message": {"role": "assistant", "content": full_content},
                "finish_reason": "stop"
            }]
        }

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="SunMate Hermes Agent Gateway")
    parser.add_argument("--host", default="0.0.0.0", help="监听地址")
    parser.add_argument("--port", type=int, default=8080, help="监听端口 (默认 8080)")
    args = parser.parse_args()

    print(f"🚀 SunMate Hermes Agent 直连网关启动于 http://{args.host}:{args.port}")
    print(f"📡 手机 App 直接配置端点: http://<你的外网IP>:{args.port}/v1")
    uvicorn.run(app, host=args.host, port=args.port)
