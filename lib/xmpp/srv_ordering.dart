import 'dart:math';

import 'srv_target.dart';

List<XmppSrvTarget> orderXmppSrvTargets(
  List<XmppSrvTarget> records, {
  Random? random,
}) {
  if (records.isEmpty) {
    return const [];
  }
  final rng = random ?? Random();
  final ordered = <XmppSrvTarget>[];
  final priorities = records.map((record) => record.priority).toSet().toList()
    ..sort();
  for (final priority in priorities) {
    final samePriority = records
        .where((record) => record.priority == priority)
        .toList();
    ordered.addAll(
      _weightedOrder(
        samePriority.where((record) => record.directTls).toList(),
        random: rng,
      ),
    );
    ordered.addAll(
      _weightedOrder(
        samePriority.where((record) => !record.directTls).toList(),
        random: rng,
      ),
    );
  }
  return ordered;
}

List<XmppSrvTarget> _weightedOrder(
  List<XmppSrvTarget> records, {
  required Random random,
}) {
  if (records.isEmpty) {
    return const [];
  }
  final remaining = List<XmppSrvTarget>.from(records);
  final ordered = <XmppSrvTarget>[];
  while (remaining.isNotEmpty) {
    final totalWeight = remaining.fold<int>(
      0,
      (sum, record) => sum + record.weight,
    );
    final index = totalWeight <= 0
        ? random.nextInt(remaining.length)
        : _weightedIndex(remaining, random.nextInt(totalWeight));
    ordered.add(remaining.removeAt(index));
  }
  return ordered;
}

int _weightedIndex(List<XmppSrvTarget> records, int roll) {
  var running = 0;
  for (var i = 0; i < records.length; i++) {
    running += records[i].weight;
    if (roll < running) {
      return i;
    }
  }
  return records.length - 1;
}
