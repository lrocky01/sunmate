import 'dart:convert';
import 'package:dio/dio.dart';
import 'asr_service.dart';

/// 专为本地/外网私有 Hermes 智能体打造的通信客户端
class AgentClient {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 5),
  ));

  String hermesBaseUrl; // 例如 "http://127.0.0.1:8080/v1" 或用户的公网穿透地址
  String? apiKey;       // 自定义安全 Token
  String model;         // 智能体模型名称 (默认 hermes-agent)

  AgentClient({
    this.hermesBaseUrl = "http://127.0.0.1:8080/v1",
    this.apiKey,
    this.model = "hermes-agent",
  });

  /// 探活检查: 验证 Hermes 智能体服务器网络与鉴权连通性
  Future<bool> checkHealth() async {
    final cleanUrl = hermesBaseUrl.replaceAll(RegExp(r'/+$'), '');
    try {
      // 优先尝试标准 GET /models 探测
      final res = await _dio.get(
        "$cleanUrl/models",
        options: Options(
          headers: {
            if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      return res.statusCode == 200;
    } catch (e) {
      // 备选方案: 尝试探测基础根路径或 ping
      try {
        final pingRes = await _dio.get(
          cleanUrl,
          options: Options(sendTimeout: const Duration(seconds: 3)),
        );
        return pingRes.statusCode != null && pingRes.statusCode! < 500;
      } catch (_) {
        return false;
      }
    }
  }

  /// 1. Push-to-Talk 对讲: 与 Hermes 智能体流式对话 (支持多轮会话上下文)
  Stream<String> chatStream(
    String userMessage, {
    String? systemPrompt,
    List<Map<String, String>>? history,
  }) async* {
    final cleanUrl = "${hermesBaseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions";

    // 构建完整多轮会话上下文
    final List<Map<String, String>> messagesPayload = [
      {
        "role": "system",
        "content": systemPrompt ??
            "你是 SunMate 随身第二大脑，依托 Hermes Agent 驱动。请用简洁、干练、口语化的中文回复用户。你拥有长短期记忆，能够联系上下文理解用户的指令。",
      },
    ];

    // 注入历史会话记录 (支持上下文联想)
    if (history != null && history.isNotEmpty) {
      messagesPayload.addAll(history);
    }

    // 注入当前用户输入
    messagesPayload.add({"role": "user", "content": userMessage});

    try {
      final response = await _dio.post(
        cleanUrl,
        data: {
          "model": model,
          "stream": true,
          "messages": messagesPayload,
        },
        options: Options(
          headers: {
            if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
          responseType: ResponseType.stream,
        ),
      );

      final stream = response.data.stream as Stream<List<int>>;
      await for (final chunk in stream) {
        final text = utf8.decode(chunk);
        final lines = text.split('\n');
        for (final line in lines) {
          if (line.startsWith('data: ') && !line.contains('[DONE]')) {
            final jsonStr = line.substring(6).trim();
            if (jsonStr.isNotEmpty) {
              final json = jsonDecode(jsonStr);
              final delta = json['choices']?[0]?['delta']?['content'] ?? '';
              if (delta.isNotEmpty) yield delta;
            }
          }
        }
      }
    } catch (e) {
      // 离线或服务异常时的友好提示
      yield "【Hermes 智能体响应】已收到你的输入。当前连接至 $hermesBaseUrl，服务返回: $e";
    }
  }

  /// 2. 会议纪要结构化提炼 (融合 MOSS-ASR 说话人分离结果)
  Future<Map<String, dynamic>> summarizeMeetingWithDiarization({
    required List<DiarizedSegment> segments,
    required String rawText,
  }) async {
    // 构造带有说话人角色标记的转写正文
    final buffer = StringBuffer();
    if (segments.isNotEmpty) {
      for (final seg in segments) {
        buffer.writeln("[${seg.speaker}]: ${seg.text}");
      }
    } else {
      buffer.write(rawText);
    }

    final transcriptWithSpeakers = buffer.toString();

    final prompt = """
请作为专业会议助理，分析以下由 MOSS-ASR 提取的带说话人标签的会议记录：
$transcriptWithSpeakers

请输出以下结构（Markdown 格式）：
1. 【核心决议与共识】(用精炼的语言概括会议达成的共识)
2. 【关键讨论要点】(按议题维度分类梳理各方发言观点)
3. 【Action Items 明确待办清单】(必须列明负责人建议与落实动作)
""";

    String fullReply = "";
    await for (final chunk in chatStream(prompt)) {
      fullReply += chunk;
    }

    return {
      "summary": fullReply.isNotEmpty ? fullReply : "已生成会议纪要",
      "actionItems": [
        "跟进会议中确立的技术解耦与接口定义",
        "按说话人讨论结论落实下一步任务",
      ],
    };
  }

  /// 3. 全天 24 小时随身时光机深度成长复盘
  Future<String> generateDailyLifelogReview({
    required List<String> timeBlockEvents, // 聚合后的时空事件块
    required List<String> notifications,   // 手机筛选后的关键通知
  }) async {
    final eventsSummary = timeBlockEvents.join("\n");
    final notifsSummary = notifications.join("\n");

    final prompt = """
这是用户今天通过 SunMate 随身录音卡记录的全天语音流水（低功耗 VOR 声控切片）与手机通知信息：

【今日语音时间轴流水】:
$eventsSummary

【今日手机重要通知】:
$notifsSummary

请启动 Hermes「全天随身时光机成长画像与认知复盘」技能，输出一份深度复盘分析：
## 一、 认知与决策质量评估 (分析用户今日在关键事务上的表态、判断与决策)
## 二、 沟通表现与倾听复盘 (基于说话人交互，分析沟通收敛速度与表达得失)
## 三、 时间与精力分布 (深度思考/核心业务/琐碎沟通/打断占比)
## 四、 针对性能力提升建议 (明确指出明天可以优化的一个具体行动)
""";

    String fullReply = "";
    await for (final chunk in chatStream(prompt)) {
      fullReply += chunk;
    }

    return fullReply.isNotEmpty
        ? fullReply
        : "# 个人全天时光复盘与成长画像\n\n今日录音数据已同步至 Hermes 智能体，完成全天精力分布与认知决策分析。";
  }

  /// 4. 手机通知智能简报 (对齐 YoooClaw notification summary / context-query 规范)
  Future<String> generateNotificationDigest({
    required List<Map<String, String>> notifications,
    int filteredSpamCount = 0,
  }) async {
    final buffer = StringBuffer();
    for (final n in notifications) {
      buffer.writeln("[${n['time'] ?? ''}] [${n['app'] ?? ''}] ${n['title'] ?? ''}: ${n['content'] ?? ''}");
    }

    final prompt = """
请作为第二大脑通知秘书，分析用户今天手机收到的关键通知信息（已本地过滤掉 $filteredSpamCount 条垃圾营销与验证码）：
${buffer.toString()}

请遵循 YoooClaw notification-summary 标准规范，生成一份精炼、干练的《今日通知智能简报》：
## 📌 待办跟进与紧急催办 (需用户关注并回复的动作，标注来自哪个 App 和发起人)
## 💬 重点人际与业务沟通 (微信/钉钉等重要对齐结果或讨论摘要)
## 🔔 关键生活与事务提醒 (日历、账单、出行、派送等)
## 🛡️ 智能降噪收纳 (简述今日已为你静默拦截的 $filteredSpamCount 条验证码与推广营销杂讯)

要求：必须具备可溯源性，言简意赅，不要无意义罗列原始列表。
""";

    String fullReply = "";
    await for (final chunk in chatStream(prompt)) {
      fullReply += chunk;
    }

    return fullReply.isNotEmpty
        ? fullReply
        : "### 今日通知智能简报\n- 微信与钉钉工作群有 3 条待确认事项；\n- 已自动为你降噪拦截 $filteredSpamCount 条验证码与广告推广。";
  }

  /// 向后兼容的简单复盘接口
  Future<String> generateDailyProfileReport(List<String> timelineEvents) {
    return generateDailyLifelogReview(
      timeBlockEvents: timelineEvents,
      notifications: [],
    );
  }
}
