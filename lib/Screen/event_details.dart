import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:homegenie/Screen/login.dart';

import '../utils/api/event.dart';
import '../utils/api/image_upload_api.dart';
import '../utils/widget/camera_service.dart';
import '../utils/widget/geofence_manager.dart';
import '../utils/widget/warning.dart';
import 'package:geofence_service/geofence_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../utils/api/location_api.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:phone_state/phone_state.dart';
import '../utils/widget/location_tracker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:homegenie/utils/widget/audio_recording_service.dart';

class EventDetails extends StatefulWidget {
  final String eventid;

  const EventDetails({super.key, required this.eventid});

  @override
  State<EventDetails> createState() => _EventDetailsState();
}

class _EventDetailsState extends State<EventDetails> {
  Map<String, dynamic> eventData = {};

  bool _isLoading = false;
  bool _isActionInProgress = false;
  bool _isFileLoaded = false;
  bool _isPlaying = false;
  bool _wasRecordingBeforeCall = false;
  bool _shouldStartNewRecordingAfterCall = false;

  bool _manualRecording = false;
  bool _isRecording = false;

  // ── Photo capture ──────────────────────────────────────────────────────────
  final List<File> _capturedPhotos = [];
  bool _isUploadingPhoto = false;

  // ── Geofence ───────────────────────────────────────────────────────────────
  GeofenceStatus? _geofenceStatus;

  Duration _recordingDuration = Duration.zero;
  Timer? _durationTimer;
  ValueNotifier<Duration>? _timerNotifier;

  final AudioPlayer _audioPlayer = AudioPlayer();
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    _checkPing();
    _listenToPhoneState();
    GeofenceManager.initialize();
  }

  Future<void> _startManualRecording() async {
    await AudioRecordingService().startRecording();
    setState(() {
      _isRecording = true;
      _manualRecording = true;
    });
  }

  Future<void> _stopManualRecording() async {
    await AudioRecordingService().stopRecording();
    setState(() {
      _isRecording = false;
      _manualRecording = false;
    });
  }

  void _listenToPhoneState() async {
    await Permission.phone.request();

    PhoneState.stream.listen((PhoneState state) async {
      final status = state.status;
      final recordingService = AudioRecordingService();

      if ((status == PhoneStateStatus.CALL_INCOMING ||
          status == PhoneStateStatus.CALL_STARTED)) {
        if (recordingService.isRecording && !recordingService.isPaused) {
          await recordingService.pauseRecording();
          _wasRecordingBeforeCall = true;
        }

        if (status == PhoneStateStatus.CALL_STARTED) {
          _shouldStartNewRecordingAfterCall = true;
        }
      } else if (status == PhoneStateStatus.CALL_ENDED &&
          _wasRecordingBeforeCall) {
        if (_shouldStartNewRecordingAfterCall) {
          await recordingService.stopRecording();

          final path = recordingService.lastRecordingPath;
          if (path != null && File(path).existsSync()) {
            final duration = await _getAudioDuration(path);
            if (duration.inSeconds < 1) {
              File(path).deleteSync();
            }
          }

          await recordingService.startRecording();
        } else {
          await recordingService.resumeRecording();
        }

        _wasRecordingBeforeCall = false;
        _shouldStartNewRecordingAfterCall = false;
      }
    });
  }

  Future<Duration> _getAudioDuration(String path) async {
    final player = AudioPlayer();
    try {
      await player.setFilePath(path);
      return player.duration ?? Duration.zero;
    } catch (_) {
      return Duration.zero;
    } finally {
      await player.dispose();
    }
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "${twoDigits(d.inHours)}:$minutes:$seconds";
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    GeofenceManager.instance.stopMonitoring();
    super.dispose();
  }



  
  // ── Geofence ───────────────────────────────────────────────────────────────

  Future<void> _startGeofenceForEvent(double lat, double lng) async {
    GeofenceManager.instance.onStatusChange = (id, status) {
      if (!mounted) return;
      setState(() => _geofenceStatus = status);

      final msg = status == GeofenceStatus.ENTER
          ? '📍 You have entered the event zone.'
          : status == GeofenceStatus.EXIT
              ? '🚪 You have left the event zone.'
              : '⏱ You are still within the event zone.';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: status == GeofenceStatus.ENTER
              ? Colors.green
              : status == GeofenceStatus.EXIT
                  ? Colors.orange
                  : Colors.blue,
        ),
      );
    };

    await GeofenceManager.instance.startMonitoring(
      eventId: widget.eventid,
      latitude: lat,
      longitude: lng,
      radiusMeters: 200,
    );
  }

  // ── Photo capture & upload ─────────────────────────────────────────────────

  Future<void> _captureAndUploadPhoto() async {
    // Opens camera directly — no gallery option
    final file = await CameraService.capturePhoto();
    if (file == null) return;

    setState(() {
      _capturedPhotos.add(file);
      _isUploadingPhoto = true;
    });

    try {
      final url = await ImageUploadApi.uploadImageToEvent(
        filePath: file.path,
        docname: widget.eventid,
        context: context,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              url != null
                  ? '✅ Photo uploaded to Event successfully!'
                  : '❌ Photo upload failed. Please try again.',
            ),
            backgroundColor: url != null ? Colors.green : Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  Future<void> _checkPing() async {
    try {
              var connectivity = await Connectivity().checkConnectivity();

    bool noInternet = false;

    if (connectivity == ConnectivityResult.none) {
      noInternet = true;
    }

    if (connectivity is List && connectivity.contains(ConnectivityResult.none)) {
      noInternet = true;
    }

    if (noInternet) {
      Warning.show(
        context,
        'No Internet Connection! Please check your network.',
        'Error',
      );
      return;
    }
      var pingResult = await Check.pingpong();
      if (pingResult == false) {
        Warning.show(
          context,
          'ERP Site is not in working condition! Please try again later.',
          'Error',
        );
      } else {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('token') ?? "";
        final email = prefs.getString('email') ?? "";

        final sessionValid = await Check.sessionActive(token, email);

        if (!sessionValid) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Session expired. Please log in again."),
              backgroundColor: Colors.red,
            ),
          );
          await prefs.clear();
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const Login()),
            (route) => false,
          );
          return;
        }
                setState(() {
          _isLoading = false;
        });
        _init();

      }
    } catch (e) {
      print('Error during ping: $e');
    }
  }

  Future<void> _init() async {
    prefs = await SharedPreferences.getInstance();
    await _fetchData();
    setState(() {});
  }

  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
    });

    await Future.wait([_fetchEventDetails()]);

    setState(() {
      _isLoading = false;
    });
  }

