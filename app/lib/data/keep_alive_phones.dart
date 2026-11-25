/// The phone makers' skins, and what each calls the settings that keep an app
/// running in the background. Names are the ones the phone shows.
///
/// ColorOS was checked on a Realme phone. The others come from
/// dontkillmyapp.com and the makers' own help pages, and may be worded a
/// little differently on other versions: the guide says to look for the
/// closest match.
library;

enum PhoneFamily {
  stock,
  colorOs,
  originOs,
  hyperOs,
  oneUi,
  emui,
  transsion,
  asus;

  static PhoneFamily parse(Object? name) =>
      values.firstWhere((f) => f.name == name, orElse: () => PhoneFamily.stock);
}

/// One thing to do so Android leaves the app alone.
class KeepStep {
  const KeepStep({
    required this.id,
    required this.title,
    required this.todo,
    required this.howTo,
    required this.path,
    this.checked = false,
  });

  /// `battery`, `background` and `access` are asked of Android; any other id
  /// is a maker's own switch that no app can read, so the user says it is done.
  final String id;
  final String title;

  /// One short line for the row.
  final String todo;

  /// The longer explanation, for the guide page.
  final String howTo;

  /// Where to tap, for the guide page.
  final List<String> path;

  /// Whether Android can say if it is done.
  final bool checked;
}

class _Phone {
  const _Phone({
    required this.name,
    this.batteryChoice = 'Don’t optimize',
    this.batteryNote = '',
    this.accessName = 'Pause app activity if unused',
    this.vendor = const [],
  });
  final String name, batteryChoice, batteryNote, accessName;
  final List<KeepStep> vendor;
}

const _phones = {
  PhoneFamily.stock: _Phone(name: 'Android'),
  PhoneFamily.colorOs: _Phone(
    name: 'ColorOS (Realme, Oppo, OnePlus)',
    batteryChoice: 'Allow background activity',
    batteryNote: ' Smart mode is not enough.',
    accessName: 'Manage unused apps',
    vendor: [
      KeepStep(
        id: 'autostart',
        title: 'Autostart',
        todo: 'Allow it to start by itself',
        howTo:
            'Turn on Allow auto launch for Simple Money. Not on the screen '
            'that opens? Look in App info or Battery › App battery '
            'management.',
        path: ['Keep it working', 'Open', 'Allow auto launch'],
      ),
    ],
  ),
  PhoneFamily.originOs: _Phone(
    name: 'OriginOS (vivo, iQOO)',
    batteryChoice: 'Unrestricted',
    vendor: [
      KeepStep(
        id: 'highPower',
        title: 'High background power use',
        todo: 'Let it run when power use is high',
        howTo:
            'Open Battery, then High background power consumption, and turn '
            'on Simple Money.',
        path: [
          'Keep it working',
          'Open',
          'High background power consumption',
          'Simple Money',
        ],
      ),
      KeepStep(
        id: 'autostart',
        title: 'Autostart',
        todo: 'Allow it to start by itself',
        howTo:
            'Open Settings › More settings › Applications › Autostart and '
            'turn on Simple Money.',
        path: ['Keep it working', 'Open', 'Simple Money'],
      ),
    ],
  ),
  PhoneFamily.hyperOs: _Phone(
    name: 'HyperOS (Xiaomi, Redmi, POCO)',
    batteryChoice: 'No restrictions',
    vendor: [
      KeepStep(
        id: 'batterySaver',
        title: 'Battery saver: No restrictions',
        todo: 'Remove its battery limits',
        howTo:
            'Open App info › Battery saver (or Security › Battery › App '
            'Battery Saver) and choose No restrictions for Simple Money.',
        path: ['Keep it working', 'Open', 'Battery saver', 'No restrictions'],
      ),
      KeepStep(
        id: 'autostart',
        title: 'Autostart',
        todo: 'Allow it to start by itself',
        howTo:
            'Turn on Autostart for Simple Money (Settings › Apps › Manage '
            'apps › Simple Money). You can also lock it in Recent apps.',
        path: ['Keep it working', 'Open', 'Autostart'],
      ),
    ],
  ),
  PhoneFamily.oneUi: _Phone(
    name: 'One UI (Samsung)',
    vendor: [
      KeepStep(
        id: 'neverSleeping',
        title: 'Never auto sleeping apps',
        todo: 'Keep it out of Samsung’s sleep lists',
        howTo:
            'Open Battery › Background usage limits › Never auto sleeping '
            'apps, tap + and add Simple Money. Also turn off Put unused apps '
            'to sleep.',
        path: [
          'Keep it working',
          'Open',
          'Never auto sleeping apps',
          'Simple Money',
        ],
      ),
    ],
    accessName: 'Remove permissions if app isn’t used',
  ),
  PhoneFamily.emui: _Phone(
    name: 'EMUI, HarmonyOS, MagicOS (Huawei, Honor)',
    batteryChoice: 'Allowed',
    vendor: [
      KeepStep(
        id: 'appLaunch',
        title: 'App launch',
        todo: 'Manage it manually',
        howTo:
            'Open Battery › App launch, find Simple Money, choose Manage '
            'manually, and turn on all three switches.',
        path: ['Keep it working', 'Open', 'Manage manually'],
      ),
    ],
  ),
  PhoneFamily.transsion: _Phone(
    name: 'HiOS, XOS (Tecno, Infinix, itel)',
    vendor: [
      KeepStep(
        id: 'autostart',
        title: 'Auto-start management',
        todo: 'Allow it to start by itself',
        howTo:
            'Open Phone Master › Toolbox › Auto-start management and allow '
            'Simple Money to run in the background.',
        path: ['Phone Master', 'Toolbox', 'Auto-start management'],
      ),
      KeepStep(
        id: 'powerSaving',
        title: 'Power saving for apps',
        todo: 'Turn off its power saving',
        howTo:
            'Open Settings › Battery Lab › Battery Saving Settings and turn '
            'off Power Saving Management For Apps.',
        path: [
          'Keep it working',
          'Open',
          'Battery Saving Settings',
          'Power Saving Management For Apps',
        ],
      ),
    ],
  ),
  PhoneFamily.asus: _Phone(
    name: 'ZenUI (Asus)',
    vendor: [
      KeepStep(
        id: 'powerMaster',
        title: 'PowerMaster',
        todo: 'Stop it cleaning up the app',
        howTo:
            'Open Mobile Manager › PowerMaster › Settings and turn off '
            'Clean up in suspend and Auto-deny apps from auto starting.',
        path: ['Mobile Manager', 'PowerMaster', 'Settings'],
      ),
    ],
  ),
};

