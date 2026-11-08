import 'amount_typing.dart';

/// Immediate-execution calculator, rounded to the currency's precision.
class AmountCalculator {
  double? _left;
  String? operation;
  bool replace = false;
  String? error;
  final List<String> _history = [];

  /// Calculator state before each operator/equals press, so backspace can
  /// undo them one at a time.
  final List<
    ({double? left, String? operation, List<String> history, String text})
  >
  _undo = [];
  double? _percentUnit;
  String _percentSource = '';
  String _percentRate = '';
  bool get enteringPercent => _percentUnit != null;
  bool get percentDecimalEnabled => !_percentRate.contains('.');
  String get _percentOperand =>
      '$_percentSource %${_percentRate.isEmpty ? '' : ' $_percentRate'}';
  String? get expression => _history.isEmpty ? null : _history.join(' ');
  String? expressionFor(String text) => enteringPercent
      ? '${operation == null ? '' : '${expression ?? ''} '}$_percentOperand'
      : operation != null && !replace
      ? '${expression ?? ''} ${text.isEmpty ? '0' : text}'
      : expression;

  double _evaluate(double value) => switch (operation) {
    '+' => _left! + value,
    '−' => _left! - value,
    '×' => _left! * value,
    '÷' => _left! / value,
    _ => value,
  };

  /// Evaluate without committing the operand or changing the typed expression.
  String resultFor(String text, int digits) {
    if (operation == null || replace) return text;
    final answer = _evaluate(double.tryParse(text) ?? 0);
    if (!answer.isFinite || answer.abs() >= 1000000000) return text;
    final rounded = answer.toStringAsFixed(digits);
    return digits == 0 ? rounded : rounded.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  void clear() {
    _undo.clear();
    _history.clear();
    _percentUnit = null;
    _percentRate = '';
    _left = null;
    operation = null;
    replace = false;
    error = null;
  }

  String edit(String text) {
    error = null;
    if (!replace) return text;
    if (operation == null) {
      _history.clear();
      _undo.clear();
    }
    replace = false;
    return '';
  }

  String _format(double value, int digits, String previous) {
    if (!value.isFinite || value.abs() >= 1000000000) {
      error = value.isFinite ? 'Amount is too large' : 'Cannot divide by zero';
      return previous;
    }
    error = null;
    final rounded = value.toStringAsFixed(digits);
    return digits == 0 ? rounded : rounded.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String press(String key, String text, int digits) {
    final value = double.tryParse(text) ?? 0;
    if (key == '±') {
      if (enteringPercent) {
        _percentUnit = -_percentUnit!;
        _percentSource = _percentSource.startsWith('-')
            ? _percentSource.substring(1)
            : '-$_percentSource';
      }
      return _format(-value, digits, text);
    }
    if (key == '%') {
      replace = false;
      final percent = (operation == '+' || operation == '−') && _left != null
          ? _left! * value / 100
          : value / 100;
      _percentUnit = percent;
      _percentSource = text.isEmpty ? '0' : text;
      _percentRate = '';
      return _format(percent, digits, text);
    }
    final operand = enteringPercent
        ? _percentOperand
        : (text.isEmpty ? '0' : text);
    _percentUnit = null;
    var result = text;
    final before = (
      left: _left,
      operation: operation,
      history: List<String>.of(_history),
      text: text,
    );
    if (operation != null && !replace) {
      final answer = _evaluate(value);
      result = _format(answer, digits, text);
      if (error != null) return result;
    }
    _undo.add(before);
    if (operation == null) {
      _history
        ..clear()
        ..add(operand);
    } else if (!replace) {
      _history.add(operand);
    } else if (_history.isNotEmpty) {
      _history.removeLast();
    }
    _history.add(key == '=' ? '= $result' : key);
    operation = key == '=' ? null : key;
    _left = double.tryParse(result) ?? 0;
    replace = true;
    return result;
  }

  String digit(String text, String digit, int digits) {
    if (enteringPercent) {
      _percentRate = AmountTyping.digit(_percentRate, digit, digits);
      return _percentResult(text, digits);
    }
    final current = edit(text);
    final negative = current.startsWith('-');
    return '${negative ? '-' : ''}${AmountTyping.digit(negative ? current.substring(1) : current, digit, digits)}';
  }

  String _percentResult(String text, int digits) => _format(
    _percentUnit! * (double.tryParse(_percentRate) ?? 1),
    digits,
    text,
  );

  String point(String text, int digits) {
    if (enteringPercent) {
      _percentRate = AmountTyping.point(_percentRate, digits);
      return _percentResult(text, digits);
    }
    return AmountTyping.point(edit(text), digits);
  }

  String backspace(String text, int digits) {
    if (enteringPercent) {
      if (_percentRate.isNotEmpty) {
        _percentRate = AmountTyping.backspace(_percentRate);
        return _percentResult(text, digits);
      }
      _percentUnit = null;
      return _percentSource;
    }
    // Nothing typed since the last operator/equals: step back through the
    // expression one entry at a time instead of eating the result's digits.
    if (_undo.isNotEmpty && (replace || (operation != null && text.isEmpty))) {
      final s = _undo.removeLast();
      _left = s.left;
      operation = s.operation;
      replace = false;
      error = null;
      _history
        ..clear()
        ..addAll(s.history);
      return s.text;
    }
    replace = false;
    error = null;
    final result = AmountTyping.backspace(text);
    return result == '-' ? '' : result;
  }
}
