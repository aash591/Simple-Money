import 'package:flutter/material.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

/// [color] moved towards white (on a dark ground) or black (on a light one)
/// just far enough to read against [ground]. A colour that already reads is
/// left alone, so any accent keeps as much of its own hue as it can.
Color legibleOn(Color color, Color ground, {double minimum = 4.5}) {
  final towards = ground.computeLuminance() < .4 ? Colors.white : Colors.black;
  var result = color;
  for (
    var step = 1;
    step <= 20 && _contrast(result, ground) < minimum;
    step++
  ) {
    result = Color.lerp(color, towards, step * .05)!;
  }
  return result;
}