/// The phone maker's skin, as a name for the guide.
String phoneName(PhoneFamily family) => _phones[family]!.name;

/// The steps for a phone of [family], in the order to do them: what Android
/// can check, then the maker's own switches.
List<KeepStep> keepStepsFor(PhoneFamily family, {bool access = true}) {
  final p = _phones[family]!;
  return [
    KeepStep(
      id: 'battery',
      title: 'Battery: Unrestricted',
      todo: 'Set Simple Money to ${p.batteryChoice}',
      howTo:
          'Android lists your apps. Find Simple Money and choose '
          '${p.batteryChoice}.${p.batteryNote}',
      path: ['Keep it working', 'Allow', 'Simple Money', p.batteryChoice],
      checked: true,
    ),
    const KeepStep(
      id: 'background',
      title: 'Background activity',
      todo: 'Let it run in the background',
      howTo:
          'Open the app’s battery settings and choose Unrestricted, so '
          'Android doesn’t limit what it does in the background.',
      path: ['Keep it working', 'Open', 'Battery', 'Unrestricted'],
      checked: true,
    ),
    // Android 11 and newer take back permissions of unused apps.
    if (access)
      KeepStep(
        id: 'access',
        title: 'Keep SMS access',
        // The exact switch on this phone, so there is nothing to work out.
        todo: 'Turn off “${p.accessName}”',
        howTo:
            'If you don’t open an app for a few months, Android removes its '
            'permissions, such as SMS access. SimpleMoney would then quietly '
            'stop adding transactions. Turn off “${p.accessName}” for '
            'Simple Money so that doesn’t happen.',
        path: ['Keep it working', 'Open', p.accessName],
        checked: true,
      ),
    ...p.vendor,
  ];
}
