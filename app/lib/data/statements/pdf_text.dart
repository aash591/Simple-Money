import 'package:flutter/services.dart';

import 'pdf_table.dart';

/// Why a PDF's text could not be read.
enum PdfTextFailure { password, wrongPassword, unreadable }

class PdfTextException implements Exception {
  const PdfTextException(this.failure);
  final PdfTextFailure failure;
}

const _channel = MethodChannel('simple_money/pdf_text');

/// The text of the PDF in [bytes], read on the device by PdfBox. Throws a
/// [PdfTextException] for a locked file ([password] opens it and is not
/// kept) or one that isn't a readable PDF.
Future<String> extractPdfText(Uint8List bytes, {String? password}) => _read(
  () async =>
      await _channel.invokeMethod<String>('extract', {
        'bytes': bytes,
        'password': password,
      }) ??
      '',
);

/// Every word of the PDF in [bytes] with where it sits on its page, read on
/// the device by PdfBox, for [pdfStatementTable]. Throws as [extractPdfText].
Future<List<PdfWord>> extractPdfWords(Uint8List bytes, {String? password}) =>
    _read(() async {
      final words = await _channel.invokeMethod<List<Object?>>('words', {
        'bytes': bytes,
        'password': password,
      });
      return [
        for (final word in words ?? const <Object?>[])
          if (word case [
            final int page,
            final num left,
            final num top,
            final num right,
            final num bottom,
            final String text,
          ])
            PdfWord(
              page,
              left.toDouble(),
              top.toDouble(),
              right.toDouble(),
              bottom.toDouble(),
              text,
            ),
      ];
    });

/// The first [count] pages of the PDF in [bytes] as JPEG pictures, drawn on
/// the device by PdfBox. Throws as [extractPdfText].
Future<List<Uint8List>> renderPdfPages(
  Uint8List bytes, {
  String? password,
  int count = 2,
}) => _read(() async {
  final pages = await _channel.invokeMethod<List<Object?>>('pages', {
    'bytes': bytes,
    'password': password,
    'count': count,
  });
  return [
    for (final page in pages ?? const <Object?>[])
      if (page is Uint8List) page,
  ];
});

Future<T> _read<T>(Future<T> Function() read) async {
  try {
    return await read();
  } on PlatformException catch (error) {
    throw PdfTextException(switch (error.code) {
      'password' => PdfTextFailure.password,
      'wrongPassword' => PdfTextFailure.wrongPassword,
      _ => PdfTextFailure.unreadable,
    });
  } on MissingPluginException {
    throw const PdfTextException(PdfTextFailure.unreadable);
  }
}
