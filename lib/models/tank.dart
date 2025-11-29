import 'package:flutter/foundation.dart';

@immutable
class Tank {
  final String id;
  final String name;
  final String imageUrl;

  const Tank({
    required this.id,
    required this.name,
    this.imageUrl = '',
  });

  Tank copyWith({String? id, String? name, String? imageUrl}) => Tank(
        id: id ?? this.id,
        name: name ?? this.name,
        imageUrl: imageUrl ?? this.imageUrl,
      );

  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'imageUrl': imageUrl};
  factory Tank.fromMap(Map<String, dynamic> map) => Tank(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        imageUrl: (map['imageUrl'] ?? '').toString(),
      );

  @override
  String toString() => 'Tank(id: $id, name: $name)';
  @override
  bool operator ==(Object other) => other is Tank && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

// Mock รายการตู้ (ถ้าไม่อยากมีรูปให้ตั้ง imageUrl = '')
final List<Tank> mockTanks = [
  Tank(id: 't1', name: 'Tank - Living Room'),
  Tank(id: 't2', name: 'Tank - Bedroom'),
  Tank(id: 't3', name: 'Tank - Office'),
];
