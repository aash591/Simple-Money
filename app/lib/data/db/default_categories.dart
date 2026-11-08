/// Categories a fresh install starts with, so a new user doesn't stare at an
/// empty list before recording anything. Every one of them can be edited or
/// deleted like any other category — there's nothing special about a default
/// once it's on the device. Fresh installs seed the whole collection; upgrades
/// add only the explicitly introduced SMS-purpose categories below.
library;

typedef DefaultCategory = ({
  String name,
  String icon,
  List<DefaultSub> children,
});
typedef DefaultSub = ({String name, String icon});
typedef DefaultCategoryGroup = ({
  String type,
  List<DefaultCategory> categories,
});

const smsPurposeCategories = [
  (name: 'Credit Card Repayment', type: 'expense', icon: 'bank_card'),
  (name: 'Credit Card Repayment', type: 'income', icon: 'bank_card'),
  (name: 'ATM Deposit', type: 'income', icon: 'atm'),
  (name: 'Cash Deposit', type: 'income', icon: 'deposit'),
  (name: 'ATM Withdrawal', type: 'expense', icon: 'atm'),
  (name: 'Bank Charges', type: 'expense', icon: 'bank'),
  (name: 'Personal', type: 'expense', icon: 'person'),
  (name: 'Personal', type: 'income', icon: 'person'),
];

const publicTransportSubcategories = <DefaultSub>[
  (name: 'Bus', icon: 'bus_two'),
  (name: 'Train', icon: 'train'),
  (name: 'Cab', icon: 'taxi'),
];

const lifestyleCategories = [
  (
    name: 'Travel Trip',
    icon: 'travel_trip',
    parent: 'Travel',
    parentIcon: 'airplane',
  ),
  (
    name: 'Wellness',
    icon: 'wellness',
    parent: 'Health & Fitness',
    parentIcon: 'hospital_two',
  ),
  (
    name: 'Emergency Fund',
    icon: 'emergency_fund',
    parent: null,
    parentIcon: 'emergency_fund',
  ),
];

