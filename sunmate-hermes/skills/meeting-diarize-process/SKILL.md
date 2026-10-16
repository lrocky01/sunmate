---
name: meeting-diarize-process
description: |
  处理来自 MOSS-Transcribe-Diarize 的带说话人标签（Diarization）的长会议录音文本，提炼会议核心决议、各方讨论要点与明确的待办事项 Action Items。在用户要求“整理会议纪要”、“提炼会议要点”、“提取待办事项”时触发。
metadata:
  version: "1.0.0"
  hermes:
    category: sunmate
    tags:
      - meeting
      - diarization
      - action-items
      - summary
---

# Meeting Diarize Process (说话人分离高精度会议纪要)

## 一、 输入数据特征

本技能专为 **MOSS-Transcribe-Diarize-0.9B** 输出的带说话人标签文本优化：
```
[Speaker 0]: 我们今天讨论一下 SunMate 的软硬件解耦...
[Speaker 1]: 我赞同，底层驱动用 HAL 抽象，上层业务零改动...
```

## 二、 提炼规范与输出结构

必须严格提取出以下三层信息，严禁胡编乱造未提及的事实：

```markdown
# 📋 会议纪要与行动清单

## 🎯 一、 会议核心共识与最终决议
- 明确列出本次会议达成的核心共识（结论先行）。

## 💡 二、 关键讨论要点梳理 (分议题)
- **议题 1: [议题名称]**
  - **Speaker 0 观点**: ...
  - **Speaker 1 观点**: ...
  - **讨论结论**: ...

## 📌 三、 Action Items 明确行动清单
| 序号 | 待办任务 | 负责人建议 | 关键交付物 |
| :--- | :--- | :--- | :--- |
| 1 | [具体可执行动作] | [根据发言认领人判断] | [明确产出] |
```
