import 'package:venera_unified/foundation/translations.dart';
import 'source_failure.dart';

String sourceFailureMessage(Object error) =>
    error is SourceFailure ? error.code.message.tl : error.toString();