const defaultCategoryGroups = <DefaultCategoryGroup>[
  (
    type: 'expense',
    categories: [
      (
        name: 'Food & Beverage',
        icon: 'fork_spoon',
        children: [
          (name: 'Restaurants', icon: 'hamburger'),
          (name: 'Groceries', icon: 'shopping_cart_one'),
          (name: 'Fruits', icon: 'fruits'),
          (name: 'Cafe', icon: 'coffee_machine'),
        ],
      ),
      (
        name: 'Shopping',
        icon: 'shopping_bag',
        children: [
          (name: 'Clothing', icon: 'clothes_short_sleeve'),
          (name: 'Electronics', icon: 'electronics'),
          (name: 'Footwear', icon: 'shoes'),
          (name: 'Accessories', icon: 'accessories'),
          (name: 'Beauty & Personal Care', icon: 'personal_care'),
          (name: 'Home Decor', icon: 'home_decor'),
          (name: 'Gifts', icon: 'gift_box'),
        ],
      ),
      (
        name: 'Transportation',
        icon: 'car',
        children: [
          (name: 'Fuel', icon: 'fuel'),
          (name: 'Parking', icon: 'parking'),
          (name: 'Tolls', icon: 'toll'),
        ],
      ),
      (
        name: 'Public Transport',
        icon: 'bus_two',
        children: publicTransportSubcategories,
      ),
      (
        name: 'Bills & Utilities',
        icon: 'lightning',
        children: [
          (name: 'Electricity', icon: 'lightning'),
          (name: 'Water', icon: 'water_rate'),
          (name: 'Internet', icon: 'wifi'),
          (name: 'Mobile', icon: 'phone'),
          (name: 'Mobile Recharge', icon: 'mobile_recharge'),
          (name: 'Subscriptions', icon: 'subscriptions'),
        ],
      ),
      (
        name: 'Health & Fitness',
        icon: 'hospital_two',
        children: [
          (name: 'Pharmacy', icon: 'medicine_bottle'),
          (name: 'Doctor', icon: 'doctor'),
          (name: 'Gym & Sports', icon: 'gym'),
          (name: 'Wellness', icon: 'wellness'),
        ],
      ),
      (
        name: 'Entertainment',
        icon: 'movie',
        children: [
          (name: 'Movies', icon: 'popcorn_one'),
          (name: 'Music', icon: 'music_one'),
          (name: 'Games', icon: 'game_handle'),
        ],
      ),
      (
        name: 'Housing',
        icon: 'home_two',
        children: [
          (name: 'Rent', icon: 'rent'),
          (name: 'Furniture', icon: 'sofa_two'),
          (name: 'Laundry', icon: 'washing_machine'),
          (name: 'Cleaning', icon: 'cleaning'),
          (name: 'Repairs', icon: 'tools'),
        ],
      ),
      (
        name: 'Travel',
        icon: 'airplane',
        children: [
          (name: 'Hotels', icon: 'homestay'),
          (name: 'Flights', icon: 'airplane'),
          (name: 'Luggage', icon: 'luggage'),
          (name: 'Travel Trip', icon: 'travel_trip'),
        ],
      ),
      (
        name: 'Education',
        icon: 'school',
        children: [(name: 'Books', icon: 'book_one')],
      ),
      (
        name: 'Family',
        icon: 'family',
        children: [
          (name: 'Childcare', icon: 'baby'),
          (name: 'Pets', icon: 'pets'),
        ],
      ),
      (
        name: 'Friends & Love',
        icon: 'friends',
        children: [
          (name: 'Friends', icon: 'friends'),
          (name: 'Partner', icon: 'partner'),
          (name: 'Dates', icon: 'restaurant'),
        ],
      ),
      (
        name: 'Insurance',
        icon: 'insurance',
        children: [
          (name: 'Health Insurance', icon: 'hospital_two'),
          (name: 'Vehicle Insurance', icon: 'car'),
          (name: 'Home Insurance', icon: 'home_two'),
          (name: 'Life Insurance', icon: 'insurance'),
        ],
      ),
      (name: 'Other Expense', icon: 'shield', children: []),
      (name: 'Emergency Fund', icon: 'emergency_fund', children: []),
      (name: 'Credit Card Repayment', icon: 'bank_card', children: []),
      (name: 'ATM Withdrawal', icon: 'atm', children: []),
      (name: 'Bank Charges', icon: 'bank', children: []),
      (name: 'Charity', icon: 'charity', children: []),
      (name: 'Personal', icon: 'person', children: []),
    ],
  ),
  (
    type: 'income',
    categories: [
      (
        name: 'Salary',
        icon: 'salary',
        children: [(name: 'Bonus', icon: 'bonus')],
      ),
      (
        name: 'Business',
        icon: 'stock_market',
        children: [(name: 'Freelance', icon: 'paper_money_two')],
      ),
      (name: 'Gifts', icon: 'gift_box', children: []),
      (
        name: 'Investments',
        icon: 'investment',
        children: [
          (name: 'Interest', icon: 'deposit'),
          (name: 'Dividends', icon: 'stock_market'),
        ],
      ),
      (name: 'Rental Income', icon: 'rent', children: []),
      (name: 'Refunds', icon: 'bank_transfer', children: []),
      (name: 'Other Income', icon: 'wallet_one', children: []),
      (name: 'Credit Card Repayment', icon: 'bank_card', children: []),
      (name: 'ATM Deposit', icon: 'atm', children: []),
      (name: 'Cash Deposit', icon: 'deposit', children: []),
      (name: 'Personal', icon: 'person', children: []),
    ],
  ),
  (
    type: 'debt_loan',
    categories: [
      (name: 'Debt', icon: 'credit', children: []),
      (name: 'Debt Collection', icon: 'bank_card', children: []),
      (name: 'Loan', icon: 'bank', children: []),
      (name: 'Repayment', icon: 'bank_transfer', children: []),
    ],
  ),
];
