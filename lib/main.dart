import 'dart:async';
import 'package:geolocator/geolocator.dart';

import 'Screen/splash.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:overlay_support/overlay_support.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

Future<void> main() async {

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.blueAccent
  ));

  await dotenv.load(fileName: ".env");

  WidgetsFlutterBinding.ensureInitialized();

  runApp(const OverlaySupport.global(child: Myapp()));
}

class Myapp extends StatefulWidget {
  const Myapp({super.key});

  @override
  State<Myapp> createState() => _MyappState();
}

class _MyappState extends State<Myapp> {
  late IO.Socket socket;
  @override
  void initState() {
    super.initState();
 _requestPermissions();
  }

    Future<void> _requestPermissions() async {
    PermissionStatus microphoneStatus = await Permission.microphone.request();
    PermissionStatus phoneStatus = await Permission.phone.request();
  }

  void showCustomNotification(String message) {
    showSimpleNotification(
      Text("📩 New Message"),
      subtitle: Text(message),
      background: Colors.green[600],
      duration: Duration(seconds: 4),
      slideDismiss: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        useMaterial3: true,
        fontFamily: 'Roboto', // Flutter's built-in font, similar to Poppins
        appBarTheme: const AppBarTheme(
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            systemNavigationBarColor: Colors.white,
            systemNavigationBarIconBrightness: Brightness.dark,
          ),
          backgroundColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.normal,
            color: Colors.white,
            fontFamily: 'Roboto',
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurple,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontSize: 16, fontFamily: 'Roboto'),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      home: Splash(),
    );
  }
}
