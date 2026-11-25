import 'package:flutter/material.dart';

import '../../../../data/keep_alive_phones.dart';
import '../../../components/info_guide.dart';

/// The ⓘ page of Keep it working: why Android stops apps, and where each
/// setting is on this phone. The steps match the screen's rows, worded the
/// way the phone's maker words them.
InfoGuide keepWorkingGuideFor(PhoneFamily family, {bool access = true}) =>
    InfoGuide(
      title: 'About Keep it working',
      headline: 'Keep transactions arriving',
      summary:
          'To save battery, Android puts apps it thinks are idle to sleep. A '
          'sleeping app misses bank SMS and notifications, so transactions '
          'show up late, or not at all. These settings tell your phone '
          '(${phoneName(family)}) to leave SimpleMoney alone. Wording can '
          'differ a little between versions: look for the closest match.',
      art: const Icon(Icons.bolt_rounded, size: 44),
      steps: [
        for (final step in keepStepsFor(family, access: access))
          GuideStep(step.title, step.howTo, path: step.path),
      ],
      footnote:
          'These are Android settings. SimpleMoney sends nothing anywhere.',
    );
