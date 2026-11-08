import 'package:flutter/material.dart';

/// Brands with no safely-licensable logo mark available (see
/// tool/fetch_brand_icons.mjs for the ones that do — several well-known
/// brands, Amazon and Microsoft included, are deliberately absent from that
/// source, and Microsoft's own published guidance is explicit that
/// third-party logo use needs an express license). Shown as a plain text
/// badge instead of a redrawn logo: a company's name/initials aren't
/// copyrightable, and labeling a real transaction with them ("this was
/// Amazon") is the same ordinary nominative use as the licensed logos —
/// what changes is not reproducing anyone's copyrighted artwork to do it.
///
/// Colors here are the brands' well-known public colors (their `#RRGGBB` is
/// documented across countless independent sources, e.g. press/media
/// coverage) used only to help recognition, not copied from any owned
/// design file.
class WordmarkBrand {
  const WordmarkBrand(this.key, this.label, this.name, this.color);
  final String key; // stored-key suffix, e.g. 'amazon'
  final String label; // short badge text, e.g. 'a'
  final String name; // full display name, e.g. 'Amazon'
  final Color color;
}

const wordmarkBrands = <WordmarkBrand>[
  WordmarkBrand('amazon', 'a', 'Amazon', Color(0xFFFF9900)),
  WordmarkBrand('microsoft', 'MS', 'Microsoft', Color(0xFF00A4EF)),
  WordmarkBrand('adobe', 'A', 'Adobe', Color(0xFFFF0000)),
  WordmarkBrand('openai', 'AI', 'OpenAI', Color(0xFF10A37F)),
  WordmarkBrand('disneyplus', 'D+', 'Disney+', Color(0xFF113CCF)),
  WordmarkBrand('dominos', 'DP', "Domino's", Color(0xFF0078AE)),
  WordmarkBrand('flipkart', 'FK', 'Flipkart', Color(0xFF2874F0)),
  WordmarkBrand('myntra', 'My', 'Myntra', Color(0xFFFF3F6C)),
  WordmarkBrand('ola', 'Ola', 'Ola', Color(0xFF000000)),
];
