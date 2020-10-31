// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.10
part of engine;

/// Converts colors and stops to typed array of bias, scale and threshold to use
/// in shaders.
///
/// A color is generated by taking a t value [0..1] and computing
/// t * scale + bias.
///
/// Example: For stops 0.0 t1, t2, 1.0 and colors c0, c1, c2, c3
///   Given t1<t<t2  outputColor = t * scale + bias.
///                 = c1 + (t - t1)/(t2 - t1) * (c2 - c1)
///                 = t * (c2 - c1)/(t2 - t1) + c1 - t1/(t2 - t1) * (c2 - c1)
///              scale = (c2 - c1) / (t2 - t1)
///              bias = c1 - t1 / (t2 - t1) * (c2 - c1)
class NormalizedGradient {
  NormalizedGradient._(this.thresholdCount, this._thresholds, this._scale,
      this._bias);

  final Float32List _thresholds;
  final Float32List _bias;
  final Float32List _scale;
  final int thresholdCount;

  factory NormalizedGradient(List<ui.Color> colors, {List<double>? stops}) {
    // If colorStops is not provided, then only two stops, at 0.0 and 1.0,
    // are implied (and colors must therefore only have two entries).
    assert(stops != null || colors.length == 2);
    stops ??= const <double>[0.0, 1.0];
    final int colorCount = colors.length;
    int normalizedCount = colorCount;
    bool addFirst = stops[0] != 0.0;
    bool addLast = stops.last != 1.0;
    if (addFirst) {
      normalizedCount++;
    }
    if (addLast) {
      normalizedCount++;
    }
    final Float32List bias = Float32List(normalizedCount * 4);
    final Float32List scale = Float32List(normalizedCount * 4);
    final Float32List thresholds = Float32List(4 * ((normalizedCount - 1)~/4 + 1));
    int targetIndex = 0;
    int thresholdIndex = 0;
    if (addFirst) {
      ui.Color c = colors[0];
      bias[targetIndex++] = c.red / 255.0;
      bias[targetIndex++] = c.green / 255.0;
      bias[targetIndex++] = c.blue / 255.0;
      bias[targetIndex++] = c.alpha / 255.0;
      thresholds[thresholdIndex++] = 0.0;
    }
    for (ui.Color c in colors) {
      bias[targetIndex++] = c.red / 255.0;
      bias[targetIndex++] = c.green / 255.0;
      bias[targetIndex++] = c.blue / 255.0;
      bias[targetIndex++] = c.alpha / 255.0;
    }
    for (double stop in stops) {
      thresholds[thresholdIndex++] = stop;
    }
    if (addLast) {
      ui.Color c = colors.last;
      bias[targetIndex++] = c.red / 255.0;
      bias[targetIndex++] = c.green / 255.0;
      bias[targetIndex++] = c.blue / 255.0;
      bias[targetIndex++] = c.alpha / 255.0;
      thresholds[thresholdIndex++] = 1.0;
    }
    // Now that we have bias for each color stop, we can compute scale based
    // on delta between colors.
    int lastColorIndex = 4 * (normalizedCount - 1);
    for (int i = 0; i < lastColorIndex; i++) {
      int thresholdIndex = i >> 2;
      scale[i] = (bias[i + 4] - bias[i]) /
          (thresholds[thresholdIndex + 1] - thresholds[thresholdIndex]);
    }
    scale[lastColorIndex] = 0.0;
    scale[lastColorIndex + 1] = 0.0;
    scale[lastColorIndex + 2] = 0.0;
    scale[lastColorIndex + 3] = 0.0;
    // Compute bias = colorAtStop - stopValue * (scale).
    for (int i = 0; i < normalizedCount; i++) {
      double t = thresholds[i];
      int colorIndex = i * 4;
      bias[colorIndex] -= t * scale[colorIndex];
      bias[colorIndex + 1] -= t * scale[colorIndex + 1];
      bias[colorIndex + 2] -= t * scale[colorIndex + 2];
      bias[colorIndex + 3] -= t * scale[colorIndex + 3];
    }
    return NormalizedGradient._(normalizedCount, thresholds, scale, bias);
  }

  /// Sets uniforms for threshold, bias and scale for program.
  void setupUniforms(_GlContext gl, _GlProgram glProgram) {
    for (int i = 0; i < thresholdCount; i++) {
      Object biasId = gl.getUniformLocation(glProgram.program, 'bias_$i');
      gl.setUniform4f(biasId, _bias[i * 4], _bias[i * 4 + 1], _bias[i * 4 + 2], _bias[i * 4 + 3]);
      Object scaleId = gl.getUniformLocation(glProgram.program, 'scale_$i');
      gl.setUniform4f(scaleId, _scale[i * 4], _scale[i * 4 + 1], _scale[i * 4 + 2], _scale[i * 4 + 3]);
    }
    for (int i = 0; i < _thresholds.length; i += 4) {
      Object thresId = gl.getUniformLocation(glProgram.program, 'threshold_${i ~/ 4}');
      gl.setUniform4f(thresId, _thresholds[i], _thresholds[i + 1], _thresholds[i + 2], _thresholds[i + 3]);
    }
  }

  /// Returns bias component at index.
  double biasAt(int index) => _bias[index];

  /// Returns scale component at index.
  double scaleAt(int index) => _scale[index];

  /// Returns threshold at index.
  double thresholdAt(int index) => _thresholds[index];
}

/// Writes fragment shader code to search for probe value in source data and set
/// bias and scale to be used for computation.
///
/// Source data for thresholds is provided using ceil(count/4) packed vec4
/// uniforms.
///
/// Bias and scale data are vec4 uniforms that hold color data.
void _writeUnrolledBinarySearch(ShaderMethod method, int start, int end,
    {required String probe,
      required String sourcePrefix, required String biasName,
      required String scaleName}) {
  if (start == end) {
    String biasSource = '${biasName}_${start}';
    method.addStatement('${biasName} = ${biasSource};');
    String scaleSource = '${scaleName}_${start}';
    method.addStatement('${scaleName} = ${scaleSource};');
  } else {
    // Add probe check.
    int mid = (start + end) ~/ 2;
    String thresholdAtMid = '${sourcePrefix}_${(mid + 1)~/4}';
    thresholdAtMid += '.${_vectorComponentIndexToName((mid + 1) % 4)}';
    method.addStatement('if ($probe < $thresholdAtMid) {');
    method.indent();
    _writeUnrolledBinarySearch(method, start, mid,
        probe: probe, sourcePrefix: sourcePrefix, biasName: biasName,
        scaleName: scaleName);
    method.unindent();
    method.addStatement('} else {');
    method.indent();
    _writeUnrolledBinarySearch(method, mid + 1, end,
        probe: probe, sourcePrefix: sourcePrefix, biasName: biasName,
        scaleName: scaleName);
    method.unindent();
    method.addStatement('}');
  }
}

String _vectorComponentIndexToName(int index) {
  assert(index >=0 && index <= 4);
  return 'xyzw'[index];
}
