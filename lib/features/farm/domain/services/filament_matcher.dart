/// 耗材→打印头 自动匹配
///
/// 移植自 lava_app `DevicePrepareToPrintViewModel.findMatchingExtruder`
/// （lava_device_control/.../device_prepare_to_print_viewmodel.dart）与
/// CIEDE2000 颜色差异 `CalColorDistance`（cal_color_distance.dart）。
///
/// 匹配规则：跳过未启用 / 喷嘴不匹配 / 类型不匹配的头；精确颜色命中立即返回；
/// 否则取 CIEDE2000 色距最小的头。返回 1-based 打印头编号，无匹配返回 null。
library filament_matcher;

import 'dart:math';

import 'package:flutter/material.dart';

import '../models/print_head.dart';
import '../models/product_material.dart';

// ── 公开 API ────────────────────────────────────────────────────────────── //

/// 两色之间的 CIEDE2000 视觉差异 ΔE（越小越相近）。
double colorDistance(Color a, Color b) => _ciede2000(
      _rgbToLab(a.red.toDouble(), a.green.toDouble(), a.blue.toDouble()),
      _rgbToLab(b.red.toDouble(), b.green.toDouble(), b.blue.toDouble()),
    );

/// 为单个耗材（类型 + 颜色 + 可选喷嘴）在打印头列表中找最匹配的头。
/// 返回 1-based [PrintHead.index]，无匹配返回 null。
int? findMatchingExtruder({
  required String type,
  required Color color,
  double? nozzle,
  required List<PrintHead> heads,
}) {
  var minDistance = double.infinity;
  int? best;

  for (final head in heads) {
    if (!head.enabled) continue;
    // 喷嘴不一致则跳过（文件指定了喷嘴时才校验）
    if (nozzle != null && head.nozzleDiameter != nozzle) continue;
    // 类型必须一致
    if (head.filamentType != type) continue;

    final headColor = Color(head.argb);
    if (headColor == color) return head.index; // 精确命中

    final d = colorDistance(headColor, color);
    if (d < minDistance) {
      minDistance = d;
      best = head.index;
    }
  }
  return best;
}

/// 批量匹配：返回一份新的耗材列表，每条有效耗材（grams>0）写入 [ProductMaterial.assignedHead]。
/// 未用耗材（grams==0）或无匹配耗材的 assignedHead 置 null。
List<ProductMaterial> assignHeads(
  List<ProductMaterial> materials,
  List<PrintHead> heads, {
  double? nozzle,
}) {
  return [
    for (final m in materials)
      ProductMaterial(
        colorName: m.colorName,
        argb: m.argb,
        grams: m.grams,
        extruderIndex: m.extruderIndex,
        assignedHead: m.grams > 0
            ? findMatchingExtruder(
                type: m.colorName,
                color: Color(m.argb),
                nozzle: nozzle,
                heads: heads,
              )
            : null,
      ),
  ];
}

// ── CIEDE2000（移植 cal_color_distance.dart，纯 Dart）───────────────────── //
const double _xn = 95.047;
const double _yn = 100.000;
const double _zn = 108.883;
const double _epsilon = 216.0 / 24389.0; // (6/29)^3
const double _kappa = 24389.0 / 27.0; // (29/3)^3

List<double> _rgbToLab(double r, double g, double b) {
  // RGB → XYZ（sRGB, D65）
  r /= 255;
  g /= 255;
  b /= 255;
  r = (r > 0.04045 ? pow((r + 0.055) / 1.055, 2.4) : r / 12.92).toDouble();
  g = (g > 0.04045 ? pow((g + 0.055) / 1.055, 2.4) : g / 12.92).toDouble();
  b = (b > 0.04045 ? pow((b + 0.055) / 1.055, 2.4) : b / 12.92).toDouble();
  final x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) * 100;
  final y = (r * 0.2126729 + g * 0.7151522 + b * 0.072175) * 100;
  final z = (r * 0.0193339 + g * 0.119192 + b * 0.9503041) * 100;

  // XYZ → Lab
  double f(double t) =>
      (t > _epsilon ? pow(t, 1 / 3) : (_kappa * t + 16) / 116).toDouble();
  final fx = f(x / _xn);
  final fy = f(y / _yn);
  final fz = f(z / _zn);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

double _ciede2000(List<double> lab1, List<double> lab2) {
  final l1 = lab1[0], a1 = lab1[1], b1 = lab1[2];
  final l2 = lab2[0], a2 = lab2[1], b2 = lab2[2];

  final c1 = sqrt(a1 * a1 + b1 * b1);
  final c2 = sqrt(a2 * a2 + b2 * b2);
  final cAvg = (c1 + c2) / 2;
  final g = 0.5 * (1 - sqrt(pow(cAvg, 7) / (pow(cAvg, 7) + pow(25, 7))));
  final a1p = (1 + g) * a1;
  final a2p = (1 + g) * a2;
  final c1p = sqrt(a1p * a1p + b1 * b1);
  final c2p = sqrt(a2p * a2p + b2 * b2);

  double hue(double b, double ap) {
    if (ap == 0 && b == 0) return 0;
    var h = atan2(b, ap);
    if (h < 0) h += 2 * pi;
    return h;
  }

  final h1p = hue(b1, a1p);
  final h2p = hue(b2, a2p);

  final dLp = l2 - l1;
  final dCp = c2p - c1p;
  double dhp = 0;
  if (c1p * c2p != 0) {
    dhp = h2p - h1p;
    if (dhp > pi) {
      dhp -= 2 * pi;
    } else if (dhp < -pi) {
      dhp += 2 * pi;
    }
  }
  final dHp = 2 * sqrt(c1p * c2p) * sin(dhp / 2);

  final lAvg = (l1 + l2) / 2;
  final cAvgp = (c1p + c2p) / 2;
  double hAvgp = 0;
  if (c1p * c2p != 0) {
    if ((h1p - h2p).abs() <= pi) {
      hAvgp = (h1p + h2p) / 2;
    } else {
      hAvgp = (h1p + h2p + 2 * pi) / 2;
      if (hAvgp > 2 * pi) hAvgp -= 2 * pi;
    }
  }

  final t = 1 -
      0.17 * cos(hAvgp - pi / 6) +
      0.24 * cos(2 * hAvgp) +
      0.32 * cos(3 * hAvgp + pi / 30) -
      0.20 * cos(4 * hAvgp - 63 * pi / 180);
  final sl = 1 + (0.015 * pow(lAvg - 50, 2)) / sqrt(20 + pow(lAvg - 50, 2));
  final sc = 1 + 0.045 * cAvgp;
  final sh = 1 + 0.015 * cAvgp * t;
  final dTheta = 30 * exp(-pow((hAvgp - 275 * pi / 180) / (25 * pi / 180), 2));
  final rc = 2 * sqrt(pow(cAvgp, 7) / (pow(cAvgp, 7) + pow(25, 7)));
  final rt = -rc * sin(2 * dTheta * pi / 180);

  return sqrt(pow(dLp / sl, 2) +
      pow(dCp / sc, 2) +
      pow(dHp / sh, 2) +
      rt * (dCp / sc) * (dHp / sh));
}