String _formatTime(String? dateTime) {
  if (dateTime == null || dateTime.isEmpty) return "--:--";

  try {
    DateTime dt = DateTime.parse(dateTime);
    String period = dt.hour >= 12 ? "pm" : "am";
    int hour = dt.hour > 12 ? dt.hour - 12 : dt.hour == 0 ? 12 : dt.hour;
    String minute = dt.minute.toString().padLeft(2, '0');
    return "$hour:$minute$period";
  } catch (e) {
    return "--:--";
  }
}


  String _calculateWorkingHours(String? checkIn, String? checkOut) {
    if (checkIn == null || checkOut == null) return "--:--";

    try {
      DateTime inTime = DateTime.parse(checkIn);
      DateTime outTime = DateTime.parse(checkOut);

      Duration difference = outTime.difference(inTime);

      int hours = difference.inHours;
      int minutes = difference.inMinutes.remainder(60);

      return "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}";
    } catch (e) {
      return "--:--";
    }
  }

  Future<void> _fetchEventDetails() async {
    final response = await Event.eventdetails(widget.eventid, context);
    if (response != Null) {
      setState(() {
        eventData = response;
      });
    }
  }

  String _getParticipantsTitles() {
    final participants = eventData['reference_details'];
    if (participants == null || participants is! List) return '';

    List<String> titles =
        participants
            .map<String>((p) => "${p['opportunity_from']}-${p['party_name']}")
            .toList();

    return titles.join(', ');
  }

  Future<String> _getCurrentLocationAddress() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final address = await LocationHelper.getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (address.isNotEmpty) {
        return address;
      } else {
        return "Unknown location";
      }
    } catch (e) {
      print("Error fetching location: $e");
      return "Error fetching location";
    }
  }

  Future<bool> _handleLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      Warning.show(context, 'Location services are disabled.', 'Error');
      return false;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        Warning.show(context, 'Location permission denied.', 'Error');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      Warning.show(
        context,
        'Location permission permanently denied. Please enable it from settings.',
        'Error',
      );
      return false;
    }

    return true;
  }

  Future<void> uploadAudioToERPNext({
    required String filePath,
    required String doctype,
    required String docname,
    required String baseUrl,
  }) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? token = prefs.getString('token');

      if (token == null) {
        print("❌ No token found in SharedPreferences.");
        return;
      }

      String url = '$baseUrl/api/method/upload_file';
      var request = http.MultipartRequest('POST', Uri.parse(url));

      request.fields['doctype'] = '$doctype';
      request.fields['docname'] = docname ?? '';
      request.headers['Authorization'] = token;
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          filePath,
          filename: 'event.mp3',
        ),
      );

      var response = await request.send();
      var responseData = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        var jsonResponse = jsonDecode(responseData);
        print("✅ File uploaded successfully: $jsonResponse");
      } else {
        print("❌ Upload failed: ${response.statusCode} - $responseData");
      }
    } catch (e) {
      print("❌ Upload error: $e");
    }
  }

  void launchDialer(String phoneNumber) async {
    final Uri dialUri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(dialUri)) {
      await launchUrl(dialUri, mode: LaunchMode.externalApplication);
    } else {
      print('Cannot launch $dialUri');
    }
  }

  void openWhatsAppChat(String phoneNumber) async {
    final cleanedNumber = phoneNumber.replaceAll(RegExp(r'\D'), '');
    final formattedNumber =
        cleanedNumber.startsWith('91') ? cleanedNumber : '91$cleanedNumber';

    final uri = Uri.parse('whatsapp://send?phone=$formattedNumber');

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WhatsApp not installed or cannot open.')),
      );
    }
  }

  bool _isTodayEvent() {
    if (eventData['event']['starts_on'] == null) return false;

    DateTime eventDate = DateTime.parse(eventData['event']['starts_on']);
    DateTime now = DateTime.now();

    return eventDate.year == now.year &&
        eventDate.month == now.month &&
        eventDate.day == now.day;
  }

  Future<bool> showOTPDialog(BuildContext context) async {
    TextEditingController otpController = TextEditingController();
    int timerSeconds = 30;
    Timer? resendTimer;

    Future<void> sendOtp() async {
      await Event.sendOtp(widget.eventid, context);
    }

    await sendOtp();

    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            void startTimer() {
              resendTimer?.cancel();
              resendTimer = Timer.periodic(Duration(seconds: 1), (timer) {
                if (timerSeconds == 0) {
                  timer.cancel();
                } else {
                  setState(() {
                    timerSeconds--;
                  });
                }
              });
            }

            if (resendTimer == null) {
              startTimer();
            }

            return AlertDialog(
              title: const Text('Enter OTP to Confirm'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: otpController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'OTP'),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    timerSeconds > 0
                        ? 'Resend OTP in $timerSeconds sec'
                        : 'Didn’t receive it?',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  TextButton(
                    onPressed:
                        timerSeconds == 0
                            ? () async {
                              await sendOtp();
                              setState(() {
                                timerSeconds = 30;
                              });
                              startTimer();
                            }
                            : null,
                    child: const Text('Resend OTP'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    resendTimer?.cancel();
                    Navigator.of(dialogContext).pop(false);
                  },
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final isValid = await Event.verifyOtp(
                      otpController.text,
                      widget.eventid,
                    );
                    if (isValid) {
                      resendTimer?.cancel();
                      Navigator.of(
                        dialogContext,
                      ).pop(true);

                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('OTP Verified')),
                      );
                    } else {
                      Warning.show(context, 'Invalid OTP', 'Error');
                    }
                  },
                  child: const Text('Submit'),
                ),
              ],
            );
          },
        );
      },
    ).then((value) => value ?? false);
  }

  @override
  Widget build(BuildContext context) {
    Color getActionColor() {
      final checkIn = eventData['event']?['custom_check_in']?? '';
      final checkOut = eventData['event']?['custom_check_out']?? '';

      if ((checkIn == null || checkIn.isEmpty) &&
          (checkOut == null || checkOut.isEmpty)) {
        return Colors.green;
      } else if ((checkIn != null && checkIn.isNotEmpty) &&
          (checkOut == null || checkOut.isEmpty)) {
        return Colors.red;
      }
      return const Color.fromARGB(231, 175, 173, 173);
    }

    String getButtonLabel() {
      final checkIn = eventData['event']?['custom_check_in']?? '';
      final checkOut = eventData['event']?['custom_check_out']?? '';

      if ((checkIn == null || checkIn.isEmpty) &&
          (checkOut == null || checkOut.isEmpty)) {
        return 'Click Here to Check In';
      } else if ((checkIn != null && checkIn.isNotEmpty) &&
          (checkOut == null || checkOut.isEmpty)) {
        return 'Click Here to Check Out';
      }
      return 'Checked In and Out';
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text('Event Details', style: TextStyle(fontSize: 20)),
          backgroundColor: Colors.blue,
        ),
        body:
            _isLoading
                ? Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                  onRefresh: ()async{
    await _checkPing(); 
                  _fetchData();
                  },
                  color: Colors.blue,
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              backgroundColor: Colors.blue,
                              radius: 40,
                              child: Text(
                                (eventData['reference_details'] != null &&
                                        eventData['reference_details']
                                            .isNotEmpty)
                                    ? (eventData['reference_details'][0]['party_name']
                                                ?.isNotEmpty ??
                                            false
                                        ? eventData['reference_details'][0]['party_name'][0]
                                        : '')
                                    : (eventData['event']?['name']
                                                ?.isNotEmpty ??
                                            false
                                        ? eventData['event']['name'][0]
                                        : ''),
                                style: TextStyle(
                                  fontSize: 18,
                                  color: Colors.white,
                                ),
                              ),
                            ),

                            SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    (eventData['reference_details'] != null &&
                                            eventData['reference_details']
                                                .isNotEmpty)
                                        ? eventData['reference_details'][0]['party_name'] ??
                                            "No Party Name"
                                        : eventData['event']?['name'] ??
                                            "No Event Name",
                                    style: TextStyle(fontSize: 15),
                                  ),
                                  SizedBox(height: 5),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        Icons.location_pin,
                                        color: Colors.blue,
                                      ),
                                      SizedBox(width: 5),
                                      Flexible(
                                        child:
                                        //         Text(eventData['event']['subject']??'',
                                        // style: TextStyle(fontSize: 14),
                                        // maxLines: 2,
                                        //           overflow: TextOverflow.ellipsis,
                                        //         ),
                                        FutureBuilder<String>(
                                          future: _getCurrentLocationAddress(),
                                          builder: (context, snapshot) {
                                            if (snapshot.connectionState ==
                                                ConnectionState.waiting) {
                                              return Text(
                                                "Fetching location...",
                                                style: TextStyle(fontSize: 14),
                                              );
                                            } else if (snapshot.hasError) {
                                              return Text(
                                                "Location error",
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: Colors.red,
                                                ),
                                              );
                                            } else {
                                              return Text(
                                                snapshot.data ??
                                                    "Location not found",
                                                style: TextStyle(fontSize: 14),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              );
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),

                        Container(
                          child: TabBar(
                            labelColor: Colors.blue,
                            indicatorColor: Colors.blue,
                            tabs: [Tab(text: 'Check In'), Tab(text: 'Details')],
                          ),
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              RefreshIndicator(
                                onRefresh: ()async{

    await _checkPing(); 
                                _fetchData();
                                },
                                child: SingleChildScrollView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.all(16),
                                  child: Container(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,

                                          children: [
                                            SizedBox(height: 250),

                                            GestureDetector(
                                              onTap: () async {
                                                setState(() {
                                                  _isActionInProgress = true;
                                                });
                                                if (!_isTodayEvent()) {
                                                  Warning.show(
                                                    context,
                                                    'You can only check in/out on the event day.',
                                                    'Invalid Date',
                                                  );
                                                  return;
                                                }

                                                final userEmail = prefs
                                                    .getString(
                                                      'email',
                                                    );
                                                final eventId = widget.eventid;
                                                String? checkIn =
                                                    eventData['event']['custom_check_in'];
                                                String? checkOut =
                                                    eventData['event']['custom_check_out'];

                                                Position position;
                                                try {
                                                  bool serviceEnabled =
                                                      await Geolocator.isLocationServiceEnabled();
                                                  if (!serviceEnabled) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          "Location services are disabled.",
                                                        ),
                                                      ),
                                                    );
                                                    return;
                                                  }

                                                  LocationPermission
                                                  permission =
                                                      await Geolocator.checkPermission();
                                                  if (permission ==
                                                      LocationPermission
                                                          .denied) {
                                                    permission =
                                                        await Geolocator.requestPermission();
                                                    if (permission ==
                                                        LocationPermission
                                                            .denied) {
                                                      ScaffoldMessenger.of(
                                                        context,
                                                      ).showSnackBar(
                                                        SnackBar(
                                                          content: Text(
                                                            "Location permission denied.",
                                                          ),
                                                        ),
                                                      );
                                                      return;
                                                    }
                                                  }

                                                  if (permission ==
                                                      LocationPermission
                                                          .deniedForever) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          "Location permission permanently denied.",
                                                        ),
                                                      ),
                                                    );
                                                    return;
                                                  }
                                                  bool hasPermission =
                                                      await _handleLocationPermission();
                                                  if (!hasPermission) return;

                                                  position =
                                                      await Geolocator.getCurrentPosition(
                                                        desiredAccuracy:
                                                            LocationAccuracy
                                                                .high,
                                                      );
                                                  double lat =
                                                      position.latitude;
                                                  double lng =
                                                      position.longitude;
                                                  final address =
                                                      await LocationHelper.getAddressFromCoordinates(
                                                        lat,
                                                        lng,
                                                      );

                                                  final working_hrs =
                                                      _calculateWorkingHours(
                                                        eventData['event']['custom_check_in'],
                                                        DateTime.now()
                                                            .toString(),
                                                      );
                                                  if ((checkIn == null ||
                                                          checkIn.isEmpty) &&
                                                      (checkOut == null ||
                                                          checkOut.isEmpty)) {
                                                    final response =
                                                        await Event.eventCheckin(
                                                          userEmail,
                                                          eventId,
                                                          lat,
                                                          lng,
                                                          address,
                                                          context,
                                                        );

                                                    if (response['message'] !=
                                                        null) {
                                                      if (response['message']['status'] ==
                                                          "success") {
                                                        Warning.show(
                                                          context,
                                                          response['message']['message'],
                                                          "Success",
                                                        );
                                                        await prefs.setBool(
                                                          'with_event',
                                                          true,
                                                        );
                                                        await _startGeofenceForEvent(lat, lng);
                                                        _fetchData();
                                                        
                                                      } else if (response['message']['status'] ==
                                                          "error") {
                                                        Warning.show(
                                                          context,
                                                          response['message']['message'],
                                                          "Error",
                                                        );
                                                      }
                                                    }
                                                  } else if ((checkIn != null &&
                                                          checkIn.isNotEmpty) &&
                                                      (checkOut == null ||
                                                          checkOut.isEmpty)) {
                                                    bool isOtpRequired =
                                                        await Event.checkIfOtpRequired(
                                                          widget.eventid,
                                                          context,
                                                        );

                                                    if (isOtpRequired) {
                                                      bool confirmed =
                                                          await showOTPDialog(
                                                            context,
                                                          );

                                                      if (!confirmed) {
                                                        Warning.show(
                                                          context,
                                                          "OTP verification failed. Cannot proceed.",
                                                          "Error",
                                                        );
                                                        return;
                                                      }
                                                    }

                                                    LocationTrackerService.stopTracking();
                                                    double distance =
                                                        LocationTrackerService.calculateTotalDistance();

                                                    String
                                                    formattedDistanceWithUnit;

                                                    if (distance >= 1000) {
                                                      double km =
                                                          distance / 1000;
                                                      formattedDistanceWithUnit =
                                                          '${km.toStringAsFixed(2)} km';
                                                    } else {
                                                      formattedDistanceWithUnit =
                                                          '${distance.toStringAsFixed(2)} m';
                                                    }

                                                    List<LatLng> path =
                                                        LocationTrackerService.getTrackedPoints();

                                                    List<Map<String, dynamic>>
                                                    locationLogs =
                                                        path
                                                            .map(
                                                              (latLng) => {
                                                                'latitude':
                                                                    latLng
                                                                        .latitude,
                                                                'longitude':
                                                                    latLng
                                                                        .longitude,
                                                              },
                                                            )
                                                            .toList();

                                                    final last_lat_lng =
                                                        prefs.getString(
                                                          'last_lat_lng',
                                                        ) ??
                                                        '';

                                                    final response =
                                                        await Event.eventCheckout(
                                                          userEmail,
                                                          eventId,
                                                          lat,
                                                          lng,
                                                          address,
                                                          working_hrs,
                                                          formattedDistanceWithUnit,
                                                          last_lat_lng,
                                                          jsonEncode(
                                                            locationLogs,
                                                          ),
                                                          context,
                                                        );
                                                    if (response['message'] !=
                                                        null) {
                                                      if (response['message']['status'] ==
                                                          "success") {
                                                        LocationTrackerService.startTracking(
                                                          start: LatLng(
                                                            position.latitude,
                                                            position.longitude,
                                                          ),
                                                        );

                                                        Warning.show(
                                                          context,
                                                          response['message']['message'],
                                                          "Success",
                                                        );
                                                        await prefs.setString(
                                                          'last_checkout_address',
                                                          address,
                                                        );

                                                        await prefs.setString(
                                                          'last_lat_lng',

                                                          '$lat,$lng',
                                                        );

                                                        _fetchData();

                                                        if (AudioRecordingService()
                                                            .isRecording) {
                                                          await AudioRecordingService()
                                                              .stopRecording();
                                                        }

                                                        final paths =
                                                            AudioRecordingService()
                                                                .getAllRecordingPaths();
                                                        if (paths.isNotEmpty) {
                                                          for (final path
                                                              in paths) {
                                                            if (File(
                                                              path,
                                                            ).existsSync()) {
                                                              await uploadAudioToERPNext(
                                                                filePath: path,
                                                                doctype:
                                                                    'Event',
                                                                docname:
                                                                    widget
                                                                        .eventid,
                                                                baseUrl:
                                                                    dotenv
                                                                        .env['SITE_URL'] ??
                                                                    '',
                                                              );
                                                            } else {
                                                              print(
                                                                "⚠️ Skipping missing file: $path",
                                                              );
                                                            }
                                                          }

                                                          AudioRecordingService()
                                                              .resetRecordings();
                                                        } else {
                                                          Warning.show(
                                                            context,
                                                            "Audio file not found. Checkout will continue without recording.",
                                                            "Warning",
                                                          );
                                                        }
                                                      } else {
                                                        Warning.show(
                                                          context,
                                                          "Already checked in and out",
                                                          "",
                                                        );
                                                      }
                                                    }
                                                  }
                                                } catch (e) {
                                                  print("Location error: $e");
                                                  Warning.show(
                                                    context,
                                                    "$e",
                                                    "Error",
                                                  );
                                                } finally {
                                                  setState(() {
                                                    _isActionInProgress = false;
                                                  });
                                                }
                                              },

                                              child: Stack(
                                                alignment: Alignment.center,
                                                children: [
                                                  CircleAvatar(
                                                    radius: 80,
                                                    backgroundColor:
                                                        getActionColor(),
                                                    child: CircleAvatar(
                                                      radius: 60,
                                                      backgroundColor:
                                                          const Color.fromARGB(
                                                            255,
                                                            221,
                                                            217,
                                                            217,
                                                          ),
                                                      child: CircleAvatar(
                                                        radius: 40,
                                                        backgroundColor:
                                                            const Color.fromARGB(
                                                              231,
                                                              175,
                                                              173,
                                                              173,
                                                            ),
                                                        child: Icon(
                                                          Icons.touch_app,
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  if (_isActionInProgress)
                                                    SizedBox(
                                                      height: 40,
                                                      width: 40,
                                                      child:
                                                          CircularProgressIndicator(
                                                            color: Colors.white,
                                                            strokeWidth: 3,
                                                          ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        Text(getButtonLabel()),
                                        if (eventData['event']?['custom_check_in'] !=
                                                null &&
                                            (eventData['event']?['custom_check_out'] ==
                                                    null ||
                                                eventData['event']?['custom_check_out']
                                                    .isEmpty)) ...[
                                          const SizedBox(height: 16),

                                          if (_isRecording) ...[
                                            RecordingWaveAnimation(
                                              isRecording: true,
                                            ),
                                            const SizedBox(height: 10),
                                            ElevatedButton.icon(
                                              icon: const Icon(
                                                Icons.stop,
                                                color: Colors.white,
                                                size: 20,
                                              ),
                                              label: const Text(
                                                "Stop Recording",
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    Colors.redAccent,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 18,
                                                      vertical: 10,
                                                    ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(25),
                                                ),
                                                elevation: 4,
                                              ),
                                              onPressed: _stopManualRecording,
                                            ),
                                          ] else ...[
                                            ElevatedButton.icon(
                                              icon: const Icon(
                                                Icons.mic,
                                                color: Colors.white,
                                                size: 20,
                                              ),
                                              label: const Text(
                                                "Start Recording",
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    Colors.green.shade600,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 18,
                                                      vertical: 10,
                                                    ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(25),
                                                ),
                                                elevation: 4,
                                              ),
                                              onPressed: _startManualRecording,
                                            ),
                                          ],
                                        ],

                                        // ── Camera capture button ──────────
                                        const SizedBox(height: 12),
                                        _isUploadingPhoto
                                            ? const Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  SizedBox(
                                                    width: 20,
                                                    height: 20,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                                  ),
                                                  SizedBox(width: 10),
                                                  Text('Uploading photo...'),
                                                ],
                                              )
                                            : ElevatedButton.icon(
                                                icon: const Icon(
                                                  Icons.camera_alt,
                                                  color: Colors.white,
                                                  size: 20,
                                                ),
                                                label: Text(
                                                  _capturedPhotos.isEmpty
                                                      ? 'Capture Photo'
                                                      : 'Capture Photo (${_capturedPhotos.length})',
                                                  style: const TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: Colors.indigo,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 18,
                                                    vertical: 10,
                                                  ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            25),
                                                  ),
                                                  elevation: 4,
                                                ),
                                                onPressed:
                                                    _captureAndUploadPhoto,
                                              ),

                                        // Thumbnail preview of captured photos
                                        if (_capturedPhotos.isNotEmpty) ...[
                                          const SizedBox(height: 10),
                                          SizedBox(
                                            height: 70,
                                            child: ListView.builder(
                                              scrollDirection: Axis.horizontal,
                                              itemCount: _capturedPhotos.length,
                                              itemBuilder: (ctx, i) => Container(
                                                margin: const EdgeInsets.only(
                                                    right: 8),
                                                width: 70,
                                                height: 70,
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  image: DecorationImage(
                                                    image: FileImage(
                                                        _capturedPhotos[i]),
                                                    fit: BoxFit.cover,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],

                                        // ── Geofence status badge ──────────
                                        if (_geofenceStatus != null) ...[
                                          const SizedBox(height: 12),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 14, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: _geofenceStatus ==
                                                      GeofenceStatus.ENTER
                                                  ? Colors.green.shade100
                                                  : _geofenceStatus ==
                                                          GeofenceStatus.EXIT
                                                      ? Colors.orange.shade100
                                                      : Colors.blue.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              border: Border.all(
                                                color: _geofenceStatus ==
                                                        GeofenceStatus.ENTER
                                                    ? Colors.green
                                                    : _geofenceStatus ==
                                                            GeofenceStatus.EXIT
                                                        ? Colors.orange
                                                        : Colors.blue,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  _geofenceStatus ==
                                                          GeofenceStatus.ENTER
                                                      ? Icons.location_on
                                                      : _geofenceStatus ==
                                                              GeofenceStatus.EXIT
                                                          ? Icons.location_off
                                                          : Icons
                                                              .location_searching,
                                                  size: 16,
                                                  color: _geofenceStatus ==
                                                          GeofenceStatus.ENTER
                                                      ? Colors.green
                                                      : _geofenceStatus ==
                                                              GeofenceStatus.EXIT
                                                          ? Colors.orange
                                                          : Colors.blue,
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  _geofenceStatus ==
                                                          GeofenceStatus.ENTER
                                                      ? 'Inside event zone'
                                                      : _geofenceStatus ==
                                                              GeofenceStatus.EXIT
                                                          ? 'Outside event zone'
                                                          : 'Dwelling in zone',
                                                  style: const TextStyle(
                                                      fontSize: 12),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],

                                        StreamBuilder<Duration>(
                                          stream:
                                              AudioRecordingService()
                                                  .timerService
                                                  .timerStream,
                                          builder: (context, snapshot) {
                                            if (snapshot.connectionState ==
                                                ConnectionState.waiting) {
                                              return Text(
                                                "Recording Not Yet Started",
                                              );
                                            } else if (snapshot.hasData) {
                                              final duration =
                                                  snapshot.data ??
                                                  Duration.zero;
                                              return Text(
                                                _formatDuration(duration),
                                                style: TextStyle(fontSize: 20),
                                              );
                                            }
                                            return Text(
                                              "Error fetching timer data",
                                            );
                                          },
                                        ),
                                        SizedBox(height: 20),
                                        Container(
                                          padding: EdgeInsets.all(20),
                                          decoration: BoxDecoration(
                                            color: Colors.grey[200],
                                            borderRadius: BorderRadius.circular(
                                              12.0,
                                            ),

                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withOpacity(
                                                  0.2,
                                                ),
                                                blurRadius: 10,
                                                spreadRadius: 2,
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Column(
                                                children: [
                                                  Icon(Icons.timer),
                                                  Text(
                                                    _formatTime(
                                                      eventData['event']?['custom_check_in']?? '',
                                                    ),
                                                  ),
                                                  Text("Check In"),
                                                ],
                                              ),
                                              Column(
                                                children: [
                                                  Icon(Icons.timer),
                                                  Text(
                                                    _formatTime(
                                                      eventData['event']?['custom_check_out']?? '',
                                                    ),
                                                  ),
                                                  Text("Check Out"),
                                                ],
                                              ),
                                              Container(
                                                width: 90,
                                                child: Column(
                                                  children: [
                                                    Icon(Icons.timer),
                                                    Text(
                                                      _calculateWorkingHours(
                                                        eventData['event']?['custom_check_in'] ?? '',
                                                        eventData['event']?['custom_check_out'] ?? '',
                                                      ),
                                                    ),

                                                    Text("Working Hrs"),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              RefreshIndicator(
                                onRefresh: ()async{

    await _checkPing(); 
                                _fetchData();
                                },
                                child: SingleChildScrollView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.all(16),
                                  child: Container(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(height: 20),

                                        Text(
                                          'Name:${eventData['event']?['name']?? ''}',
                                        ),
                                        SizedBox(height: 20),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                (eventData['reference_details'] !=
                                                            null &&
                                                        eventData['reference_details']
                                                            .isNotEmpty &&
                                                        eventData['reference_details'][0]['contact_mobile'] !=
                                                            null &&
                                                        eventData['reference_details'][0]['contact_mobile']
                                                            .toString()
                                                            .isNotEmpty)
                                                    ? 'Mobile Number: ${eventData['reference_details'][0]['contact_mobile']}'
                                                    : 'Mobile Number: null',
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (eventData['reference_details'] !=
                                                    null &&
                                                eventData['reference_details']
                                                    .isNotEmpty &&
                                                eventData['reference_details'][0]['contact_mobile'] !=
                                                    null &&
                                                eventData['reference_details'][0]['contact_mobile']
                                                    .toString()
                                                    .isNotEmpty)
                                              Row(
                                                children: [
                                                  IconButton(
                                                    icon: const Icon(
                                                      Icons.call,
                                                    ),
                                                    onPressed: () {
                                                      final phone =
                                                          eventData['reference_details'][0]['contact_mobile'];
                                                      launchDialer(phone);
                                                    },
                                                  ),
                                                  IconButton(
                                                    icon: FaIcon(
                                                      FontAwesomeIcons.whatsapp,
                                                      color: Colors.green,
                                                    ),

                                                    onPressed: () {
                                                      final phone =
                                                          eventData['reference_details'][0]['contact_mobile'];
                                                      openWhatsAppChat(phone);
                                                    },
                                                  ),
                                                ],
                                              ),
                                          ],
                                        ),

                                        SizedBox(height: 20),

                                        Text(
                                          'Title:${_getParticipantsTitles()}',
                                        ),
                                        SizedBox(height: 20),
                                        Text(
                                          (eventData['reference_details'] !=
                                                      null &&
                                                  eventData['reference_details']
                                                      .isNotEmpty)
                                              ? 'Product Enquired:${eventData['reference_details'][0]['custom_product_enquired']}'
                                              : 'Product Enquired:null',
                                        ),
                                        SizedBox(height: 20),

                                        Text(
                                          'Event Type:${eventData['event']?['event_type']?? ''}',
                                        ),
                                        SizedBox(height: 20),

                                        Text(
                                          'Subject:${eventData['event']?['subject']?? ''}',
                                        ),
                                        SizedBox(height: 20),

                                        Text(
                                          'Owner:${eventData['event']?['owner']?? ''}',
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
      ),
    );
  }
}

class RecordingWaveAnimation extends StatefulWidget {
  final bool isRecording;

  const RecordingWaveAnimation({super.key, required this.isRecording});

  @override
  _RecordingWaveAnimationState createState() => _RecordingWaveAnimationState();
}

class _RecordingWaveAnimationState extends State<RecordingWaveAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<Animation<double>> _barAnimations;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    _barAnimations = List.generate(5, (index) {
      final delay = index * 0.1;
      return Tween<double>(begin: 5, end: 20).animate(
        CurvedAnimation(
          parent: _controller,
          curve: Interval(delay, 1.0, curve: Curves.easeInOut),
        ),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RecordingWaveAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isRecording && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children:
                _barAnimations.map((anim) {
                  return Container(
                    width: 6,
                    height: anim.value,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }).toList(),
          );
        },
      ),
    );
  }
}
