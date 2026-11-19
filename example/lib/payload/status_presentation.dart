import 'package:flutter/material.dart';
import 'package:web_payload_manager/web_payload_manager.dart';

/// 将插件状态统一映射为面板展示用的文案与语义色。
class StatusPresentation {
  const StatusPresentation({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  static StatusPresentation forResourceState(ResourceState? state) {
    return switch (state) {
      null => const StatusPresentation(label: '未开始', color: Colors.grey),
      Loading(:final progress) => StatusPresentation(
          label: progress == null
              ? '加载中'
              : '下载中 ${(progress * 100).toStringAsFixed(0)}%',
          color: Colors.blue,
        ),
      Data() => const StatusPresentation(label: '已就绪', color: Colors.green),
      Error() => const StatusPresentation(label: '加载失败', color: Colors.red),
    };
  }

  /// [hasPendingRemoteUpdate] 为 true 时覆盖插件侧「无需更新」等历史同步状态。
  static StatusPresentation forPayloadSync({
    required PayloadSyncState state,
    required bool hasPendingRemoteUpdate,
    int? activeVersion,
    int? remoteVersion,
  }) {
    if (state is SyncChecking ||
        state is SyncDownloading ||
        state is SyncFailed) {
      return _fromPayloadSyncState(state);
    }
    if (hasPendingRemoteUpdate &&
        activeVersion != null &&
        remoteVersion != null) {
      return StatusPresentation(
        label: '有待更新（$activeVersion → $remoteVersion，请点「立即同步」）',
        color: Colors.orange,
      );
    }
    return _fromPayloadSyncState(state);
  }

  static StatusPresentation _fromPayloadSyncState(PayloadSyncState state) {
    return switch (state) {
      SyncIdle() => const StatusPresentation(label: '未开始', color: Colors.grey),
      SyncChecking() =>
        const StatusPresentation(label: '检测更新中', color: Colors.grey),
      SyncDownloading(:final progress) => StatusPresentation(
          label: progress == null
              ? '下载中'
              : '下载中 ${(progress * 100).toStringAsFixed(0)}%',
          color: Colors.blue,
        ),
      SyncUpToDate() =>
        const StatusPresentation(label: '无需更新（已是最新）', color: Colors.green),
      SyncCompleted() =>
        const StatusPresentation(label: '下载成功', color: Colors.green),
      SyncFailed(:final message) => StatusPresentation(
          label: '下载失败：$message',
          color: Colors.red,
        ),
    };
  }
}
