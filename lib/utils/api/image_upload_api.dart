import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class ImageUploadApi {
  /// Uploads a single image file to the ERPNext Event doctype
  /// via Frappe's /api/method/upload_file endpoint.
  ///
  /// [filePath] - local path of the captured image
  /// [docname]  - ERPNext Event document name (e.g. "EV-00123")
  ///
  /// Returns the uploaded file URL on success, null on failure.
  static Future<String?> uploadImageToEvent({
    required String filePath,
    required String docname,
    BuildContext? context,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? token = prefs.getString('token');
      final String baseUrl = dotenv.env['SITE_URL'] ?? '';

      if (token == null || token.isEmpty) {
        debugPrint('❌ No auth token found.');
        return null;
      }

      if (baseUrl.isEmpty) {
        debugPrint('❌ SITE_URL not set in .env');
        return null;
      }

      final file = File(filePath);
      if (!file.existsSync()) {
        debugPrint('❌ Image file does not exist: $filePath');
        return null;
      }

      final fileName = p.basename(filePath);
      final uploadUrl = '$baseUrl/api/method/upload_file';

      var request = http.MultipartRequest('POST', Uri.parse(uploadUrl));

      // Frappe upload_file fields
      request.fields['doctype'] = 'Event';
      request.fields['docname'] = docname;
      request.fields['fieldname'] = 'custom_event_images';
      request.fields['is_private'] = '0';

      request.headers['Authorization'] = token;

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          filePath,
          filename: fileName,
        ),
      );

      debugPrint('📤 Uploading image "$fileName" to Event: $docname ...');

      final streamedResponse = await request.send();
      final responseBody = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode == 200) {
        final jsonResponse = jsonDecode(responseBody);
        final fileUrl = jsonResponse['message']?['file_url'];
        debugPrint('✅ Image uploaded successfully: $fileUrl');
        return fileUrl;
      } else {
        debugPrint(
          '❌ Upload failed [${streamedResponse.statusCode}]: $responseBody',
        );
        return null;
      }
    } catch (e) {
      debugPrint('❌ Image upload exception: $e');
      return null;
    }
  }

  /// Uploads multiple images and returns a list of uploaded file URLs.
  static Future<List<String>> uploadMultipleImages({
    required List<String> filePaths,
    required String docname,
    BuildContext? context,
  }) async {
    final List<String> uploadedUrls = [];
    for (final path in filePaths) {
      final url = await uploadImageToEvent(
        filePath: path,
        docname: docname,
        context: context,
      );
      if (url != null) uploadedUrls.add(url);
    }
    debugPrint('✅ Uploaded ${uploadedUrls.length}/${filePaths.length} images.');
    return uploadedUrls;
  }
}
