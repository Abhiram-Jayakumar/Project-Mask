import 'package:flutter/material.dart';

import '../call_controller.dart';
import '../services/notification_mirror_service.dart';

/// Sliding bottom sheet that shows the host's mirrored app notifications.
class NotificationPanel extends StatelessWidget {
  const NotificationPanel({super.key, required this.controller});

  final CallController controller;

  static void show(BuildContext context, CallController controller) {
    controller.clearUnreadNotifs();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.60,
        minChildSize: 0.35,
        maxChildSize: 0.90,
        builder: (ctx, scroll) => NotificationPanel(controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final feed = controller.notificationFeed;
        return Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Handle bar
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.notifications, color: cs.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Notifications from host',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (feed.isNotEmpty)
                      Text(
                        '${feed.length}',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Feed
              Expanded(
                child: feed.isEmpty
                    ? _EmptyState(icon: Icons.notifications_none)
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: feed.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, indent: 68),
                        itemBuilder: (ctx, i) =>
                            _NotifTile(entry: feed[i]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NotifTile extends StatelessWidget {
  const _NotifTile({required this.entry});

  final NotifEntry entry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: _AppAvatar(appName: entry.app),
      title: Row(
        children: [
          Expanded(
            child: Text(
              entry.app,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.55),
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _timeAgo(entry.time),
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entry.title.isNotEmpty)
            Text(
              entry.title,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (entry.text.isNotEmpty)
            Text(
              entry.text,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      isThreeLine: entry.text.isNotEmpty,
    );
  }
}

class _AppAvatar extends StatelessWidget {
  const _AppAvatar({required this.appName});

  final String appName;

  @override
  Widget build(BuildContext context) {
    final letter =
        appName.isNotEmpty ? appName[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: 20,
      backgroundColor: _appColor(appName).withValues(alpha: 0.18),
      child: Text(
        letter,
        style: TextStyle(
          color: _appColor(appName),
          fontWeight: FontWeight.bold,
          fontSize: 15,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: cs.onSurface.withValues(alpha: 0.25)),
          const SizedBox(height: 12),
          Text(
            'No notifications yet',
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.4),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'App notifications from the host appear here',
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.3),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Deterministic color for an app name — consistent across redraws.
Color _appColor(String name) {
  const palette = [
    Color(0xFF3B82F6), // blue
    Color(0xFF8B5CF6), // violet
    Color(0xFF10B981), // emerald
    Color(0xFFF59E0B), // amber
    Color(0xFFEF4444), // red
    Color(0xFF06B6D4), // cyan
    Color(0xFFF97316), // orange
    Color(0xFF6366F1), // indigo
  ];
  if (name.isEmpty) return palette[0];
  return palette[name.codeUnitAt(0) % palette.length];
}

String _timeAgo(int epochMs) {
  final diff =
      DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(epochMs));
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
