/// What a recurring payment's name says about it: the artwork and category
/// someone typing "Rent" or "Electricity" most likely wants.
class RecurringSuggestion {
  const RecurringSuggestion({this.icon, this.category});

  /// An app icon key, or null when the name says nothing about artwork.
  final String? icon;

  /// A category name as it is spelled in the default categories.
  final String? category;
}

/// The suggestion for [name], or null when nothing in it is recognised.
/// [incoming] picks between the money-in and money-out readings of a word
/// like "rent".
RecurringSuggestion? suggestRecurring(String name, {required bool incoming}) {
  final words = name.toLowerCase();
  if (words.trim().isEmpty) return null;
  final rules = incoming ? _incoming : _outgoing;
  for (final rule in rules) {
    if (RegExp(rule.$1).hasMatch(words)) {
      return RecurringSuggestion(icon: rule.$2, category: rule.$3);
    }
  }
  return null;
}

// Most specific first: "health insurance" before "insurance".
const _outgoing = <(String, String, String)>[
  (r'\b(?:rent|lease|landlord|pg|hostel)\b', 'rent', 'Rent'),
  (
    r'\b(?:electric\w*|power\s*bill|current\s*bill|bescom|kseb|tneb)\b',
    'lightning',
    'Electricity',
  ),
  (r'\bwater\b', 'water_rate', 'Water'),
  (r'\b(?:wifi|wi-fi|broadband|internet|fibre|fiber)\b', 'wifi', 'Internet'),
  (r'\b(?:recharge|prepaid|postpaid)\b', 'mobile_recharge', 'Mobile Recharge'),
  (r'\b(?:mobile|phone|sim)\b', 'phone', 'Mobile'),
  (r'\bhealth\s*insurance\b|\bmediclaim\b', 'hospital_two', 'Health Insurance'),
  (r'\b(?:car|bike|vehicle|motor)\s*insurance\b', 'car', 'Vehicle Insurance'),
  (r'\b(?:home|house)\s*insurance\b', 'home_two', 'Home Insurance'),
  (r'\b(?:life\s*insurance|lic|term\s*plan)\b', 'insurance', 'Life Insurance'),
  (r'\b(?:insurance|premium)\b', 'insurance', 'Insurance'),
  (r'\b(?:gym|fitness|yoga|cult|crossfit|swimming)\b', 'gym', 'Gym & Sports'),
  (
    r'\b(?:school|tuition|college|course|coaching|fees?)\b',
    'school',
    'Education',
  ),
  (r'\b(?:maid|cook|cleaning|housekeeping)\b', 'cleaning', 'Cleaning'),
  (r'\blaundry\b', 'washing_machine', 'Laundry'),
  (r'\b(?:nanny|daycare|creche|childcare)\b', 'baby', 'Childcare'),
  (
    r'\b(?:doctor|clinic|medicine|pharmacy)\b',
    'medicine_bottle',
    'Health & Fitness',
  ),
  (r'\b(?:music|spotify|gaana|wynk)\b', 'music_one', 'Subscriptions'),
  (
    r'\b(?:netflix|prime|hotstar|disney|youtube|ott|streaming)\b',
    'subscriptions',
    'Subscriptions',
  ),
  (
    r'\b(?:cloud|storage|icloud|google\s*one|dropbox)\b',
    'subscriptions',
    'Subscriptions',
  ),
];

const _incoming = <(String, String, String)>[
  (r'\b(?:rent|lease|tenant)\b', 'rent', 'Rental Income'),
  (r'\b(?:salary|pay\s*check|paycheck|wages?)\b', 'salary', 'Salary'),
  (r'\b(?:pension|annuity)\b', 'deposit', 'Other Income'),
  (r'\b(?:interest|fd|fixed\s*deposit)\b', 'deposit', 'Interest'),
  (r'\bdividends?\b', 'stock_market', 'Dividends'),
  (r'\b(?:freelance|retainer|client)\b', 'paper_money_two', 'Freelance'),
];
