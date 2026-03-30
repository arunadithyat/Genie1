import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class CameraService {
  static final ImagePicker _picker = ImagePicker();

  /// Opens the device camera and returns the captured image file.
  /// Returns null if the user cancels.
  static Future<File?> capturePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80, // compress to reduce upload size
        preferredCameraDevice: CameraDevice.rear,
      );
      if (photo == null) return null;
      return File(photo.path);
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      return null;
    }
  }

  // Gallery access is intentionally disabled.
  // Users must capture photos using the device camera only.
}
