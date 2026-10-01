// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:PiliPlus/services/video_accelerator/diagnostic_export.dart';

import 'package:PiliPlus/services/video_accelerator/accelerator_config.dart';
import 'package:PiliPlus/services/video_accelerator/accelerator_diagnostics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/services/video_accelerator/transfer_metrics.dart';

class StreamingAcceleratorPage extends StatefulWidget {
  const StreamingAcceleratorPage({
    super.key,
    required this.mode,
    required this.onChanged,
    this.budgets = const AcceleratorBudgets(),
    this.onBudgetsChanged,
  });
  final AcceleratorMode mode;
  final AcceleratorBudgets budgets;
  final Future<void> Function(AcceleratorBudgets)? onBudgetsChanged;
  final Future<void> Function(AcceleratorMode) onChanged;
  @override
  State<StreamingAcceleratorPage> createState() =>
      _StreamingAcceleratorPageState();
}

class _StreamingAcceleratorPageState extends State<StreamingAcceleratorPage> {
  late AcceleratorMode mode = widget.mode;
  bool saving = false;
  late AcceleratorBudgets budgets = widget.budgets;
  Future<void> saveBudgets(AcceleratorBudgets next) async {
    if (saving || widget.onBudgetsChanged == null) return;
    setState(() => saving = true);
    try {
      await widget.onBudgetsChanged!(next);
      if (mounted) setState(() => budgets = next);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('保存失败，保留原设置')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> select(AcceleratorMode next) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await widget.onChanged(next);
      if (mounted) setState(() => mode = next);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('播放加速 / Streaming Accelerator')),
    body: ListView(
      children: [
        const ListTile(
          title: Text('PiliBoost Accelerator · V8'),
          subtitle: Text('默认关闭。设置在下次加载视频/切换画质时生效；原 CDN 设置仍保留。'),
        ),
        for (final entry in const {
          AcceleratorMode.off: '关闭 / OFF',
          AcceleratorMode.auto: '自动 / Auto（V1：CDN 优选）',
          AcceleratorMode.smartCdn: 'CDN 优选 / Smart CDN',
          AcceleratorMode.rangeProxy: '本地 Range 代理 / Proxy（实验，单连接）',
          AcceleratorMode.multiCdn: '多 CDN 多线程 / Multi-CDN · Auto（实验）',
          AcceleratorMode.rangeAuto: '多线程 / Multi-Range · Auto（4–16）',
          AcceleratorMode.multiRange4: '多线程 / Multi-Range · 4',
          AcceleratorMode.multiRange8: '多线程 / Multi-Range · 8',
          AcceleratorMode.multiRange12: '多线程 / Multi-Range · 12',
          AcceleratorMode.multiRange16: '多线程 / Multi-Range · 16',
        }.entries)
          ListTile(
            title: Text(entry.value),
            trailing: mode == entry.key ? const Icon(Icons.check) : null,
            enabled: !saving,
            onTap: () => select(entry.key),
          ),
        ListTile(
          title: const Text('并发上限'),
          subtitle: Text('${budgets.concurrencyLimit} 路；手动与 Auto 均受此上限约束'),
          trailing: DropdownButton<int>(
            value: budgets.concurrencyLimit,
            items: [
              for (final n in [4, 8, 12, 16])
                DropdownMenuItem(value: n, child: Text('$n 路')),
            ],
            onChanged: saving || widget.onBudgetsChanged == null
                ? null
                : (n) {
                    if (n != null)
                      saveBudgets(
                        AcceleratorBudgets(
                          cacheMiB: budgets.cacheMiB,
                          concurrencyLimit: n,
                        ),
                      );
                  },
          ),
        ),
        ListTile(
          title: const Text('RAM 缓存预算'),
          subtitle: Text('${budgets.cacheMiB} MiB 缓存 + 4 MiB 重排；非进程总内存上限'),
          trailing: DropdownButton<int>(
            value: budgets.cacheMiB,
            items: [
              for (final n in [4, 8, 16])
                DropdownMenuItem(value: n, child: Text('$n MiB')),
            ],
            onChanged: saving || widget.onBudgetsChanged == null
                ? null
                : (n) {
                    if (n != null)
                      saveBudgets(
                        AcceleratorBudgets(
                          cacheMiB: n,
                          concurrencyLimit: budgets.concurrencyLimit,
                        ),
                      );
                  },
          ),
        ),
        const ListTile(
          title: Text('缓存与带宽'),
          subtitle: Text(
            '音频直连。Multi-CDN 最多验证 2 条备用线路，强 ETag/总长度/头尾采样一致后分配；失败线路冷却。其他代理模式保持单 CDN。每片 256 KiB，重排最多 4 MiB；仅可传输的强 ETag 启用并发。seek 取消旧代；缓存预算可选 4/8/16 MiB，前后窗口各 4 MiB，不写磁盘缓存。CDN 优选每轮至多 2 次 256 KiB 探测，间隔至少 30 秒。',
          ),
        ),
        ListTile(
          title: const Text('加速状态 / Diagnostics'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const AcceleratorDiagnosticsPage(),
            ),
          ),
        ),
      ],
    ),
  );
}

