import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../helpers/language_helper.dart';
import 'package:intl/intl.dart';
import '../../services/camera_service.dart';
import '../../attendance/services/attendance_service.dart';
import '../../attendance/screens/camera_selfie_screen.dart';
import 'member_selection_page.dart';
import 'device_selection_screen.dart';
import '../../services/supabase_storage_service.dart';
import '../../models/attendance_model.dart';

class SelfieAttendanceFlowPage extends StatefulWidget {
  final int organizationId;
  final String organizationName;
  final Map<String, dynamic> petugasData;
  final bool isSelfAttendance;

  const SelfieAttendanceFlowPage({
    super.key,
    required this.organizationId,
    required this.organizationName,
    required this.petugasData,
    this.isSelfAttendance = false,
  });

  @override
  State<SelfieAttendanceFlowPage> createState() =>
      _SelfieAttendanceFlowPageState();
}

class _SelfieAttendanceFlowPageState extends State<SelfieAttendanceFlowPage> {
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseStorageService _storageService = SupabaseStorageService();

  bool _isProcessing = false;

  static const Color primaryColor = Color(0xFF6366F1);
  static const Color backgroundColor = Color(0xFF1F2937);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startSelfieAttendanceFlow();
    });
  }

  Future<void> _startSelfieAttendanceFlow() async {
    int currentStep = 1;
    Map<String, dynamic>? selectedMember;
    Map<String, dynamic>? selectedShift;
    Map<String, dynamic>? locationData;
    String? photoPath;

    try {
      while (mounted) {
        if (currentStep == 1) {
          if (widget.isSelfAttendance) {
            selectedMember = widget.petugasData;
          } else {
            selectedMember = await _selectMember();
          }

          if (selectedMember == null) {
            // Exit entirely to dashboard
            Navigator.pop(context);
            return;
          }
          currentStep = 2; // Move to Shift Selection
        } else if (currentStep == 2) {
          currentStep = 3; // Move to Location & Shift Selection
        } else if (currentStep == 3) {
          final selection = await _selectLocation(selectedMember!['id']);
          if (selection == null) {
            // Exit entirely
            Navigator.pop(context);
            return;
          }
          locationData = selection;
          selectedShift = selection['selectedShift'];
          currentStep = 4; // Move to Take Selfie
        } else if (currentStep == 4) {
          photoPath = await _takeSelfie();
          if (photoPath == null) {
            // Go back to step 3
            currentStep = 3;
            continue;
          }
          currentStep = 5; // Move to Submit
        } else if (currentStep == 5) {
          await _submitSelfieAttendance(
            member: selectedMember!,
            locationData: locationData!,
            photoPath: photoPath!,
            selectedShift: selectedShift,
          );

          if (mounted) {
            Navigator.pop(context, {'success': true});
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('Error in selfie attendance flow: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${AppLanguage.tr('attendance.selfie.error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<Map<String, dynamic>?> _selectMember() async {
    return await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => MemberSelectionPage(
          organizationId: widget.organizationId,
          organizationName: widget.organizationName,
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _selectLocation(int memberId) async {
    return await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => DeviceSelectionScreen(
          organizationId: widget.organizationId.toString(),
          organizationName: widget.organizationName,
          isRequired: false,
          allowCurrentLocation: true, // Enable manual location selection
          memberId: memberId, // NEW: Pass memberId for shift selection
        ),
      ),
    );
  }

  Future<String?> _takeSelfie() async {
    try {
      // Initialize cameras
      final cameras = await CameraService.initializeCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available');
      }

      return await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (context) => CameraSelfieScreen(cameras: cameras),
        ),
      );
    } catch (e) {
      debugPrint('Error initializing camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${AppLanguage.tr('attendance.selfie.camera_error')}: $e',
            ),
          ),
        );
      }
      return null;
    }
  }

  Future<void> _submitSelfieAttendance({
    required Map<String, dynamic> member,
    required Map<String, dynamic> locationData,
    required String photoPath,
    Map<String, dynamic>? selectedShift,
  }) async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      // Show loading dialog
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => WillPopScope(
            onWillPop: () async => false,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      AppLanguage.tr('attendance.selfie.submitting'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      // 1. Upload photo to Supabase Storage
      final photoUrl = await _uploadPhoto(photoPath, member['id']);

      // 2. Prepare location data
      final latitude = locationData['latitude'] as double?;
      final longitude = locationData['longitude'] as double?;
      final accuracy = locationData['accuracy'] as double?;

      final location = {
        'latitude': latitude,
        'longitude': longitude,
        if (accuracy != null) 'accuracy': accuracy,
        if (locationData['type'] == 'device')
          'device_id':
              (locationData['selectedDevice'] as AttendanceDevice?)?.id,
        if (locationData['reason'] != null) 'reason': locationData['reason'],
      };

      // 3. Determine check-in or check-out
      final todayAttendance = await _attendanceService.getTodayAttendance(
        member['id'] as int,
        organizationTimezone: 'Asia/Jakarta',
      );

      final isCheckOut =
          todayAttendance != null && todayAttendance.actualCheckIn != null;

      // 4. Submit attendance
      if (isCheckOut) {
        await _attendanceService.checkOut(
          organizationMemberId: member['id'] as int,
          photoUrl: photoUrl,
          method: 'selfie',
          organizationTimezone: 'Asia/Jakarta',
          location: location,
          deviceId: locationData['type'] == 'device'
              ? int.tryParse(
                  (locationData['selectedDevice'] as AttendanceDevice?)?.id ??
                      '',
                )
              : null,
          rawData: {
            if (selectedShift != null) 'selected_shift_id': selectedShift['id'],
            if (selectedShift != null)
              'selected_shift_name': selectedShift['name'],
          },
        );
      } else {
        await _attendanceService.checkIn(
          organizationMemberId: member['id'] as int,
          photoUrl: photoUrl,
          method: 'selfie',
          organizationTimezone: 'Asia/Jakarta',
          location: location,
          deviceId: locationData['type'] == 'device'
              ? int.tryParse(
                  (locationData['selectedDevice'] as AttendanceDevice?)?.id ??
                      '',
                )
              : null,
          rawData: {
            if (selectedShift != null) 'selected_shift_id': selectedShift['id'],
            if (selectedShift != null)
              'selected_shift_name': selectedShift['name'],
          },
        );
      }

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Show success message
      if (mounted) {
        final locationName = locationData['type'] == 'device'
            ? _getDeviceDisplayName(locationData['selectedDevice'])
            : AppLanguage.tr('attendance.selfie.current_location');

        await _showSuccessOverlay(
          photoPath: photoPath,
          locationName: locationName,
          time: DateFormat('hh:mm aa').format(DateTime.now()),
          memberName: _getMemberName(member),
          shiftName:
              selectedShift?['name'] ??
              AppLanguage.tr('attendance.selfie.non_scheduled'),
        );
      }
    } catch (e) {
      debugPrint('Error submitting selfie attendance: $e');

      // Close loading dialog if open
      if (mounted) Navigator.pop(context);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${AppLanguage.tr('attendance.selfie.error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _showSuccessOverlay({
    required String photoPath,
    required String locationName,
    required String time,
    String? memberName,
    String? shiftName,
  }) async {
    if (!mounted) return;

    // Show the dialog
    final dialogFuture = showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          child: Stack(
            children: [
              // 1. Captured Photo Backdrop
              Positioned.fill(
                child: Image.file(File(photoPath), fit: BoxFit.cover),
              ),

              // 2. Dark Overlay with Blur
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: Container(color: Colors.black.withOpacity(0.6)),
                ),
              ),

              // 3. Success Card (Centered)
              Center(
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.85,
                  padding: const EdgeInsets.symmetric(
                    vertical: 40,
                    horizontal: 24,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(
                      0xFF1E1B2E,
                    ).withOpacity(0.95), // Dark modern purple/black
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 40,
                        offset: const Offset(0, 20),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Checkbox Icon
                      Container(
                        width: 80,
                        height: 80,
                        decoration: const BoxDecoration(
                          color: Color(0xFF8B5CF6), // Purple
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        AppLanguage.tr('attendance.selfie.attendance_success'),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Info Rows
                      _buildInfoRow(
                        icon: Icons.person_rounded,
                        label: AppLanguage.tr('attendance.selfie.member'),
                        value: memberName ?? 'Unknown',
                      ),
                      const SizedBox(height: 12),
                      _buildInfoRow(
                        icon: Icons.access_time_filled_rounded,
                        label: AppLanguage.tr('attendance.selfie.time'),
                        value: time,
                      ),
                      const SizedBox(height: 12),
                      _buildInfoRow(
                        icon: Icons.calendar_today_rounded,
                        label: AppLanguage.tr('attendance.selfie.shift'),
                        value:
                            shiftName ??
                            AppLanguage.tr('attendance.selfie.non_scheduled'),
                      ),
                      const SizedBox(height: 12),
                      _buildInfoRow(
                        icon: Icons.location_on_rounded,
                        label: AppLanguage.tr('attendance.selfie.location'),
                        value: locationName,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    // Auto-dismiss after 3 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        // Only pop if the dialog is still showing (dialogFuture is still active)
        Navigator.of(context, rootNavigator: true).pop();
      }
    });

    return dialogFuture;
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF8B5CF6).withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFFA78BFA), size: 18),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 14,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  String _getDeviceDisplayName(dynamic device) {
    if (device is AttendanceDevice) {
      if (device.location != null && device.location!.isNotEmpty) {
        return device.location!;
      }
      return device.deviceName;
    }
    return AppLanguage.tr('attendance.selfie.unknown_location');
  }

  Future<String> _uploadPhoto(String photoPath, int memberId) async {
    try {
      final photoFile = File(photoPath);
      if (!await photoFile.exists()) {
        throw Exception('Photo file not found at $photoPath');
      }

      // Use the centralized storage service
      final publicUrl = await _storageService.uploadAttendancePhoto(
        photoFile,
        memberId,
        'selfie', // Standard type for this flow
      );

      debugPrint('Photo uploaded via storage service: $publicUrl');
      return publicUrl;
    } catch (e) {
      debugPrint('Error uploading photo via storage service: $e');
      throw Exception('Failed to upload photo: $e');
    }
  }

  String _getMemberName(Map<String, dynamic> member) {
    // Resilience: Check user_profiles but also fallback to employee_id or ID
    final userProfile = member['user_profiles'] as Map<String, dynamic>?;

    if (userProfile != null) {
      final displayName = userProfile['display_name'] as String?;
      if (displayName != null && displayName.isNotEmpty) {
        return displayName;
      }

      final firstName = userProfile['first_name'] as String? ?? '';
      final lastName = userProfile['last_name'] as String? ?? '';
      final fullName = '$firstName $lastName'.trim();
      if (fullName.isNotEmpty) return fullName;
    }

    // Fallbacks
    if (member['employee_id'] != null) return 'Member ${member['employee_id']}';
    return 'Member #${member['id']}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
            ),
            const SizedBox(height: 16),
            Text(
              AppLanguage.tr('attendance.selfie.preparing'),
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
