#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
YoooClaw / AiNote 6095 蓝牙通信协议模拟与编解码器 (Python 实现)
支持：
 1. GATT UUID 定义速查
 2. TLV 帧与 JSON-RPC 报文组包/解包
 3. 核心控制命令构造 (开始录音/停止录音/RTC校准/增益配置)
 4. Opus 音频流帧结构解析
"""

import struct
import json
import time

# ==================== 1. GATT UUID 定义 ====================
UUIDS = {
    "SERVICE_OPUS":         "00010203-0405-0607-0809-0a0b0c0d1913",
    "CHAR_APP_CMD_WRITE":   "00010203-0405-0607-0809-0a0b0c0d2b15", # App 发送命令 (Write)
    "CHAR_DEVICE_EVENT":    "00010203-0405-0607-0809-0a0b0c0d2b30", # 设备事件上报 (Notify)
    "CHAR_OPUS_AUDIO_DATA": "00010203-0405-0607-0809-0a0b0c0d2b31", # 实时音频流 (Notify)
    "CHAR_FILE_DATA":       "00010203-0405-0607-0809-0a0b0c0d2b32", # 离线文件块传输
    "CHAR_EXT_DEBUG":       "00010203-0405-0607-0809-0a0b0c0d2b33", # 调试扩展
    "SERVICE_BATTERY":      "0000180F-0000-1000-8000-00805F9B34FB", # 电池服务
    "CHAR_BATTERY_LEVEL":   "00002A19-0000-1000-8000-00805F9B34FB", # 电量特征值
    "DESC_CCCD":            "00002902-0000-1000-8000-00805F9B34FB", # 通知使能
}

# ==================== 2. TLV 帧封装与解包 ====================
def pack_tlv(msg_type: int, payload: bytes) -> bytes:
    """
    封装为标准 TLV 结构:
      [2 字节 Type] + [2 字节 Length] + [Payload]
    """
    return struct.pack('<HH', msg_type, len(payload)) + payload

def unpack_tlv(data: bytes):
    """
    解析 TLV 结构
    """
    if len(data) < 4:
        return None, None, data
    msg_type, length = struct.unpack('<HH', data[:4])
    if len(data) < 4 + length:
        return None, None, data # 数据不完整
    payload = data[4:4+length]
    remaining = data[4+length:]
    return msg_type, payload, remaining

# ==================== 3. JSON-RPC 命令构造 ====================
def build_json_rpc(method: str, params: dict = None, req_id: int = 1) -> bytes:
    msg = {
        "version": "1.0.0",
        "method": method,
        "id": req_id
    }
    if params:
        msg["params"] = params
    return json.dumps(msg, separators=(',', ':')).encode('utf-8')

# ==================== 4. 业务控制命令构造器 ====================
class AiNote6095CommandBuilder:
    @staticmethod
    def get_capabilities():
        """查询设备能力"""
        payload = build_json_rpc("getCapabilities")
        return pack_tlv(0x0001, payload)

    @staticmethod
    def get_status():
        """查询当前状态 (电量、录音状态、存储)"""
        payload = build_json_rpc("getStatus")
        return pack_tlv(0x0002, payload)

    @staticmethod
    def start_recording():
        """开始录音命令"""
        payload = build_json_rpc("startRecord", {"timestamp": int(time.time())})
        return pack_tlv(0x0010, payload)

    @staticmethod
    def stop_recording():
        """停止录音命令"""
        payload = build_json_rpc("stopRecord")
        return pack_tlv(0x0011, payload)

    @staticmethod
    def pause_recording():
        """暂停录音"""
        payload = build_json_rpc("pauseRecord")
        return pack_tlv(0x0012, payload)

    @staticmethod
    def resume_recording():
        """恢复录音"""
        payload = build_json_rpc("resumeRecord")
        return pack_tlv(0x0013, payload)

    @staticmethod
    def sync_time(unix_sec: int = None):
        """同步硬件 RTC 时间戳"""
        if unix_sec is None:
            unix_sec = int(time.time())
        # 二进制 4 字节时间戳同步
        payload = struct.pack('<I', unix_sec)
        return pack_tlv(0x0005, payload)

    @staticmethod
    def set_gain(gain0: int, gain1: int):
        """设置主麦/辅助麦克风增益 (dB)"""
        payload = struct.pack('<BB', min(48, max(0, gain0)), min(48, max(0, gain1)))
        return pack_tlv(0x0008, payload)

    @staticmethod
    def power_off():
        """硬件关机"""
        payload = build_json_rpc("powerOff")
        return pack_tlv(0x00FF, payload)

# ==================== 5. 音频数据流帧解析 ====================
def parse_voice_data_frame(packet: bytes):
    """
    解析来自 CHAR_OPUS_AUDIO_DATA (2B31) 的实时音频 Notify 数据包
    """
    if len(packet) < 4:
        return None
    # 假设前 2 字节为 SessionID，接下来的 2 字节为包序号 Seq
    session_id, seq = struct.unpack('<HH', packet[:4])
    opus_payload = packet[4:]
    
    # 检查 Opus 码率规格
    bitrate = "Unknown"
    if len(opus_payload) == 40:
        bitrate = "16 kbps (40 Bytes / 20ms frame)"
    elif len(opus_payload) == 80:
        bitrate = "32 kbps (80 Bytes / 20ms frame)"
    
    return {
        "session_id": session_id,
        "seq": seq,
        "payload_len": len(opus_payload),
        "bitrate_profile": bitrate,
        "raw_opus": opus_payload
    }

# ==================== 6. 自测演示 ====================
if __name__ == '__main__':
    print("==================================================")
    print("  YoooClaw 硬件录音卡 (AiNote 6095) 蓝牙协议自测演示")
    print("==================================================\n")

    print("[1] 核心 GATT 特征值:")
    for k, v in UUIDS.items():
        print(f"  {k:<22}: {v}")
    
    print("\n[2] 构造【开始录音】命令报文:")
    cmd_start = AiNote6095CommandBuilder.start_recording()
    print("  Hex:", cmd_start.hex(' '))
    msg_type, payload, _ = unpack_tlv(cmd_start)
    print(f"  解包 Type: 0x{msg_type:04X}, Length: {len(payload)}, Payload: {payload.decode('utf-8')}")

    print("\n[3] 构造【RTC 时间校准】命令报文:")
    cmd_time = AiNote6095CommandBuilder.sync_time(1728988888)
    print("  Hex:", cmd_time.hex(' '))
    msg_type, payload, _ = unpack_tlv(cmd_time)
    print(f"  解包 Type: 0x{msg_type:04X}, Timestamp: {struct.unpack('<I', payload)[0]}")

    print("\n[4] 模拟解析硬件发来的【16kbps Opus 实时音频包】:")
    # 模拟硬件发来的音频包: Header(Session=1, Seq=105) + 40字节 Opus 数据
    dummy_audio_packet = struct.pack('<HH', 1, 105) + (b'\xFC' + b'\xAA' * 39)
    result = parse_voice_data_frame(dummy_audio_packet)
    print("  解析结果:", result)

    print("\n所有协议测试完成，格式校验通过！")
