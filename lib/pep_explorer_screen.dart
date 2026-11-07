import 'package:flutter/material.dart';

import 'pep/pep_explorer.dart';
import 'xmpp/xmpp_service.dart';

/// Lists all nodes on the logged-in user's PEP (XEP-0163) service,
/// discovered via a XEP-0030 disco#items query against their own bare JID.
///
/// Tapping a node opens [PepNodeDetailScreen], which shows the node's
/// configuration form and its currently published items.
class PepExplorerScreen extends StatefulWidget {
  const PepExplorerScreen({super.key, required this.service});

  final XmppService service;

  @override
  State<PepExplorerScreen> createState() => _PepExplorerScreenState();
}

class _PepExplorerScreenState extends State<PepExplorerScreen> {
  late Future<List<PepNodeSummary>> _nodesFuture;

  @override
  void initState() {
    super.initState();
    _nodesFuture = widget.service.fetchPepNodes();
  }

  void _refresh() {
    setState(() {
      _nodesFuture = widget.service.fetchPepNodes();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PEP explorer'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<PepNodeSummary>>(
        future: _nodesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final nodes = snapshot.data ?? const <PepNodeSummary>[];
          if (nodes.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No PEP nodes found.',
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: nodes.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final node = nodes[index];
              return ListTile(
                title: Text(node.node),
                subtitle: node.name != null ? Text(node.name!) : null,
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => PepNodeDetailScreen(
                        service: widget.service,
                        node: node.node,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// Shows a single PEP node's configuration fields and published items.
class PepNodeDetailScreen extends StatefulWidget {
  const PepNodeDetailScreen({
    super.key,
    required this.service,
    required this.node,
  });

  final XmppService service;
  final String node;

  @override
  State<PepNodeDetailScreen> createState() => _PepNodeDetailScreenState();
}

class _PepNodeDetailScreenState extends State<PepNodeDetailScreen> {
  late Future<List<PepNodeConfigField>> _configFuture;
  late Future<List<PepNodeItem>> _itemsFuture;

  @override
  void initState() {
    super.initState();
    _configFuture = widget.service.fetchPepNodeConfig(widget.node);
    _itemsFuture = widget.service.fetchPepNodeItems(widget.node);
  }

  void _refresh() {
    setState(() {
      _configFuture = widget.service.fetchPepNodeConfig(widget.node);
      _itemsFuture = widget.service.fetchPepNodeItems(widget.node);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.node, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Configuration', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          FutureBuilder<List<PepNodeConfigField>>(
            future: _configFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final fields = snapshot.data ?? const <PepNodeConfigField>[];
              if (fields.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'No configuration available.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final field in fields)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              field.label?.isNotEmpty == true
                                  ? field.label!
                                  : field.varName,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              field.values.isEmpty
                                  ? '(empty)'
                                  : field.values.join(', '),
                              textAlign: TextAlign.end,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          const Divider(height: 32),
          Text('Items', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          FutureBuilder<List<PepNodeItem>>(
            future: _itemsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final items = snapshot.data ?? const <PepNodeItem>[];
              if (items.isEmpty) {
                return Text(
                  'No items published.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in items)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (item.id.isNotEmpty)
                              Text(
                                item.id,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            const SizedBox(height: 4),
                            SelectableText(
                              item.xml.isEmpty ? '(empty payload)' : item.xml,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
