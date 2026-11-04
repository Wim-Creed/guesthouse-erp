import 'package:flutter/services.dart';

// ====================================================================
// THE ONE NAME RULE (the app's copy; the server has the identical rule)
// ====================================================================
// Every name typed anywhere in the app — a guest, an employee, a room
// type, a shop item, a daily-cost item — gets each word's first letter in
// capitals and the rest in lowercase: "mineral water", "MINERAL WATER" and
// "mInEral wAter" all become "Mineral Water".
//
// Abbreviations and brand names are the exception and stay exactly as
// typed. The rule, in plain words:
//   1. A word containing a digit is kept as typed ("A4", "B12").
//   2. A word typed in capitals, four letters or fewer, is an
//      abbreviation or brand and is kept as typed ("TV", "AC", "UP",
//      "USB", "WIFI") ...
//   3. ... UNLESS the whole entry is typed in capitals and has more than
//      one word ("MINERAL WATER" is shouting, not two abbreviations). An
//      entry that is just one such word ("TV") is kept as typed.
//   4. Every other word: first letter capital, the rest lowercase.
//
// People's names are the one place rules 2 and 3 do not apply
// (keepAbbreviations: false): "KOFI" and "AMA" are names, not
// abbreviations, so they become "Kofi" and "Ama".
//
// The server applies this same rule again before anything is saved, so
// even an old tablet or a queued offline action can never store a
// different spelling. These examples are the ones checked on both sides:
//   "tv room" -> "Tv Room"      "TV room" -> "TV Room"
//   "A4" -> "A4"              "mineral water" -> "Mineral Water"
//   "MINERAL WATER" -> "Mineral Water"   "ac" -> "Ac"   "AC" -> "AC"
//   "juice" -> "Juice"          "USB" -> "USB"

final RegExp _wordPattern = RegExp(r'\S+');
final RegExp _lettersOnly = RegExp(r'^\p{L}+$', unicode: true);
final RegExp _anyLetter = RegExp(r'\p{L}', unicode: true);
final RegExp _anyDigit = RegExp(r'\d');

/// Capitalises one word that has already been judged an ordinary word:
/// first letter capital, the rest lowercase, and a letter right after a
/// hyphen also starts a new part ("mary-jane" -> "Mary-Jane").
String _capitaliseOrdinaryWord(String word) {
  final StringBuffer out = StringBuffer();
  bool startOfPart = true;
  for (final String character in word.split('')) {
    if (_anyLetter.hasMatch(character)) {
      out.write(startOfPart ? character.toUpperCase() : character.toLowerCase());
      startOfPart = false;
    } else {
      out.write(character);
      startOfPart = character == '-';
    }
  }
  return out.toString();
}

/// Applies the case part of the rule to [text] WITHOUT touching spacing,
/// so it is safe to run on every keystroke (the length never changes,
/// which is what keeps the cursor from jumping while someone types).
String applyNameCase(String text, {bool keepAbbreviations = true}) {
  final List<String> words = _wordPattern.allMatches(text).map((m) => m.group(0)!).toList();
  if (words.isEmpty) return text;

  final String lettersOnlyText = text.split('').where(_anyLetter.hasMatch).join();
  final bool wholeEntryInCapitals = words.length > 1 &&
      lettersOnlyText.isNotEmpty &&
      lettersOnlyText == lettersOnlyText.toUpperCase();

  return text.replaceAllMapped(_wordPattern, (match) {
    final String word = match.group(0)!;
    if (_anyDigit.hasMatch(word)) return word;
    final bool looksLikeAbbreviation = _lettersOnly.hasMatch(word) &&
        word == word.toUpperCase() &&
        word.length <= 4;
    if (keepAbbreviations && !wholeEntryInCapitals && looksLikeAbbreviation) return word;
    return _capitaliseOrdinaryWord(word);
  });
}

/// The final, tidy form of a name: case rule applied, extra spaces
/// squeezed to one, ends trimmed. This is what is shown and sent.
String canonicalName(String text, {bool keepAbbreviations = true}) {
  final String squeezed = text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  return applyNameCase(squeezed, keepAbbreviations: keepAbbreviations);
}

/// Applies the name rule as it is typed, so staff never have to reach for
/// shift themselves. WHILE TYPING it only does the safe, one-way part:
/// the first letter of each word becomes a capital, and nothing else is
/// changed. It deliberately does not lowercase the rest as you type:
/// whether "WATER" is an abbreviation or just caps-lock depends on the
/// WHOLE entry ("TV room" versus "MINERAL WATER"), which is only known once
/// typing is finished, and lowercasing letter by letter would destroy that
/// information. The complete rule (canonicalName above) is applied when
/// the entry is saved, and again by the server, so what is stored and
/// shown everywhere is always "Mineral Water".
///
/// Letters, spacing, punctuation and digits are otherwise left exactly as
/// typed, and the cursor position is preserved (the length never changes).
///
/// The [keepAbbreviations] flag is kept so every screen can say whether it
/// is a person's name (false) or an item/room/cost name (true); it matters
/// when the entry is saved, not while typing.
class CapitalizeWordsFormatter extends TextInputFormatter {
  final bool keepAbbreviations;

  CapitalizeWordsFormatter({this.keepAbbreviations = true});

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue;

    final StringBuffer buffer = StringBuffer();
    bool atWordStart = true;
    for (final String character in newValue.text.split('')) {
      if (atWordStart && character.trim().isNotEmpty) {
        buffer.write(character.toUpperCase());
      } else {
        buffer.write(character);
      }
      atWordStart = character.trim().isEmpty;
    }

    final String formatted = buffer.toString();
    // Upper-casing a character can, for a few unusual letters, change the
    // length; if so, leave what was typed alone rather than move the cursor.
    if (formatted == newValue.text || formatted.length != newValue.text.length) return newValue;
    return newValue.copyWith(text: formatted);
  }
}
