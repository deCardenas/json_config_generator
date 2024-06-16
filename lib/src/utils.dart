import 'package:analyzer/dart/element/element.dart';

void throwIf(bool condition, String message, {Element? element}) {
  if (condition) throwError(message, element: element);
}

void throwError(String message, {Element? element}) {
  throw InvalidGenerationSourceError(
    message,
    element: element,
  );
}

/// Error Generator class
class InvalidGenerationSourceError implements Exception {
  final String message;
  final Element? element;

  const InvalidGenerationSourceError(this.message, {this.element});

  @override
  String toString() =>
      '[ERROR] $message ${element != null ? 'in $element' : ''}';
}