class AcceleratorDiagnosticsPage extends StatefulWidget {
  const AcceleratorDiagnosticsPage({super.key});
  @override
  State<AcceleratorDiagnosticsPage> createState() =>
      _AcceleratorDiagnosticsPageState();
}

class _AcceleratorDiagnosticsPageState
    extends State<AcceleratorDiagnosticsPage> {
  final comparison = DiagnosticComparison();
  Future<void> copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制脱敏诊断')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PiliBoost Diagnostics')),
    body: StreamBuilder<Map<String, Object?>>(
      initialData: AcceleratorDiagnostics.latest,
      stream: AcceleratorDiagnostics.updates,
      builder: (context, snapshot) {
        final data = snapshot.data ?? const {'state': 'off'};
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => copy(DiagnosticExport.encode(data)),
                  child: const Text('复制当前诊断'),
                ),
                for (final enabled in [false, true])
                  TextButton(
                    onPressed: () {
                      final recorded = comparison.record(
                        data,
                        enabled: enabled,
                      );
                      if (recorded) setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            recorded
                                ? '已记录 ${enabled ? "ON" : "OFF"}'
                                : '请先切换到对应模式并重新加载视频',
                          ),
                        ),
                      );
                    },
                    child: Text('记录 ${enabled ? "ON" : "OFF"}'),
                  ),
                TextButton(
                  onPressed: comparison.complete
                      ? () => copy(comparison.encode())
                      : null,
                  child: const Text('复制 OFF/ON 对照'),
                ),
              ],
            ),
            Text(
              '记录：OFF ${comparison.off == null ? "未记录" : "已记录"} / ON ${comparison.on == null ? "未记录" : "已记录"}；仅为两次手工快照，不自动认定同视频或加速收益。',
            ),
            Text('状态：${data['state']}'),
            Text(AcceleratorEffectSummary.describe(data)),
            Text(
              '网络接收：${AcceleratorEffectSummary.rate(data['networkReceivedBps'])}（含探测/重试）',
            ),
            Text(
              '网络顺序输出：${AcceleratorEffectSummary.rate(data['networkForwardedBps'])}',
            ),
            Text(
              '缓存输出：${AcceleratorEffectSummary.rate(data['cacheForwardedBps'])}',
            ),
            Text(
              '缓冲：${(data['bufferSeconds'] as num?)?.toStringAsFixed(1) ?? "未测量"} 秒；目标：${AcceleratorEffectSummary.rate(data['requiredBps'])}',
            ),
            Text(switch (data['switchOutcome']) {
              'awaitingBufferRecovery' => '已切线，正在观察缓冲；尚未确认改善。',
              'stillLowBuffer' => '切线后仍低缓冲：本次加速尚未达到播放需求。',
              'bufferRecovered' => '缓冲已恢复；不代表长期播放验收通过。',
              _ => '尚未切线。',
            }),
            const Text(
              '吞吐单位 bits/s；TTFB、cooldown 单位 ms；buffer 单位秒。\n'
              'V1 的 aggregateBps 为 mpv cache-speed 辅助值，不是逐轨精确吞吐。\n'
              '代理计量为最近约 3 秒视频载荷速率，不含音频/协议开销；输出区分网络与缓存。Auto 只使用网络顺序输出，不使用缓存速度，仍不是跨 seek 去重 goodput。\n'
              'DNS/connect/RTT 未测量时显示 null；不输出签名 URL。',
            ),
            const SizedBox(height: 12),
            SelectableText(const JsonEncoder.withIndent('  ').convert(data)),
          ],
        );
      },
    ),
  );
}
