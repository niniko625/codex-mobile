import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/i18n/app_locale.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../features/workspace/workspace_provider.dart';

enum _HomeMenuAction { language, theme, backup, update, logs, about }

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final themeState = ref.watch(themeProvider);
    final locale = ref.watch(localeProvider);
    final workspaceState = ref.watch(workspaceProvider);
    final s = Strings.get(locale);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        backgroundColor: colorScheme.surface,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/brand_mark.png',
              width: 26,
              height: 26,
              color: colorScheme.onSurface,
              colorBlendMode: BlendMode.srcIn,
            ),
            const SizedBox(width: 10),
            Text(
              s.homeTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: '部署中心',
            onPressed: () => context.push(RouteNames.deploy),
          ),
          PopupMenuButton<_HomeMenuAction>(
            tooltip: '更多设置',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (action) {
              switch (action) {
                case _HomeMenuAction.language:
                  ref.read(localeProvider.notifier).toggleLocale();
                  break;
                case _HomeMenuAction.theme:
                  ref.read(themeProvider.notifier).toggleTheme();
                  break;
                case _HomeMenuAction.backup:
                  context.push(RouteNames.backup);
                  break;
                case _HomeMenuAction.update:
                  context.push(RouteNames.update);
                  break;
                case _HomeMenuAction.logs:
                  context.push(RouteNames.logCenter);
                  break;
                case _HomeMenuAction.about:
                  context.push(RouteNames.about);
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _HomeMenuAction.language,
                child: _menuItem(
                  Icons.translate_rounded,
                  locale == AppLanguage.zhCN ? '切换到 English' : '切换到中文',
                ),
              ),
              PopupMenuItem(
                value: _HomeMenuAction.theme,
                child: _menuItem(
                  themeState.mode == ThemeModeOption.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  themeState.mode == ThemeModeOption.dark ? '切换亮色主题' : '切换暗色主题',
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: _HomeMenuAction.backup,
                child: _menuItem(Icons.backup_outlined, '备份与恢复'),
              ),
              PopupMenuItem(
                value: _HomeMenuAction.update,
                child: _menuItem(Icons.system_update_alt, '检查更新'),
              ),
              PopupMenuItem(
                value: _HomeMenuAction.logs,
                child: _menuItem(Icons.receipt_long_outlined, '日志中心'),
              ),
              PopupMenuItem(
                value: _HomeMenuAction.about,
                child: _menuItem(Icons.info_outline, '关于'),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _HeroCard(
            onStart: () => context.push(RouteNames.aiChat),
            onDeploy: () => context.push(RouteNames.deploy),
          ),
          const SizedBox(height: 12),
          _WorkspaceCard(
            workspaceState: workspaceState,
            onTap: () => context.push(RouteNames.workspaceList),
          ),
          const SizedBox(height: 24),
          _SectionTitle(title: '快捷工具', trailing: '常用入口'),
          const SizedBox(height: 10),
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              mainAxisExtent: 96,
            ),
            children: [
              _ToolTile(
                icon: Icons.terminal_rounded,
                title: '完整 Codex',
                subtitle: '官方 TUI · 插件 · Skills',
                color: colorScheme.primary,
                onTap: () => context.push(RouteNames.codex),
              ),
              _ToolTile(
                icon: Icons.auto_awesome_rounded,
                title: 'Codex 对话',
                subtitle: '描述任务并执行',
                color: colorScheme.onSurfaceVariant,
                onTap: () => context.push(RouteNames.aiChat),
              ),
              _ToolTile(
                icon: Icons.terminal_rounded,
                title: '终端',
                subtitle: '运行命令与查看日志',
                color: colorScheme.onSurfaceVariant,
                onTap: () => context.push(RouteNames.terminal),
              ),
              _ToolTile(
                icon: Icons.folder_open_rounded,
                title: '文件',
                subtitle: '浏览项目与源码',
                color: colorScheme.onSurfaceVariant,
                onTap: () => context.push(RouteNames.fileBrowser),
              ),
              _ToolTile(
                icon: Icons.edit_note_rounded,
                title: '编辑器',
                subtitle: '查看和修改代码',
                color: colorScheme.onSurfaceVariant,
                onTap: () => context.push(RouteNames.editor),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _SectionTitle(title: '工作台', trailing: '项目与运行环境'),
          const SizedBox(height: 10),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            color: colorScheme.surfaceContainerLow,
            child: Column(
              children: [
                _MenuTile(
                  icon: Icons.workspace_premium_outlined,
                  title: '工作区',
                  subtitle: '管理项目目录和模板',
                  onTap: () => context.push(RouteNames.workspaceList),
                ),
                _divider(colorScheme),
                _MenuTile(
                  icon: Icons.code_rounded,
                  title: 'GitHub 仓库',
                  subtitle: '仓库、PR、Issues 与 Git 操作',
                  onTap: () => context.push(RouteNames.repoList),
                ),
                _divider(colorScheme),
                _MenuTile(
                  icon: Icons.rocket_launch_outlined,
                  title: '部署中心',
                  subtitle: '安装 Linux、Codex CLI 并配置 Key',
                  onTap: () => context.push(RouteNames.deploy),
                ),
                _divider(colorScheme),
                _MenuTile(
                  icon: Icons.system_update_alt,
                  title: '检查更新',
                  subtitle: '下载并安装最新版 App',
                  onTap: () => context.push(RouteNames.update),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '文件与命令在手机本地执行 · 模型请求需要联网',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (index) {
          switch (index) {
            case 0:
              break;
            case 1:
              context.push(RouteNames.aiChat);
              break;
            case 2:
              context.push(RouteNames.terminal);
              break;
            case 3:
              context.push(RouteNames.repoList);
              break;
          }
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home_rounded),
            label: s.navHome,
          ),
          const NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'Codex',
          ),
          const NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: '终端',
          ),
          const NavigationDestination(
            icon: Icon(Icons.code_rounded),
            selectedIcon: Icon(Icons.code_rounded),
            label: 'GitHub',
          ),
        ],
      ),
    );
  }

  Widget _menuItem(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Text(text),
      ],
    );
  }

  Widget _divider(ColorScheme colorScheme) {
    return Divider(
      height: 1,
      indent: 56,
      color: colorScheme.outlineVariant.withValues(alpha: 0.6),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final VoidCallback onStart;
  final VoidCallback onDeploy;

  const _HeroCard({required this.onStart, required this.onDeploy});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '把手机变成\nCodex 工作台',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Text(
                  '>_',
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontFamily: 'monospace',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '选择工作目录，直接用自然语言读写文件、执行命令并运行测试。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              FilledButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: const Text('开始任务'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onDeploy,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('环境部署'),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.onSurfaceVariant,
                  minimumSize: const Size(0, 44),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  final WorkspaceState workspaceState;
  final VoidCallback onTap;

  const _WorkspaceCard({required this.workspaceState, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final workspace = workspaceState.currentWorkspace;

    return Card(
      margin: EdgeInsets.zero,
      color: colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  Icons.folder_open_rounded,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      workspace?.name ?? '选择工作目录',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      workspace == null
                          ? '未绑定项目时，Codex 使用 App 文档目录'
                          : '${workspace.projects.length} 个项目 · 点击切换或管理',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String trailing;

  const _SectionTitle({required this.title, required this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        Text(
          trailing,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ToolTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ToolTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 24),
              const Spacer(),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}
