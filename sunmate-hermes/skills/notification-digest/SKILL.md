---
name: notification-digest
description: 手机系统通知智能简报与洞察萃取。当用户需要对微信、钉钉、日程、生活提醒等全天手机通知进行智能总结、提炼待办跟进项、或查询“今天有什么通知/谁找过我”时使用。
metadata:
  version: "1.0.0"
  category: sunmate
  tags:
    - notifications
    - digest
    - action-items
    - memory
---

# Notification Digest & Insights

针对 SunMate App 本地降噪聚合后的通知流，提炼结构化智能简报并识别隐式待办。

## 输入格式规范

接收标准时间戳通知流数组，每个通知包含：
- `timestamp`: ISO 8601 或 HH:mm 时间
- `appName`: 来源 App (如 wechat, dingtalk, calendar, system)
- `title`: 发起人、群聊名或通知标题
- `content`: 通知消息正文

## 核心提炼维度 (Output Contract)

```markdown
# 📬 今日通知智能简报 · [YYYY-MM-DD]

### 📌 待办跟进与催办事项 (Action Items)
- [ ] **[时间] [来自 App/人名]**: [提取需要用户回复、确认或执行的具体行动]

### 💬 核心沟通与对齐动态 (Key Conversations)
- **[人名/群组]** ([App]): [讨论的核心结论、关键背景或决策同步]

### 🔔 关键生活与事务动态 (Life & Transactions)
- **[分类]**: [如日程安排、账单消费、快递取件码、行程提醒等关键事实]

### 🛡️ 智能降噪收纳概览
- *今日已自动为你静默过滤拦截 [N] 条营销推广与验证码通知，未打扰深度思考。*
```

## 执行准则
1. **可溯源性**：所有提炼出的事项必须标注来源 App、时间与发言主体；
2. **严禁无意义罗列**：将同一个群的多次零碎刷屏聚合为一条明确结论；
3. **记忆沉淀**：如果通知中包含长期重要决定（如“团队正式确定项目名称”），除在简报中体现外，自动增量标记并沉淀至 `MEMORY.md`。
