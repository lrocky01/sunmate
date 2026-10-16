---
name: sunmate-doctor
description: |
  SunMate 随身第二大脑全链路健康检查与诊断技能。用于自检本地 MOSS-ASR 服务器状态、Hermes Agent 网关端点、局域网/反代网络延迟以及模型推理就绪情况。在用户询问“系统状态如何”、“测试连接”、“网络诊断”时触发。
metadata:
  version: "1.0.0"
  hermes:
    category: sunmate
    tags:
      - doctor
      - health-check
      - diagnostics
      - connection-test
---

# SunMate Doctor (全链路系统诊断与探活技能)

## 一、 技能目标
确保用户的 SunMate 手机 App、AiNote 6095 蓝牙卡、本地 MOSS-ASR 服务与 Hermes 智能体四端链路畅通无阻。

## 二、 诊断指标清单
1. **ASR 连通性**：
   - 检查本地 MOSS-ASR 端点（默认 `http://127.0.0.1:8000/health`）；
   - 检查 MLX 算力加速是否正常识别；
2. **Hermes 智能体网关**：
   - 检查 HTTP/SSE 端点（默认 `:8080/v1`）是否在后台稳定运行；
   - 验证 API Key / Bearer Token 校验是否通过；
3. **网络与反代可达性**：
   - 检测当前机器的本机内网 IP（`192.168.x.x`）与外部访问端口；
   - 若配置了反代（Cloudflare Tunnel / frp / cpolar），验证外网域名解析。
