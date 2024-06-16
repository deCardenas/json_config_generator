import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:built_collection/built_collection.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:json_config_annotation/json_config_annotation.dart';
import 'package:json_config_generator/src/utils.dart';
import 'package:recase/recase.dart';
import 'package:source_gen/source_gen.dart';

/// Internal class that generate the Config class
class JsonConfigGenerator extends GeneratorForAnnotation<Configuration> {
  /// Unique constructor for the class
  const JsonConfigGenerator();

  @override
  generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    throwIf(
        !element.displayName.startsWith('\$'), 'class name must start with \$',
        element: element);
    final className = element.displayName.replaceAll('\$', '');
    final environmentEnumName =
        annotation.read('environmentEnumName').stringValue;
    final environments = annotation.read('environments').listValue;
    throwIf(environments.isEmpty, 'environments could not be empty',
        element: element);
    final environmentMap = generateEnvironmentMap(environments, element);
    final path = environmentMap.values.first;
    final Map<String, dynamic> config = await getConfigMap(path);
    if (environments.length == 1) {
      return mainClassGenerator(className, config, configFile: path);
    } else {
      throwIf(environmentEnumName.isEmpty,
          'environemntEnumName could not be empty');
      final environmentEnum =
          environmentEnumGenerator(environmentEnumName, environmentMap);
      return stringConverter(environmentEnum) +
          mainClassGenerator(className, config,
              environmentName: environmentEnumName,
              environmentMap: environmentMap);
    }
  }

  Future<Map<String, dynamic>> getConfigMap(String path) async {
    final jsonString = await File(path).readAsString();
    throwIf(jsonString.isEmpty, 'file in path "$path" could not be empty');
    Map<String, dynamic> map = await json.decode(jsonString);
    throwIf(map.isEmpty, 'file in path "$path" do not have fields');
    return map;
  }

  /// Method that generate a Map of environments
  Map<String, String> generateEnvironmentMap(
      List<DartObject> environments, Element element) {
    final map = Map<String, String>();
    environments.forEach((env) {
      final name = env.getField('name')?.toStringValue();
      throwIf(name == null || name.trim().isEmpty,
          'name could not be  empty in $env',
          element: element);
      final path = env.getField('path')?.toStringValue();
      throwIf(path == null || path.trim().isEmpty,
          'path could not be empty in $env',
          element: element);
      throwIf(
          map.containsKey(name),
          'every environment need to have distinct name. '
          '$name was already used',
          element: element);
      final fileName = path!.split('/').last;
      throwIf(!fileName.contains('.json'),
          'environment file "$fileName" must have extension ".json"',
          element: element);
      map[name!] = path;
    });
    return map;
  }

  /// Method that generate an Enum for environments
  Enum environmentEnumGenerator(String enumName, Map<String, String> map) {
    final builder = EnumBuilder()
      ..name = enumName
      ..values =
          ListBuilder(map.keys.map((e) => EnumValue((v) => v..name = e)));
    return builder.build();
  }

  /// Main method that generate the generated class
  String mainClassGenerator(String name, Map<String, dynamic> config,
      {String? environmentName,
      Map<String, String>? environmentMap,
      String? configFile}) {
    String initMethodBody = '';
    if (configFile != null) {
      initMethodBody += '''
      final jsonString = await rootBundle.loadString('$configFile');
      final ${name.camelCase} = json.decode(jsonString) as Map<String, dynamic>;
    ''';
    } else {
      initMethodBody = '''
      String path = '';
      switch(${environmentName!.camelCase}){
    ''';
      environmentMap!.entries.forEach((entry) => initMethodBody += '''
      case ${environmentName}.${entry.key}:
        path = '${entry.value}';
        break;
    ''');
      initMethodBody += '''
      }
      final jsonString = await rootBundle.loadString(path);
      final ${name.camelCase} = json.decode(jsonString) as Map<String, dynamic>;
    ''';
    }

    String subClasses = '';
    config.forEach((key, value) {
      final type = getType(key, value);
      if (value is Map) {
        subClasses += subClassesGenerator(key, value);
        initMethodBody +=
            '${key.camelCase}= _${key.pascalCase}.fromJson(${name.camelCase}[\'${key.snakeCase}\'] as Map<String,dynamic>);';
      } else if (type == 'List<_${key.pascalCase}>') {
        subClasses += subClassesGenerator(key, value);
        initMethodBody +=
            '${key.camelCase}= _${key.pascalCase}.listFromJson(${name.camelCase}[\'${key.snakeCase}\'] as List);';
      } else if (type.contains('List')) {
        final castType = type.replaceAll('List', '');
        initMethodBody +=
            '${key.camelCase}= (${name.camelCase}[\'${key.snakeCase}\'] as List).cast$castType();';
      } else {
        initMethodBody +=
            '${key.camelCase}= ${name.camelCase}[\'${key.snakeCase}\'] as $type;';
      }
    });
    final mainClass = Class(
      (c) => c
        ..name = name
        ..constructors.addAll([Constructor((c) => c..name = '_')])
        ..fields.addAll([
          Field((f) => f
            ..name = 'instance'
            ..static = true
            ..modifier = FieldModifier.final$
            ..assignment = Code('$name._()')),
          ...config
              .map((key, value) {
                return MapEntry(
                  key,
                  Field((f) => f
                    ..name = key.camelCase
                    ..late = true
                    ..type = refer(getType(key, value))),
                );
              })
              .values
              .toList()
        ])
        ..methods.addAll(
          [
            Method((m) => m
              ..name = 'init'
              ..modifier = MethodModifier.async
              ..requiredParameters = ListBuilder([
                if (environmentName != null && environmentMap != null)
                  Parameter((p) => p
                    ..name = environmentName.camelCase
                    ..type = refer(environmentName))
              ])
              ..body = Code(initMethodBody)
              ..returns = refer('Future<void>'))
          ],
        ),
    );
    return stringConverter(mainClass) + subClasses;
  }

  /// Helper method that generate subclasses
  String subClassesGenerator(String name, dynamic values) {
    Map<String, dynamic> data;
    String subClasses = '';
    bool isList = false;
    if (getType(name, values) == 'List<_${name.pascalCase}>') {
      data = (values as List).first;
      isList = true;
    } else if (values is Map<String, dynamic>) {
      data = values;
    } else {
      return '';
    }
    String factoryCode = '';
    factoryCode += '_${name.pascalCase}(';
    data.forEach((key, value) {
      final type = getType(key, value);
      if (value is Map) {
        subClasses += subClassesGenerator(key, value);
        factoryCode +=
            '${key.camelCase}: _${key.pascalCase}.fromJson(${name.camelCase}[\'${key.snakeCase}\'] as Map<String,dynamic>),';
      } else if (type == 'List<_${key.pascalCase}>') {
        subClasses += subClassesGenerator(key, value);
        factoryCode +=
            '${key.camelCase}: _${key.pascalCase}.listFromJson(${name.camelCase}[\'${key.snakeCase}\'] as List),';
      } else if (type.contains('List')) {
        final castType = type.replaceAll('List', '');
        factoryCode +=
            '${key.camelCase}= (${name.camelCase}[\'${key.snakeCase}\'] as List).cast$castType();';
      } else {
        factoryCode +=
            '${key.camelCase}: ${name.camelCase}[\'${key.snakeCase}\'] as $type,';
      }
    });
    factoryCode += ')';
    final subclass = Class(
      (c) => c
        ..name = '_${name.pascalCase}'
        ..fields.addAll(data
            .map(
              (key, value) => MapEntry(
                  key,
                  Field((f) => f
                    ..name = key.camelCase
                    ..type = refer(getType(key, value))
                    ..modifier = FieldModifier.final$)),
            )
            .values
            .toList())
        ..constructors.addAll(
          [
            Constructor((e) => e
              ..constant = true
              ..optionalParameters.addAll(data
                  .map(
                    (key, value) => MapEntry(
                      key,
                      Parameter((f) => f
                        ..name = key.camelCase
                        ..toThis = true
                        ..named = true
                        ..required = true),
                    ),
                  )
                  .values
                  .toList())),
            Constructor((e) => e
              ..factory = true
              ..name = 'fromJson'
              ..lambda = true
              ..requiredParameters.add(Parameter(
                (p) => p
                  ..type = refer('Map<String, dynamic>')
                  ..name = name.camelCase,
              ))
              ..body = Code(factoryCode)),
          ],
        )
        ..methods.addAll([
          if (isList)
            Method((m) => m
              ..static = true
              ..returns = refer('List<_${name.pascalCase}>')
              ..name = 'listFromJson'
              ..requiredParameters.add(
                Parameter((p) => p
                  ..name = 'data'
                  ..type = refer('List')),
              )
              ..lambda = true
              ..body = Code(
                  'data.map((e) => _${name.pascalCase}.fromJson(e as Map<String,dynamic>)).toList()'))
        ]),
    );
    return stringConverter(subclass) + subClasses;
  }

  /// Method that recognize value type
  String getType(String key, dynamic value) {
    if (value is String) {
      return 'String';
    } else if (value is bool) {
      return 'bool';
    } else if (value is int) {
      return 'int';
    } else if (value is double) {
      return 'double';
    } else if (value is List) {
      return 'List<${getType(key, value.first)}>';
    } else {
      return '_${key.pascalCase}';
    }
  }

  /// Method that generate the class string from Spec
  String stringConverter(Spec obj) {
    final emitter = DartEmitter(useNullSafetySyntax: true);
    return DartFormatter().format(obj.accept(emitter).toString());
  }
}
