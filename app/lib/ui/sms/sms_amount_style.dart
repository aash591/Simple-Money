import 'package:flutter/material.dart';

import '../../data/repositories/sms_import_repository.dart';
import '../theme/app_theme.dart';

Color smsAmountColor(PendingSmsImport sms) => sms.credit
    ? green
    : sms.creditCard
    ? Colors.orange
    : Colors.red;
