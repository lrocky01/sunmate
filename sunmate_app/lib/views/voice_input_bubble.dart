import 'dart:async';
import 'package:flutter/material.dart';
import '../providers/chat_provider.dart';

/// 同一条消息从录音、转写过渡为文字；动画表示处理状态，不依赖伪造的音量数据。
class VoiceInputBubble extends StatefulWidget {
  final ChatMessage message;
  const VoiceInputBubble({super.key, required this.message});
  @override
  State<VoiceInputBubble> createState() => _VoiceInputBubbleState();
}

class _VoiceInputBubbleState extends State<VoiceInputBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));
  Timer? _timer;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _configure();
  }

  @override
  void didUpdateWidget(VoiceInputBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.voicePhase != widget.message.voicePhase) _configure();
  }

  void _configure() {
    final recording = widget.message.voicePhase == VoiceInputPhase.recording;
    if (recording && !_reduceMotion) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
    }
    if (recording) {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  String get _duration {
    final elapsed = widget.message.voiceDuration ??
        DateTime.now().difference(widget.message.timestamp);
    final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final phase = message.voicePhase!;
    final scheme = Theme.of(context).colorScheme;
    final failed =
        phase == VoiceInputPhase.failed || phase == VoiceInputPhase.cancelled;
    final foreground =
        failed ? scheme.onErrorContainer : scheme.onPrimaryContainer;
    final label = switch (phase) {
      VoiceInputPhase.recording => '正在录音',
      VoiceInputPhase.preparing => '正在整理语音…',
      VoiceInputPhase.queued => '语音已收好，等待上一轮完成…',
      VoiceInputPhase.transcribing => '正在转成文字…',
      VoiceInputPhase.ready => '语音',
      VoiceInputPhase.failed => '语音未发送',
      VoiceInputPhase.cancelled => '录音已取消',
    };
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      constraints:
          BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .78),
      decoration: BoxDecoration(
          color: failed ? scheme.errorContainer : scheme.primaryContainer,
          borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4))),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (phase == VoiceInputPhase.preparing ||
                  phase == VoiceInputPhase.transcribing)
                SizedBox(
                    width: 18,
                    height: 18,
                    child: _reduceMotion
                        ? Icon(Icons.hourglass_top, size: 18, color: foreground)
                        : CircularProgressIndicator(
                            strokeWidth: 2, color: foreground))
              else
                Icon(failed ? Icons.info_outline : Icons.mic,
                    size: 18, color: foreground),
              const SizedBox(width: 8),
              Flexible(
                  child: Semantics(
                      liveRegion: phase != VoiceInputPhase.recording,
                      child: Text(label,
                          style: TextStyle(
                              color: foreground,
                              fontWeight: FontWeight.w600)))),
              const SizedBox(width: 12),
              Text(_duration,
                  style: TextStyle(color: foreground, fontSize: 12)),
            ]),
            if (phase == VoiceInputPhase.recording) ...[
              const SizedBox(height: 10),
              ExcludeSemantics(
                  child: AnimatedBuilder(
                      animation: _pulse,
                      builder: (context, _) => SizedBox(
                          height: 24,
                          child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                for (var i = 0; i < 7; i++)
                                  Container(
                                      width: 4,
                                      height: 6 +
                                          (i.isEven
                                                  ? _pulse.value
                                                  : 1 - _pulse.value) *
                                              (i % 3 + 1) *
                                              5,
                                      margin: const EdgeInsets.only(right: 4),
                                      decoration: BoxDecoration(
                                          color: foreground,
                                          borderRadius:
                                              BorderRadius.circular(2)))
                              ])))),
              const SizedBox(height: 6),
              Text('松开按键后转写',
                  style: TextStyle(color: foreground, fontSize: 12)),
            ],
            if (message.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(message.text,
                  style:
                      TextStyle(color: foreground, fontSize: 15, height: 1.4)),
            ],
          ]),
    );
    return Align(
        alignment: Alignment.centerRight,
        child: _reduceMotion
            ? bubble
            : AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topRight,
                child: bubble));
  }
}
