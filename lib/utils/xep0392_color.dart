import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';

const double _kappa = 903.2962962;
const double _epsilon = 0.0088564516;
const double _refU = 0.19783000664283;
const double _refV = 0.46831999493879;

Color xep0392ColorForLabel(String input) {
  final normalized = input.trim();
  if (normalized.isEmpty) {
    return const Color(0xFF9E9E9E);
  }
  final hash = Sha1().toSync().hashSync(utf8.encode(normalized));
  final bytes = hash.bytes;
  final value = bytes[0] + (bytes[1] << 8);
  final hue = (value / 65536.0) * 360.0;
  const saturation = 100.0;
  const lightness = 50.0;
  final rgb = _hsluvToRgb(hue, saturation, lightness);
  return Color.fromARGB(
    255,
    (rgb[0] * 255).round().clamp(0, 255),
    (rgb[1] * 255).round().clamp(0, 255),
    (rgb[2] * 255).round().clamp(0, 255),
  );
}

List<double> _hsluvToRgb(double h, double s, double l) {
  final lch = _hsluvToLch(h, s, l);
  final luv = _lchToLuv(lch);
  final xyz = _luvToXyz(luv);
  return _xyzToRgb(xyz);
}

List<double> _hsluvToLch(double h, double s, double l) {
  if (l > 99.9999999) {
    return <double>[100.0, 0.0, h];
  }
  if (l < 0.00000001) {
    return <double>[0.0, 0.0, h];
  }
  final maxChroma = _maxChromaForLH(l, h);
  final c = maxChroma / 100.0 * s;
  return <double>[l, c, h];
}

List<double> _lchToLuv(List<double> lch) {
  final l = lch[0];
  final c = lch[1];
  final h = lch[2] * pi / 180.0;
  final u = cos(h) * c;
  final v = sin(h) * c;
  return <double>[l, u, v];
}

List<double> _luvToXyz(List<double> luv) {
  final l = luv[0];
  if (l == 0) {
    return <double>[0.0, 0.0, 0.0];
  }
  final u = luv[1];
  final v = luv[2];
  final varU = u / (13.0 * l) + _refU;
  final varV = v / (13.0 * l) + _refV;
  final y = l > (_kappa * _epsilon) ? pow((l + 16.0) / 116.0, 3).toDouble() : l / _kappa;
  final x = -(9.0 * y * varU) / ((varU - 4.0) * varV - varU * varV);
  final z = (9.0 * y - 15.0 * varV * y - varV * x) / (3.0 * varV);
  return <double>[x, y, z];
}

List<double> _xyzToRgb(List<double> xyz) {
  const m = <List<double>>[
    <double>[3.240969941904521, -1.537383177570093, -0.498610760293],
    <double>[-0.96924363628087, 1.87596750150772, 0.041555057407175],
    <double>[0.055630079696993, -0.20397695888897, 1.056971514242878],
  ];
  final r = _fromLinear(_dot(m[0], xyz));
  final g = _fromLinear(_dot(m[1], xyz));
  final b = _fromLinear(_dot(m[2], xyz));
  return <double>[
    r.isFinite ? r : 0.0,
    g.isFinite ? g : 0.0,
    b.isFinite ? b : 0.0,
  ];
}

double _fromLinear(double c) {
  if (c <= 0.0031308) {
    return 12.92 * c;
  }
  return 1.055 * pow(c, 1.0 / 2.4).toDouble() - 0.055;
}

double _dot(List<double> a, List<double> b) {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

double _maxChromaForLH(double l, double h) {
  final bounds = _getBounds(l);
  final hRad = h * pi / 180.0;
  var minLength = double.infinity;
  for (final line in bounds) {
    final denom = sin(hRad) - line[0] * cos(hRad);
    if (denom == 0.0) {
      continue;
    }
    final length = line[1] / denom;
    if (length >= 0 && length < minLength) {
      minLength = length;
    }
  }
  if (minLength.isInfinite || minLength.isNaN) {
    return 0.0;
  }
  return minLength;
}

List<List<double>> _getBounds(double l) {
  final result = <List<double>>[];
  final sub1 = pow(l + 16.0, 3).toDouble() / 1560896.0;
  final sub2 = sub1 > _epsilon ? sub1 : l / _kappa;
  const m = <List<double>>[
    <double>[3.240969941904521, -1.537383177570093, -0.498610760293],
    <double>[-0.96924363628087, 1.87596750150772, 0.041555057407175],
    <double>[0.055630079696993, -0.20397695888897, 1.056971514242878],
  ];
  for (var c = 0; c < 2; c++) {
    for (var t = 0; t < 3; t++) {
      final m1 = m[t][0];
      final m2 = m[t][1];
      final m3 = m[t][2];
      final top1 = (284517.0 * m1 - 94839.0 * m3) * sub2;
      final top2 = (838422.0 * m3 + 769860.0 * m2 + 731718.0 * m1) * l * sub2 -
          769860.0 * t * l;
      final bottom = (632260.0 * m3 - 126452.0 * m2) * sub2 + 126452.0 * t;
      result.add(<double>[top1 / bottom, top2 / bottom]);
    }
  }
  return result;
}
